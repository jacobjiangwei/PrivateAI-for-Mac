import Foundation
import LLMCore

public enum BrowserRepresentation: String, Codable, Equatable, Sendable {
    case raw
    case marks
}

public enum BrowserTypeMode: String, Codable, Equatable, Sendable {
    case replace
    case append
}

public enum BrowserRequest: Equatable, Sendable {
    case open(URL)
    case navigate(sessionID: UUID, url: URL)
    case search(String)
    case observe(sessionID: UUID, representation: BrowserRepresentation)
    case scroll(
        sessionID: UUID,
        frameID: UUID,
        x: Int,
        y: Int,
        deltaX: Int,
        deltaY: Int
    )
    case click(sessionID: UUID, frameID: UUID, x: Int, y: Int)
    case type(
        sessionID: UUID,
        frameID: UUID,
        x: Int,
        y: Int,
        text: String,
        mode: BrowserTypeMode
    )
    case press(sessionID: UUID, frameID: UUID, key: String)
    case back(sessionID: UUID)
    case forward(sessionID: UUID)
    case close(sessionID: UUID)
}

public struct BrowserFrame: Equatable, Sendable {
    public let sessionID: UUID
    public let documentID: UUID
    public let frameID: UUID
    public let revision: Int
    public let validatedOrigin: String
    public let pageURL: String
    public let pageTitle: String
    public let image: ModelImage
    public let coordinateSpace: String
    public let scrollX: Double
    public let scrollY: Double
    public let visualStability: String
    public let representation: BrowserRepresentation
    public let markIDs: [String]
    public let inputBackend: String?

    public init(
        sessionID: UUID,
        documentID: UUID,
        frameID: UUID,
        revision: Int,
        validatedOrigin: String,
        pageURL: String,
        pageTitle: String,
        image: ModelImage,
        coordinateSpace: String = "image_pixels_top_left",
        scrollX: Double = 0,
        scrollY: Double = 0,
        visualStability: String = "stable",
        representation: BrowserRepresentation = .raw,
        markIDs: [String] = [],
        inputBackend: String? = nil
    ) {
        self.sessionID = sessionID
        self.documentID = documentID
        self.frameID = frameID
        self.revision = revision
        self.validatedOrigin = validatedOrigin
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.image = image
        self.coordinateSpace = coordinateSpace
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.visualStability = visualStability
        self.representation = representation
        self.markIDs = markIDs
        self.inputBackend = inputBackend
    }
}

public struct BrowserResponse: Equatable, Sendable {
    public let status: String
    public let frame: BrowserFrame?

    public init(status: String, frame: BrowserFrame? = nil) {
        self.status = status
        self.frame = frame
    }
}

public protocol BrowserServing: Sendable {
    func execute(_ request: BrowserRequest) async throws -> BrowserResponse
    func cancel(sessionIDs: Set<UUID>) async
}

public extension BrowserServing {
    func cancel(sessionIDs: Set<UUID>) async {}
}