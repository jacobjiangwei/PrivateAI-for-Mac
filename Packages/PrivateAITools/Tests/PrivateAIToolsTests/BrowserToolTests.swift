import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Browser Tool")
struct BrowserToolTests {
    @Test("opens a public page and returns a screenshot Tool output")
    func opensAndReturnsImage() async throws {
        let backend = BrowserFixtureBackend()
        let tool = BrowserTool(backend: backend)

        let output = try await tool.executeOutput(arguments: [
            "action": .string("open"),
            "url": .string("https://example.com")
        ])
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(output.content.utf8))

        #expect(payload.objectValue?["coordinate_space"] == .string("image_pixels_top_left"))
        #expect(payload.objectValue?["image_width"] == .number(1_280))
        #expect(output.images.count == 1)
        #expect(output.images[0].data == Data([1, 2, 3]))
        #expect(await backend.requests == [.open(URL(string: "https://example.com")!)])
    }

    @Test("requires the owned session and exact frame for scrolling")
    func validatesOwnedSessionAndFrame() async throws {
        let backend = BrowserFixtureBackend()
        let tool = BrowserTool(backend: backend)
        _ = try await tool.executeOutput(arguments: [
            "action": .string("open"),
            "url": .string("https://example.com")
        ])

        _ = try await tool.executeOutput(arguments: [
            "action": .string("scroll"),
            "session_id": .string(BrowserFixtureBackend.sessionID.uuidString),
            "frame_id": .string(BrowserFixtureBackend.frameID.uuidString),
            "x": .number(640),
            "y": .number(400),
            "delta_x": .number(0),
            "delta_y": .number(600)
        ])

        #expect(await backend.requests.count == 2)
        await #expect(throws: BrowserToolError.sessionNotOwned(UUID.zero.uuidString.lowercased())) {
            try await tool.executeOutput(arguments: [
                "action": .string("observe"),
                "session_id": .string(UUID.zero.uuidString)
            ])
        }
    }

    @Test("rejects private URLs and unexpected action arguments")
    func rejectsUnsafeArguments() async {
        let tool = BrowserTool(backend: BrowserFixtureBackend())

        await #expect(throws: CapabilityToolError.invalidArgument("url")) {
            try await tool.executeOutput(arguments: [
                "action": .string("open"),
                "url": .string("https://127.0.0.1/private")
            ])
        }
        await #expect(throws: CapabilityToolError.unexpectedArguments(["text"])) {
            try await tool.executeOutput(arguments: [
                "action": .string("search"),
                "query": .string("Swift"),
                "text": .string("unexpected")
            ])
        }
        await #expect(throws: CapabilityToolError.invalidArgument("url")) {
            try await tool.executeOutput(arguments: [
                "action": .string("open"),
                "url": .string("https://[::1]/private")
            ])
        }
    }

    @Test("is always exclusive within a model round")
    func requiresExclusiveRound() {
        let tool = BrowserTool(backend: BrowserFixtureBackend())
        #expect(tool.requiresExclusiveRound(arguments: ["action": .string("observe")]))
    }
}

private actor BrowserFixtureBackend: BrowserServing {
    static let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let documentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let frameID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private(set) var requests: [BrowserRequest] = []

    func execute(_ request: BrowserRequest) async throws -> BrowserResponse {
        requests.append(request)
        if case .close = request {
            return BrowserResponse(status: "closed")
        }
        return BrowserResponse(
            status: "ready",
            frame: BrowserFrame(
                sessionID: Self.sessionID,
                documentID: Self.documentID,
                frameID: Self.frameID,
                revision: requests.count,
                validatedOrigin: "https://example.com",
                pageURL: "https://example.com/",
                pageTitle: "Example",
                image: ModelImage(data: Data([1, 2, 3]), width: 1_280, height: 800)
            )
        )
    }
}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}