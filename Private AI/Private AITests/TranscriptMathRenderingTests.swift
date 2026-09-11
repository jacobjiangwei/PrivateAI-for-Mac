import WebKit
import XCTest
@testable import Private_AI

@MainActor
final class TranscriptMathRenderingTests: XCTestCase {
    func testRendersStandardMathWithBundledResources() async throws {
        let webView = WKWebView()
        let navigation = NavigationWaiter()
        try await navigation.load(
            TranscriptWebView.document,
            baseURL: try XCTUnwrap(TranscriptWebView.resourceBaseURL),
            in: webView
        )

        let result = try await webView.callAsyncJavaScript(
            #"""
            const host = document.createElement('div');
            host.innerHTML = markdown(String.raw`Inline $a^2+b^2=c^2$ and \(x+y\).

            $$\frac{a}{b}$$

            \[\sqrt{2}\]

            Code: ` + '`$notMath$`');
            renderMath(host);
            document.body.appendChild(host);
            await document.fonts.load('16px KaTeX_Main');
            return {
              codeText: host.querySelector('code')?.textContent,
              displayCount: host.querySelectorAll('.katex-display').length,
              errorCount: host.querySelectorAll('.katex-error').length,
              fontLoaded: document.fonts.check('16px KaTeX_Main'),
              mathCount: host.querySelectorAll('.katex').length,
              mathMLCount: host.querySelectorAll('.katex-mathml math').length
            };
            """#,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let values = try XCTUnwrap(result as? [String: Any])

        XCTAssertEqual(values["mathCount"] as? Int, 4)
        XCTAssertEqual(values["displayCount"] as? Int, 2)
        XCTAssertEqual(values["mathMLCount"] as? Int, 4)
        XCTAssertEqual(values["errorCount"] as? Int, 0)
        XCTAssertEqual(values["codeText"] as? String, "$notMath$")
        XCTAssertEqual(values["fontLoaded"] as? Bool, true)
    }

    func testStreamingUpdatesKeepOnlyLatestPendingRender() async throws {
        let webView = WKWebView()
        let coordinator = TranscriptWebView.Coordinator(onCopy: { _ in })
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        let message = MessageRecord(
            sequence: 1,
            role: .assistant,
            content: "initial",
            status: .streaming
        )
        coordinator.render([message])
        webView.loadHTMLString(
            TranscriptWebView.document,
            baseURL: try XCTUnwrap(TranscriptWebView.resourceBaseURL)
        )

        _ = try await waitForContent("initial", in: webView)
        _ = try await webView.callAsyncJavaScript(
            """
            window.privateAIRenderCount = 0;
            const productionRender = render;
            render = messages => {
              const deadline = performance.now() + 8;
              while (performance.now() < deadline) {}
              window.privateAIRenderCount += 1;
              productionRender(messages);
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        for index in 1...100 {
            message.content = "token \(index)"
            coordinator.render([message])
        }

        let renderCount = try await waitForContent("token 100", in: webView)
        XCTAssertGreaterThan(renderCount, 0)
        XCTAssertLessThanOrEqual(renderCount, 2)
    }

    private func waitForContent(_ expected: String, in webView: WKWebView) async throws -> Int {
        for _ in 0..<500 {
            let result = try await webView.callAsyncJavaScript(
                """
                const content = document.querySelector('article.assistant .content')?.textContent;
                return content === expected ? (window.privateAIRenderCount || 0) : -1;
                """,
                arguments: ["expected": expected],
                in: nil,
                contentWorld: .page
            )
            if let renderCount = result as? Int, renderCount >= 0 {
                return renderCount
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for transcript content: \(expected)")
        return -1
    }

    func testSixMessageKindsPreserveRawContentAndPatchOnlyChangedMessage() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 440, height: 700))
        let navigation = NavigationWaiter()
        try await navigation.load(TranscriptWebView.document, baseURL: try XCTUnwrap(TranscriptWebView.resourceBaseURL), in: webView)
        let result = try await webView.callAsyncJavaScript(
            #"""
            const raw = JSON.stringify({messages: [{role: 'system', content: '<script>throw 1</script> $notMath$'}], tools: [{function: {name: 'probe'}}]});
            const roles = ['user', 'modelInput', 'thinking', 'toolCall', 'toolResult', 'assistant'];
            const messages = roles.map((role, index) => ({id: String(index), role, content: role === 'modelInput' ? raw : role, status: 'complete'}));
            renderPatch(messages, messages.map(message => message.id));
            const originalRaw = document.querySelector('article.modelInput pre');
            renderPatch([{...messages[5], content: 'Final answer'}], messages.map(message => message.id));
            return {
              titles: Array.from(document.querySelectorAll('.message-heading'), node => node.textContent),
              raw: originalRaw.textContent,
              preserved: originalRaw === document.querySelector('article.modelInput pre'),
              scriptCount: document.querySelectorAll('article script').length,
              mathCount: document.querySelectorAll('article.modelInput .katex').length,
              complete: document.querySelector('article.assistant .content').textContent,
              overflow: document.documentElement.scrollWidth > innerWidth,
              expectedRaw: JSON.stringify(JSON.parse(raw), null, 2),
              storedRaw: document.querySelector('article.modelInput').renderedMessage.content === raw
            };
            """#,
            arguments: [:], in: nil, contentWorld: .page
        )
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["titles"] as? [String], ["You", "AI input (raw)", "AI thinking", "AI tool call", "Tool result", "AI reply"])
        XCTAssertEqual(values["raw"] as? String, values["expectedRaw"] as? String)
        XCTAssertEqual(values["storedRaw"] as? Bool, true)
        XCTAssertEqual(values["preserved"] as? Bool, true)
        XCTAssertEqual(values["scriptCount"] as? Int, 0)
        XCTAssertEqual(values["mathCount"] as? Int, 0)
        XCTAssertEqual(values["complete"] as? String, "Final answer")
        XCTAssertEqual(values["overflow"] as? Bool, false)
    }

        func testInputJSONUsesOnlyWholeMessageFoldingAndPreservesSource() async throws {
                let webView = WKWebView()
                let navigation = NavigationWaiter()
                try await navigation.load(TranscriptWebView.document, baseURL: try XCTUnwrap(TranscriptWebView.resourceBaseURL), in: webView)
                let result = try await webView.callAsyncJavaScript(
                        #"""
                        const source = '{"messages":[{"role":"user","content":"Hello"}],"think":true}';
                        const message = {id: 'json-input', role: 'modelInput', content: source, status: 'streaming'};
                        render([message]);
                        const article = document.getElementById('message-json-input');
                        const formatted = article.querySelector('pre').textContent;
                        article.querySelector('details').open = false;
                        render([{...message, status: 'complete'}]);
                        return {
                            formatted,
                            source: article.renderedMessage.content,
                            folds: article.querySelectorAll('details').length,
                            staysClosed: !article.querySelector('details').open,
                            invalid: rawDisplayText({role: 'modelInput', content: '{partial'}),
                            plain: rawDisplayText({role: 'modelInput', content: 'Plain text'}),
                            tool: rawDisplayText({role: 'toolResult', content: source})
                        };
                        """#,
                        arguments: [:], in: nil, contentWorld: .page
                )
                let values = try XCTUnwrap(result as? [String: Any])
                XCTAssertEqual(values["formatted"] as? String,
                    "{\n  \"messages\": [\n    {\n      \"role\": \"user\",\n      \"content\": \"Hello\"\n    }\n  ],\n  \"think\": true\n}")
                let raw = #"{"messages":[{"role":"user","content":"Hello"}],"think":true}"#
                XCTAssertEqual(values["source"] as? String, raw)
                XCTAssertEqual(values["tool"] as? String, raw)
                XCTAssertEqual(values["folds"] as? Int, 1)
                XCTAssertEqual(values["staysClosed"] as? Bool, true)
                XCTAssertEqual(values["invalid"] as? String, "{partial")
                XCTAssertEqual(values["plain"] as? String, "Plain text")
        }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(with: error)
    }

    private func fail(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}