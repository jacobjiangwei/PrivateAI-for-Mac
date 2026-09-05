import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Web Tool")
struct WebToolTests {
    @Test("rejects non-HTTPS fetch")
    func rejectsInsecureFetch() async {
        let tool = WebTool()

        await #expect(throws: WebToolError.invalidURL) {
            try await tool.execute(arguments: [
                "action": .string("fetch"),
                "url": .string("http://example.com")
            ])
        }
    }

    @Test("rejects private destinations")
    func rejectsPrivateDestination() async {
        let tool = WebTool()

        await #expect(throws: WebToolError.disallowedHost("127.0.0.1")) {
            try await tool.execute(arguments: [
                "action": .string("fetch"),
                "url": .string("https://127.0.0.1/private")
            ])
        }
    }
}

@Suite(
    "Live Web Tool",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_LIVE_WEB_TESTS"] == "1")
)
struct LiveWebToolTests {
    @Test("fetches and extracts a real public page")
    func fetch() async throws {
        let tool = WebTool()
        let result = try await tool.execute(arguments: [
            "action": .string("fetch"),
            "url": .string("https://example.com")
        ])
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        let object = try #require(payload.objectValue)

        #expect(object["url"]?.stringValue == "https://example.com/")
        #expect(object["content_type"]?.stringValue == "text/html")
        #expect(object["encoding"] == .string("utf-8"))
        let text = try #require(object["text"]?.stringValue)
        #expect(text.contains("Example Domain") == true)
        // HTML is reduced to readable text so the tool result stays within the context window.
        #expect(text.contains("<html") == false)
        #expect(text.contains("<body") == false)
        #expect(text.isEmpty == false)
    }

    @Test("searches the public web")
    func search() async throws {
        let tool = WebTool()
        let result = try await tool.execute(arguments: [
            "action": .string("search"),
            "query": .string("Swift programming language official"),
            "maximum_results": .number(3)
        ])

        #expect(result.contains("results"))
        #expect(result.contains("swift"))
    }
}