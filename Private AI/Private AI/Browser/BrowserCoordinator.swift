import AppKit
import Foundation
import LLMCore
import Observation
import PrivateAITools
import WebKit

enum BrowserCoordinatorError: Error, Equatable, LocalizedError {
    case sessionNotFound
    case staleFrame
    case coordinateOutOfBounds
    case navigationFailed(String)
    case navigationTimedOut
    case snapshotUnavailable
    case imageTooLarge
    case interactionBlocked(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            "The browser session is no longer available."
        case .staleFrame:
            "The browser frame is stale. Inspect the new screenshot before acting."
        case .coordinateOutOfBounds:
            "The browser coordinate is outside the referenced screenshot."
        case .navigationFailed(let message):
            "Browser navigation failed: \(message)"
        case .navigationTimedOut:
            "Browser navigation timed out."
        case .snapshotUnavailable:
            "The browser could not capture a screenshot."
        case .imageTooLarge:
            "The browser screenshot exceeded the model image limit."
        case .interactionBlocked(let reason):
            "Browser interaction was blocked: \(reason)"
        }
    }
}

@MainActor
@Observable
final class BrowserCoordinator: BrowserServing {
    private(set) var isActive = false
    private(set) var isVisible = false
    private(set) var status = "Idle"
    private(set) var title = ""
    private(set) var origin = ""
    private(set) var latestImage: NSImage?
    private(set) var latestFrameID: UUID?
    private(set) var latestPageURL = ""
    @ObservationIgnored private(set) var activeWebView: WKWebView?

