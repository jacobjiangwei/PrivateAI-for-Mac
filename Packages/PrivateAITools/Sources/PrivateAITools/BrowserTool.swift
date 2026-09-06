import Foundation
import LLMCore

public enum BrowserToolError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier(String)
    case sessionNotOwned(String)
    case sessionAlreadyOpen(String)
    case missingFrame

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            "Browser identifier '\(value)' is not a valid UUID."
        case .sessionNotOwned(let value):
            "Browser session '\(value)' does not belong to this run."
        case .sessionAlreadyOpen(let value):
            "Browser session '\(value)' is already active. Close it before opening another."
        case .missingFrame:
            "The browser did not return a screenshot frame."
        }
    }
}

public actor BrowserTool: LLMTool {
    public static let maximumImageBytes = 2 * 1_024 * 1_024

    public nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: PrivateAIToolPrompts.Browser.name,
            description: PrivateAIToolPrompts.Browser.tool,
            parameters: objectSchema(
                properties: [
                    "action": stringSchema(
                        description: PrivateAIToolPrompts.Browser.action,
                        values: [
                            "open", "search", "observe", "scroll", "click", "type",
                            "press", "back", "forward", "close"
                        ]
                    ),
                    "url": stringSchema(description: PrivateAIToolPrompts.Browser.url),
                    "query": stringSchema(description: PrivateAIToolPrompts.Browser.query),
                    "session_id": stringSchema(
                        description: PrivateAIToolPrompts.Browser.sessionID
                    ),
                    "frame_id": stringSchema(description: PrivateAIToolPrompts.Browser.frameID),
                    "representation": stringSchema(
                        description: PrivateAIToolPrompts.Browser.representation,
                        values: ["raw"]
                    ),
                    "x": integerSchema(
                        description: PrivateAIToolPrompts.Browser.x,
                        range: 0...8_191
                    ),
                    "y": integerSchema(
                        description: PrivateAIToolPrompts.Browser.y,
                        range: 0...8_191
                    ),
                    "delta_x": integerSchema(
                        description: PrivateAIToolPrompts.Browser.deltaX,
                        range: -4_096...4_096
                    ),
                    "delta_y": integerSchema(
                        description: PrivateAIToolPrompts.Browser.deltaY,
                        range: -4_096...4_096
                    ),
                    "text": stringSchema(description: PrivateAIToolPrompts.Browser.text),
                    "mode": stringSchema(
                        description: PrivateAIToolPrompts.Browser.mode,
                        values: ["replace", "append"]
                    ),
                    "key": stringSchema(
                        description: PrivateAIToolPrompts.Browser.key,
                        values: [
                            "Enter", "Escape", "Tab", "ArrowUp", "ArrowDown",
                            "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End"
                        ]
                    )
                ],
                required: ["action"]
            )
        )
    )

    private let backend: any BrowserServing
    private var sessionID: UUID?
    private var frameID: UUID?

    public init(backend: any BrowserServing) {
        self.backend = backend
    }

    public nonisolated func requiresExclusiveRound(arguments: [String: JSONValue]) -> Bool {
        true
    }

    public func cancelAll() async {
        guard let sessionID else { return }
        await backend.cancel(sessionIDs: [sessionID])
        self.sessionID = nil
        frameID = nil
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        try await executeOutput(arguments: arguments).content
    }

    public func executeOutput(arguments: [String: JSONValue]) async throws -> ToolOutput {
        let request = try request(arguments)
        let response = try await backend.execute(request)
        if case .close(let closedSessionID) = request,
           closedSessionID == sessionID {
            sessionID = nil
            frameID = nil
        }
        if let frame = response.frame {
            guard frame.image.data.count <= Self.maximumImageBytes else {
                throw CapabilityToolError.invalidArgument("browser_image")
            }
            if sessionID == nil {
                sessionID = frame.sessionID
            }
            frameID = frame.frameID
            return ToolOutput(
                content: try encodeFrame(response.status, frame: frame),
                images: [frame.image]
            )
        }
        return ToolOutput(content: try encodeToolResult(.object([
            "status": .string(response.status)
        ])))
    }

    private func request(_ arguments: [String: JSONValue]) throws -> BrowserRequest {
        let values = CapabilityArguments(values: arguments)
        let action = try values.requiredString("action", maximumBytes: 32)
        switch action {
        case "open":
            try values.requireOnly(["action", "url"])
            let url = try publicHTTPSURL(values.requiredString("url", maximumBytes: 4_096))
            return sessionID.map { .navigate(sessionID: $0, url: url) } ?? .open(url)
        case "search":
            try values.requireOnly(["action", "query"])
            let query = try values.requiredString("query", maximumBytes: 2_048)
            if let sessionID {
                var components = URLComponents(string: "https://www.bing.com/search")!
                components.queryItems = [URLQueryItem(name: "q", value: query)]
                guard let url = components.url else {
                    throw CapabilityToolError.invalidArgument("query")
                }
                return .navigate(sessionID: sessionID, url: url)
            }
            return .search(query)
        case "observe":
            try values.requireOnly(["action", "session_id", "frame_id", "representation"])
            if values.values["frame_id"] != nil {
                let candidate = try identifier(values, name: "frame_id")
                guard candidate == frameID else {
                    throw BrowserToolError.invalidIdentifier(
                        candidate.uuidString.lowercased()
                    )
                }
            }
            let representationValue = try values.optionalString(
                "representation",
                maximumBytes: 16
            ) ?? "raw"
            guard representationValue == BrowserRepresentation.raw.rawValue else {
                throw CapabilityToolError.invalidArgument("representation")
            }
            return .observe(
                sessionID: try ownedSessionID(values),
                representation: .raw
            )
        case "scroll":
            try values.requireOnly([
                "action", "session_id", "frame_id", "x", "y", "delta_x", "delta_y"
            ])
            return .scroll(
                sessionID: try ownedSessionID(values),
                frameID: try identifier(values, name: "frame_id"),
                x: try requiredInteger(values, name: "x", range: 0...8_191),
                y: try requiredInteger(values, name: "y", range: 0...8_191),
                deltaX: try requiredInteger(values, name: "delta_x", range: -4_096...4_096),
                deltaY: try requiredInteger(values, name: "delta_y", range: -4_096...4_096)
            )
        case "click":
            try values.requireOnly(["action", "session_id", "frame_id", "x", "y"])
            return .click(
                sessionID: try ownedSessionID(values),
                frameID: try identifier(values, name: "frame_id"),
                x: try requiredInteger(values, name: "x", range: 0...8_191),
                y: try requiredInteger(values, name: "y", range: 0...8_191)
            )
        case "type":
            try values.requireOnly([
                "action", "session_id", "frame_id", "x", "y", "text", "mode"
            ])
            let modeValue = try values.optionalString("mode", maximumBytes: 16) ?? "replace"
            guard let mode = BrowserTypeMode(rawValue: modeValue) else {
                throw CapabilityToolError.invalidArgument("mode")
            }
            return .type(
                sessionID: try ownedSessionID(values),
                frameID: try identifier(values, name: "frame_id"),
                x: try requiredInteger(values, name: "x", range: 0...8_191),
                y: try requiredInteger(values, name: "y", range: 0...8_191),
                text: try values.requiredString("text", maximumBytes: 8_192),
                mode: mode
            )
        case "press":
            try values.requireOnly(["action", "session_id", "frame_id", "key"])
            let key = try values.requiredString("key", maximumBytes: 32)
            guard Self.allowedKeys.contains(key) else {
                throw CapabilityToolError.invalidArgument("key")
            }
            return .press(
                sessionID: try ownedSessionID(values),
                frameID: try identifier(values, name: "frame_id"),
                key: key
            )
        case "back":
            try values.requireOnly(["action", "session_id"])
            return .back(sessionID: try ownedSessionID(values))
        case "forward":
            try values.requireOnly(["action", "session_id"])
            return .forward(sessionID: try ownedSessionID(values))
        case "close":
            try values.requireOnly(["action", "session_id"])
            return .close(sessionID: try ownedSessionID(values))
        default:
            throw CapabilityToolError.unsupportedAction(action)
        }
    }

    private func ownedSessionID(_ values: CapabilityArguments) throws -> UUID {
        let candidate = try identifier(values, name: "session_id")
        guard candidate == sessionID else {
            throw BrowserToolError.sessionNotOwned(candidate.uuidString.lowercased())
        }
        return candidate
    }

    private func identifier(_ values: CapabilityArguments, name: String) throws -> UUID {
        let value = try values.requiredString(name, maximumBytes: 64)
        guard let identifier = UUID(uuidString: value) else {
            throw BrowserToolError.invalidIdentifier(value)
        }
        return identifier
    }

    private func requiredInteger(
        _ values: CapabilityArguments,
        name: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = try values.optionalInteger(name, range: range) else {
            throw CapabilityToolError.missingArgument(name)
        }
        return value
    }

    private func publicHTTPSURL(_ value: String) throws -> URL {
        do {
            return try BrowserDestinationPolicy.validatedURL(value)
        } catch {
            throw CapabilityToolError.invalidArgument("url")
        }
    }

    private func encodeFrame(_ status: String, frame: BrowserFrame) throws -> String {
        var value: [String: JSONValue] = [
            "status": .string(status),
            "session_id": .string(frame.sessionID.uuidString.lowercased()),
            "document_id": .string(frame.documentID.uuidString.lowercased()),
            "frame_id": .string(frame.frameID.uuidString.lowercased()),
            "revision": .number(Double(frame.revision)),
            "validated_origin": .string(frame.validatedOrigin),
            "page_url": .string(frame.pageURL),
            "page_title": .string(frame.pageTitle),
            "image_width": .number(Double(frame.image.width ?? 0)),
            "image_height": .number(Double(frame.image.height ?? 0)),
            "coordinate_space": .string(frame.coordinateSpace),
            "scroll_x": .number(frame.scrollX),
            "scroll_y": .number(frame.scrollY),
            "visual_stability": .string(frame.visualStability),
            "representation": .string(frame.representation.rawValue),
            "mark_ids": .array(frame.markIDs.map(JSONValue.string)),
            "untrusted_page_content": .bool(true)
        ]
        if let inputBackend = frame.inputBackend {
            value["input_backend"] = .string(inputBackend)
        }
        return try encodeToolResult(.object(value))
    }

    private static let allowedKeys: Set<String> = [
        "Enter", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft",
        "ArrowRight", "PageUp", "PageDown", "Home", "End"
    ]
}