    @ObservationIgnored private var sessions: [UUID: BrowserSession] = [:]
    @ObservationIgnored private let maximumImageBytes = BrowserTool.maximumImageBytes
    @ObservationIgnored private let allowsTestURLs: Bool
    @ObservationIgnored private let framesDirectory: URL
    @ObservationIgnored private static let frameTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    init(
        allowsTestURLs: Bool = false,
        framesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".privateAI/logs/browser-frames", directoryHint: .isDirectory)
    ) {
        self.allowsTestURLs = allowsTestURLs
        self.framesDirectory = framesDirectory
    }

    func execute(_ request: BrowserRequest) async throws -> BrowserResponse {
        switch request {
        case .open(let url):
            return try await open(url)
        case .navigate(let sessionID, let url):
            let session = try session(sessionID)
            status = "Loading"
            try await session.navigate(to: url)
            return try await response(for: session, status: "ready")
        case .search(let query):
            var components = URLComponents(string: "https://www.bing.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url else {
                throw BrowserCoordinatorError.navigationFailed("Invalid search URL.")
            }
            return try await open(url)
        case .observe(let sessionID, let representation):
            return try await response(
                for: session(sessionID),
                status: "ready",
                representation: representation
            )
        case .scroll(
            let sessionID,
            let frameID,
            let x,
            let y,
            let deltaX,
            let deltaY
        ):
            let session = try session(sessionID)
            let point = try await session.viewPoint(frameID: frameID, x: x, y: y)
            status = "Scrolling"
            try await session.scroll(
                at: point,
                deltaX: Double(deltaX) * session.viewWidth / session.imageWidth,
                deltaY: Double(deltaY) * session.viewHeight / session.imageHeight
            )
            return try await response(for: session, status: "ready")
        case .click(let sessionID, let frameID, let x, let y):
            let session = try session(sessionID)
            let point = try await session.viewPoint(frameID: frameID, x: x, y: y)
            status = "Clicking"
            let target = try await session.hitTest(at: point)
            if let navigationURL = target.navigationURL {
                try await session.navigate(to: navigationURL)
            } else {
                try await session.click(at: point)
            }
            return try await response(
                for: session,
                status: "ready",
                inputBackend: "javascript_element_from_point"
            )
        case .type(let sessionID, let frameID, let x, let y, let text, let mode):
            let session = try session(sessionID)
            let point = try await session.viewPoint(frameID: frameID, x: x, y: y)
            status = "Typing"
            let target = try await session.hitTest(at: point)
            guard !target.isSecureInput else {
                throw BrowserCoordinatorError.interactionBlocked(
                    "Secure input requires direct user interaction."
                )
            }
            try await session.type(text, mode: mode, at: point)
            return try await response(
                for: session,
                status: "ready",
                inputBackend: "javascript_element_from_point"
            )
        case .press(let sessionID, let frameID, let key):
            let session = try session(sessionID)
            try session.require(frameID: frameID)
            status = "Pressing \(key)"
            try await session.press(key)
            return try await response(
                for: session,
                status: "ready",
                inputBackend: "javascript_keyboard_event"
            )
        case .back(let sessionID):
            let session = try session(sessionID)
            status = "Going back"
            try await session.goBack()
            return try await response(for: session, status: "ready")
        case .forward(let sessionID):
            let session = try session(sessionID)
            status = "Going forward"
            try await session.goForward()
            return try await response(for: session, status: "ready")
        case .close(let sessionID):
            guard let session = sessions.removeValue(forKey: sessionID) else {
                throw BrowserCoordinatorError.sessionNotFound
            }
            session.close()
            activeWebView = nil
            latestImage = nil
            latestFrameID = nil
            latestPageURL = ""
            title = ""
            origin = ""
            status = "Idle"
            isActive = false
            isVisible = false
            return BrowserResponse(status: "closed")
        }
    }

    func cancel(sessionIDs: Set<UUID>) async {
        for sessionID in sessionIDs {
            guard let session = sessions.removeValue(forKey: sessionID) else { continue }
            session.stopAutomation()
            activeWebView = session.webView
        }
        updateVisibleSession()
    }

    func dismiss() {
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        activeWebView?.stopLoading()
        activeWebView?.removeFromSuperview()
        activeWebView = nil
        latestImage = nil
        latestFrameID = nil
        latestPageURL = ""
        title = ""
        origin = ""
        status = "Idle"
        isActive = false
        isVisible = false
    }

    func pageText(sessionID: UUID) async throws -> String {
        try await session(sessionID).visibleText()
    }

    private func open(_ url: URL) async throws -> BrowserResponse {
        if !allowsTestURLs {
            try await BrowserDestinationPolicy.validateResolvedDestination(url)
        }
        let session = BrowserSession(allowsTestURLs: allowsTestURLs)
        sessions[session.id] = session
        activeWebView = session.webView
        isActive = true
        isVisible = true
        status = "Loading"
        origin = Self.origin(for: url)
        do {
            try await session.load(url)
            return try await response(for: session, status: "ready")
        } catch {
            sessions.removeValue(forKey: session.id)
            session.close()
            updateVisibleSession()
            throw error
        }
    }

    private func session(_ id: UUID) throws -> BrowserSession {
        guard let session = sessions[id] else {
            throw BrowserCoordinatorError.sessionNotFound
        }
        return session
    }

    private func response(
        for session: BrowserSession,
        status: String,
        representation: BrowserRepresentation = .raw,
        inputBackend: String? = nil
    ) async throws -> BrowserResponse {
        let frame = try await session.capture(
            representation: representation,
            inputBackend: inputBackend
        )
        guard frame.image.data.count <= maximumImageBytes else {
            throw BrowserCoordinatorError.imageTooLarge
        }
        latestImage = NSImage(data: frame.image.data)
        latestFrameID = frame.frameID
        latestPageURL = frame.pageURL
        persistFrame(frame)
        title = frame.pageTitle
        origin = frame.validatedOrigin
        isActive = true
        self.status = status.capitalized
        return BrowserResponse(status: status, frame: frame)
    }

    private func persistFrame(_ frame: BrowserFrame) {
        do {
            try FileManager.default.createDirectory(
            at: framesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: framesDirectory.path
            )
            let timestamp = Self.frameTimestampFormatter.string(from: .now)
            let filename = "\(timestamp)_\(frame.frameID.uuidString.lowercased()).jpg"
            let fileURL = framesDirectory.appending(path: filename)
            try frame.image.data.write(
            to: fileURL,
            options: .atomic
        )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            status = "Frame save failed"
        }
    }

    private func updateVisibleSession() {
        guard let session = sessions.values.first else {
            isActive = false
            status = activeWebView == nil ? "Idle" : "Completed"
            latestImage = nil
            latestFrameID = nil
            isVisible = activeWebView != nil
            return
        }
        isActive = true
        activeWebView = session.webView
        title = session.webView.title ?? ""
        origin = session.webView.url.map(Self.origin(for:)) ?? ""
    }

    private static func origin(for url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "" }
        return "\(scheme)://\(host)"
    }
}

@MainActor
private final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    private(set) var documentID = UUID()

    private var revision = 0
    private var currentFrameID: UUID?
    private var currentImageWidth = 0
    private var currentImageHeight = 0
    private var capturedViewSize = CGSize.zero
    private var capturedMetrics: BrowserMetrics?
    private var navigationContinuation: CheckedContinuation<Void, any Error>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var snapshotContinuation: CheckedContinuation<NSImage, any Error>?
    private var snapshotTimeoutTask: Task<Void, Never>?
    private let allowsTestURLs: Bool

    var imageWidth: Double { Double(currentImageWidth) }
    var imageHeight: Double { Double(currentImageHeight) }
    var viewWidth: Double { capturedViewSize.width }
    var viewHeight: Double { capturedViewSize.height }

    init(allowsTestURLs: Bool) {
        self.allowsTestURLs = allowsTestURLs
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1_280, height: 800),
            configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ url: URL) async throws {
        try await navigate { webView.load(URLRequest(url: url)) }
    }

    func goBack() async throws {
        guard webView.canGoBack else {
            throw BrowserCoordinatorError.navigationFailed("No previous page is available.")
        }
        try await navigate { webView.goBack() }
    }

    func goForward() async throws {
        guard webView.canGoForward else {
            throw BrowserCoordinatorError.navigationFailed("No forward page is available.")
        }
        try await navigate { webView.goForward() }
    }

    func navigate(to url: URL) async throws {
        if !allowsTestURLs {
            try await BrowserDestinationPolicy.validateResolvedDestination(url)
        }
        try await navigate { webView.load(URLRequest(url: url)) }
    }

    func require(frameID: UUID) throws {
        guard currentFrameID == frameID else {
            throw BrowserCoordinatorError.staleFrame
        }
    }

    func viewPoint(frameID: UUID, x: Int, y: Int) async throws -> CGPoint {
        try require(frameID: frameID)
        guard currentImageWidth > 0,
              currentImageHeight > 0,
              x >= 0,
              y >= 0,
              x < currentImageWidth,
              y < currentImageHeight else {
            throw BrowserCoordinatorError.coordinateOutOfBounds
        }
        let point = CGPoint(
            x: capturedViewSize.width * Double(x) / Double(currentImageWidth),
            y: capturedViewSize.height * Double(y) / Double(currentImageHeight)
        )
        let current = try await metrics()
        guard current == capturedMetrics else {
            throw BrowserCoordinatorError.staleFrame
        }
        return point
    }

    func hitTest(at point: CGPoint) async throws -> BrowserHitTarget {
        let result = try await webView.callAsyncJavaScript(
            """
            const element = document.elementFromPoint(Number(x), Number(y));
            if (!element) return null;
            const control = element.closest('a,button,input,select,textarea,[role="button"],[role="link"]') || element;
            const tag = control.tagName.toLowerCase();
            const inputType = tag === 'input' ? (control.type || 'text').toLowerCase() : '';
            const href = tag === 'a' ? control.href : '';
            const formMethod = control.form ? (control.form.method || 'get').toLowerCase() : '';
            const name = (control.getAttribute('aria-label') || control.innerText || control.value || tag).trim().slice(0, 160);
            return {tag, inputType, href, formMethod, name};
            """,
            arguments: ["x": point.x, "y": point.y],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let object = result as? [String: Any] else {
            throw BrowserCoordinatorError.interactionBlocked(
                "No actionable control exists at that point."
            )
        }
        let tag = object["tag"] as? String ?? "element"
        let inputType = object["inputType"] as? String ?? ""
        let href = object["href"] as? String ?? ""
        let formMethod = object["formMethod"] as? String ?? ""
        let name = object["name"] as? String ?? tag
        let navigationURL = URL(string: href)
        let readOnlyNavigation = tag == "a"
            && formMethod.isEmpty
            && navigationURL?.scheme?.lowercased() == "https"
        return BrowserHitTarget(
            summary: name.isEmpty ? tag : "\(tag) \(name)",
            isSecureInput: inputType == "password" || inputType == "file",
            isReadOnlyNavigation: readOnlyNavigation,
            navigationURL: readOnlyNavigation ? navigationURL : nil
        )
    }

    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) async throws {
        _ = try await webView.callAsyncJavaScript(
            """
            const point = {x: Number(x), y: Number(y)};
            let target = document.elementFromPoint(point.x, point.y);
            let scrollable = (element) => {
              for (let current = element; current; current = current.parentElement) {
                const style = getComputedStyle(current);
                const overflowY = style.overflowY;
                const overflowX = style.overflowX;
                if ((current.scrollHeight > current.clientHeight && ['auto','scroll','overlay'].includes(overflowY)) ||
                    (current.scrollWidth > current.clientWidth && ['auto','scroll','overlay'].includes(overflowX))) {
                  return current;
                }
              }
              return document.scrollingElement || document.documentElement;
            };
            const container = scrollable(target);
            container.scrollBy({left: Number(deltaX), top: Number(deltaY), behavior: 'instant'});
            return {x: container.scrollLeft, y: container.scrollTop};
            """,
            arguments: [
                "x": point.x,
                "y": point.y,
                "deltaX": deltaX,
                "deltaY": deltaY
            ],
            in: nil,
            contentWorld: .defaultClient
        )
        try await settle()
    }

    func click(at point: CGPoint) async throws {
        let result = try await webView.callAsyncJavaScript(
            """
            const element = document.elementFromPoint(Number(x), Number(y));
            if (!element) return {ok:false, reason:'no element at coordinate'};
            const control = element.closest('a,button,input,select,textarea,[role="button"],[role="link"]') || element;
            const tag = control.tagName.toLowerCase();
            const inputType = tag === 'input' ? (control.type || 'text').toLowerCase() : '';
            if (inputType === 'password' || inputType === 'file') {
              return {ok:false, reason:'secure or file input requires user takeover'};
            }
            const form = control.form;
            if (form && (form.method || 'get').toLowerCase() !== 'get') {
              return {ok:false, reason:'non-GET form requires approval'};
            }
            control.focus({preventScroll:true});
            control.click();
            return {ok:true};
            """,
            arguments: ["x": point.x, "y": point.y],
            in: nil,
            contentWorld: .defaultClient
        )
        try requireSuccessfulInteraction(result)
        try await settle()
    }

    func type(_ text: String, mode: BrowserTypeMode, at point: CGPoint) async throws {
        let result = try await webView.callAsyncJavaScript(
            """
            const element = document.elementFromPoint(Number(x), Number(y));
            const control = element?.closest('input,textarea,[contenteditable="true"]');
            if (!control) return {ok:false, reason:'no editable control at coordinate'};
            const inputType = control.tagName.toLowerCase() === 'input'
              ? (control.type || 'text').toLowerCase() : '';
            if (inputType === 'password' || inputType === 'file') {
              return {ok:false, reason:'secure or file input requires user takeover'};
            }
            control.focus({preventScroll:true});
            if (control.isContentEditable) {
              control.textContent = mode === 'append' ? control.textContent + text : text;
            } else {
              control.value = mode === 'append' ? control.value + text : text;
            }
            control.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:text}));
            control.dispatchEvent(new Event('change', {bubbles:true}));
            return {ok:true};
            """,
            arguments: [
                "x": point.x,
                "y": point.y,
                "text": text,
                "mode": mode.rawValue
            ],
            in: nil,
            contentWorld: .defaultClient
        )
        try requireSuccessfulInteraction(result)
        try await settle()
    }

    func press(_ key: String) async throws {
        let result = try await webView.callAsyncJavaScript(
            """
            const control = document.activeElement;
            if (!control || control === document.body) return {ok:false, reason:'no focused control'};
            const form = control.form;
            if (key === 'Enter' && form && (form.method || 'get').toLowerCase() !== 'get') {
              return {ok:false, reason:'non-GET form requires approval'};
            }
            control.dispatchEvent(new KeyboardEvent('keydown', {key, bubbles:true}));
            control.dispatchEvent(new KeyboardEvent('keyup', {key, bubbles:true}));
            if (key === 'Enter' && form) form.requestSubmit();
            return {ok:true};
            """,
            arguments: ["key": key],
            in: nil,
            contentWorld: .page
        )
        try requireSuccessfulInteraction(result)
        try await settle()
    }

    func visibleText() async throws -> String {
        let result = try await webView.callAsyncJavaScript(
            "return document.body?.innerText || '';",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        return result as? String ?? ""
    }

    func capture(
        representation: BrowserRepresentation,
        inputBackend: String?
    ) async throws -> BrowserFrame {
        let before = try await metrics()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 1_280
        configuration.afterScreenUpdates = true
        let image = try await snapshot(configuration)
        let after = try await metrics()
        guard before.documentURL == after.documentURL,
              before.scrollX == after.scrollX,
              before.scrollY == after.scrollY,
              before.width == after.width,
              before.height == after.height else {
            throw BrowserCoordinatorError.staleFrame
        }
        let targetWidth = 1_280
        let targetHeight = max(1, Int(
            (Double(targetWidth) * webView.bounds.height / webView.bounds.width).rounded()
        ))
        let bitmap = try rasterizedBitmap(
            image,
            width: targetWidth,
            height: targetHeight
        )
        guard
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else {
            throw BrowserCoordinatorError.snapshotUnavailable
        }
        guard data.count <= BrowserTool.maximumImageBytes else {
            throw BrowserCoordinatorError.imageTooLarge
        }

        revision += 1
        let frameID = UUID()
        currentFrameID = frameID
        currentImageWidth = bitmap.pixelsWide
        currentImageHeight = bitmap.pixelsHigh
        capturedViewSize = webView.bounds.size
        capturedMetrics = after
        let pageURL = webView.url?.absoluteString ?? ""
        let origin = webView.url.map { url in
            guard let scheme = url.scheme, let host = url.host else { return "" }
            return "\(scheme)://\(host)"
        } ?? ""
        return BrowserFrame(
            sessionID: id,
            documentID: documentID,
            frameID: frameID,
            revision: revision,
            validatedOrigin: origin,
            pageURL: pageURL,
            pageTitle: webView.title ?? "",
            image: ModelImage(
                data: data,
                width: bitmap.pixelsWide,
                height: bitmap.pixelsHigh
            ),
            scrollX: after.scrollX,
            scrollY: after.scrollY,
            visualStability: "sampled",
            representation: representation,
            inputBackend: inputBackend
        )
    }

    func close() {
        stopAutomation()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func stopAutomation() {
        navigationTimeoutTask?.cancel()
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil
        snapshotTimeoutTask?.cancel()
        snapshotContinuation?.resume(throwing: CancellationError())
        snapshotContinuation = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolveNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentID = UUID()
        currentFrameID = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if allowsTestURLs { return .allow }
        do {
            try await BrowserDestinationPolicy.validateResolvedDestination(url)
            return .allow
        } catch {
            if navigationAction.targetFrame?.isMainFrame != false {
                resolveNavigation(.failure(error))
            }
            return .cancel
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        resolveNavigation(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        resolveNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resolveNavigation(.failure(
            BrowserCoordinatorError.navigationFailed("The WebContent process terminated.")
        ))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let requestURL = navigationAction.request.url {
            webView.load(URLRequest(url: requestURL))
        }
        return nil
    }

    private func navigate(_ start: () -> WKNavigation?) async throws {
        guard navigationContinuation == nil else {
            throw BrowserCoordinatorError.navigationFailed("Another navigation is active.")
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                guard start() != nil else {
                    resolveNavigation(.failure(
                        BrowserCoordinatorError.navigationFailed("WebKit rejected the request.")
                    ))
                    return
                }
                navigationTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.resolveNavigation(.failure(
                        BrowserCoordinatorError.navigationTimedOut
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.webView.stopLoading()
                self?.resolveNavigation(.failure(CancellationError()))
            }
        }
    }

    private func resolveNavigation(_ result: Result<Void, any Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        continuation.resume(with: result)
    }

    private func snapshot(_ configuration: WKSnapshotConfiguration) async throws -> NSImage {
        guard snapshotContinuation == nil else {
            throw BrowserCoordinatorError.snapshotUnavailable
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                snapshotContinuation = continuation
                snapshotTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.resolveSnapshot(.failure(
                        BrowserCoordinatorError.snapshotUnavailable
                    ))
                }
                webView.takeSnapshot(with: configuration) { [weak self] image, error in
                    Task { @MainActor in
                        if let error {
                            self?.resolveSnapshot(.failure(error))
                        } else if let image {
                            self?.resolveSnapshot(.success(image))
                        } else {
                            self?.resolveSnapshot(.failure(
                                BrowserCoordinatorError.snapshotUnavailable
                            ))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveSnapshot(.failure(CancellationError()))
            }
        }
    }

    private func resolveSnapshot(_ result: Result<NSImage, any Error>) {
        guard let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        continuation.resume(with: result)
    }

    private func rasterizedBitmap(
        _ image: NSImage,
        width: Int,
        height: Int
    ) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw BrowserCoordinatorError.snapshotUnavailable
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func metrics() async throws -> BrowserMetrics {
        let result = try await webView.callAsyncJavaScript(
            """
            return {
              url: location.href,
              scrollX: window.scrollX,
              scrollY: window.scrollY,
              width: window.visualViewport?.width || window.innerWidth,
              height: window.visualViewport?.height || window.innerHeight
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let object = result as? [String: Any] else {
            throw BrowserCoordinatorError.snapshotUnavailable
        }
        return BrowserMetrics(
            documentURL: object["url"] as? String ?? "",
            scrollX: object["scrollX"] as? Double ?? 0,
            scrollY: object["scrollY"] as? Double ?? 0,
            width: object["width"] as? Double ?? 0,
            height: object["height"] as? Double ?? 0
        )
    }

    private func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        try await Task.sleep(for: .milliseconds(200))
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !webView.isLoading else {
            throw BrowserCoordinatorError.navigationTimedOut
        }
        try await Task.sleep(for: .milliseconds(300))
        try Task.checkCancellation()
    }

    private func requireSuccessfulInteraction(_ result: Any?) throws {
        guard let object = result as? [String: Any],
              object["ok"] as? Bool == true else {
            let reason = (result as? [String: Any])?["reason"] as? String
                ?? "The page rejected the visual action."
            throw BrowserCoordinatorError.interactionBlocked(reason)
        }
    }

}

private struct BrowserMetrics: Equatable {
    let documentURL: String
    let scrollX: Double
    let scrollY: Double
    let width: Double
    let height: Double
}

private struct BrowserHitTarget {
    let summary: String
    let isSecureInput: Bool
    let isReadOnlyNavigation: Bool
    let navigationURL: URL?
}