import Foundation

public protocol LLMTool: Sendable {
    var definition: ToolDefinition { get }
    func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool
    func stabilizedArguments(
        _ arguments: [String: JSONValue],
        previousArguments: [[String: JSONValue]]
    ) -> [String: JSONValue]
    func canonicalArgumentsForStabilization(
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue]?
    func successfulResultReuseKey(arguments: [String: JSONValue]) -> String?
    func toolCallBudgetCost(arguments: [String: JSONValue]) -> Int
    func requiresExclusiveRound(arguments: [String: JSONValue]) -> Bool
    func cancelAll() async
    func execute(arguments: [String: JSONValue]) async throws -> String
    func executeOutput(arguments: [String: JSONValue]) async throws -> ToolOutput
}

public extension LLMTool {
    func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        false
    }

    func stabilizedArguments(
        _ arguments: [String: JSONValue],
        previousArguments: [[String: JSONValue]]
    ) -> [String: JSONValue] {
        arguments
    }

    func canonicalArgumentsForStabilization(
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue]? {
        nil
    }

    func successfulResultReuseKey(arguments: [String: JSONValue]) -> String? {
        nil
    }

    func toolCallBudgetCost(arguments: [String: JSONValue]) -> Int {
        1
    }

    func requiresExclusiveRound(arguments: [String: JSONValue]) -> Bool {
        false
    }

    func cancelAll() async {}

    func executeOutput(arguments: [String: JSONValue]) async throws -> ToolOutput {
        ToolOutput(content: try await execute(arguments: arguments))
    }
}

public struct ToolOutput: Equatable, Sendable {
    public let content: String
    public let images: [ModelImage]

    public init(content: String, images: [ModelImage] = []) {
        self.content = content
        self.images = images
    }
}

public enum ToolRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTool(String)
    case invalidOutputLimit(Int)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTool(let name):
            "A tool named '\(name)' is already registered."
        case .invalidOutputLimit(let limit):
            "The Tool output limit must be at least 32 bytes, not \(limit)."
        case .unknownTool(let name):
            "The model requested an unknown tool named '\(name)'."
        }
    }
}

public struct ToolExecution: Equatable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]
    public let content: String
    public let succeeded: Bool
    public let errorType: String?
    public let images: [ModelImage]

    public init(
        name: String,
        arguments: [String: JSONValue],
        content: String,
        succeeded: Bool,
        images: [ModelImage] = []
    ) {
        self.init(
            name: name,
            arguments: arguments,
            content: content,
            succeeded: succeeded,
            errorType: nil,
            images: images
        )
    }

    public init(
        name: String,
        arguments: [String: JSONValue],
        content: String,
        succeeded: Bool,
        errorType: String?,
        images: [ModelImage] = []
    ) {
        self.name = name
        self.arguments = arguments
        self.content = content
        self.succeeded = succeeded
        self.errorType = errorType
        self.images = images
    }
}

public actor ToolRuntime {
    private let tools: [String: any LLMTool]
    private let serialGates: [String: ToolSerialGate]
    private let outputLimitBytes: Int

    public init(tools: [any LLMTool], outputLimitBytes: Int = 16 * 1_024) throws {
        guard outputLimitBytes >= 32 else {
            throw ToolRuntimeError.invalidOutputLimit(outputLimitBytes)
        }
        var registeredTools: [String: any LLMTool] = [:]
        for tool in tools {
            let name = tool.definition.function.name
            guard registeredTools[name] == nil else {
                throw ToolRuntimeError.duplicateTool(name)
            }
            registeredTools[name] = tool
        }

        self.tools = registeredTools
    self.serialGates = registeredTools.mapValues { _ in ToolSerialGate() }
        self.outputLimitBytes = outputLimitBytes
    }

    public var definitions: [ToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.function.name < $1.function.name }
    }

    public func isConcurrencySafe(_ call: ToolCall) -> Bool {
        guard let tool = tools[call.function.name] else {
            return false
        }
        return tool.isConcurrencySafe(arguments: call.function.arguments)
    }

    public func stabilizedCall(
        _ call: ToolCall,
        previousArguments: [[String: JSONValue]]
    ) -> ToolCall {
        guard let tool = tools[call.function.name] else { return call }
        return ToolCall(
            type: call.type,
            function: ToolFunctionCall(
                index: call.function.index,
                name: call.function.name,
                arguments: tool.stabilizedArguments(
                    call.function.arguments,
                    previousArguments: previousArguments
                )
            )
        )
    }

    public func canonicalArgumentsForStabilization(
        _ call: ToolCall
    ) -> [String: JSONValue]? {
        tools[call.function.name]?.canonicalArgumentsForStabilization(
            call.function.arguments
        )
    }

    public func successfulResultReuseKey(_ call: ToolCall) -> String? {
        tools[call.function.name]?.successfulResultReuseKey(
            arguments: call.function.arguments
        )
    }

    public func toolCallBudgetCost(_ call: ToolCall) -> Int {
        guard let tool = tools[call.function.name] else { return 1 }
        return max(0, tool.toolCallBudgetCost(arguments: call.function.arguments))
    }

    public func requiresExclusiveRound(_ call: ToolCall) -> Bool {
        tools[call.function.name]?.requiresExclusiveRound(
            arguments: call.function.arguments
        ) ?? false
    }

    public func cancelAll() async {
        let cleanupTasks = tools.values.map { tool in
            Task.detached {
                await tool.cancelAll()
            }
        }
        for task in cleanupTasks {
            await task.value
        }
    }

    public func execute(_ call: ToolCall) async -> ToolExecution {
        let name = call.function.name
        guard let tool = tools[name] else {
            return ToolExecution(
                name: name,
                arguments: call.function.arguments,
                content: errorContent(
                    code: "unknown_tool",
                    message: ToolRuntimeError.unknownTool(name).localizedDescription
                ),
                succeeded: false,
                errorType: String(reflecting: ToolRuntimeError.self)
            )
        }

        if !tool.isConcurrencySafe(arguments: call.function.arguments),
           let gate = serialGates[name] {
            do {
                try await gate.acquire()
            } catch {
                return failedExecution(call: call, error: error)
            }
            if Task.isCancelled {
                await gate.release()
                return failedExecution(call: call, error: CancellationError())
            }
            let execution = await execute(tool: tool, call: call)
            await gate.release()
            return execution
        }
        return await execute(tool: tool, call: call)
    }

    private func execute(tool: any LLMTool, call: ToolCall) async -> ToolExecution {
        do {
            let output = try await tool.executeOutput(arguments: call.function.arguments)
            return ToolExecution(
                name: call.function.name,
                arguments: call.function.arguments,
                content: Self.boundedContent(output.content, limitBytes: outputLimitBytes),
                succeeded: true,
                images: output.images
            )
        } catch {
            return failedExecution(call: call, error: error)
        }
    }

    private func failedExecution(call: ToolCall, error: any Error) -> ToolExecution {
        ToolExecution(
            name: call.function.name,
            arguments: call.function.arguments,
            content: errorContent(code: "tool_failed", message: error.localizedDescription),
            succeeded: false,
            errorType: String(reflecting: type(of: error))
        )
    }

    private func errorContent(code: String, message: String) -> String {
        func encoded(_ value: String) -> Data? {
            try? JSONEncoder().encode([
                "error": code,
                "message": value
            ])
        }
        if let data = encoded(message), data.count <= outputLimitBytes {
            return String(decoding: data, as: UTF8.self)
        }
        let bytes = Array(message.utf8)
        var prefixCount = min(bytes.count, outputLimitBytes / 2)
        while prefixCount > 0 {
            let candidate = String(decoding: bytes.prefix(prefixCount), as: UTF8.self)
                + "...[truncated]"
            if let data = encoded(candidate), data.count <= outputLimitBytes {
                return String(decoding: data, as: UTF8.self)
            }
            prefixCount /= 2
        }
        return "{\"error\":\"tool_failed\"}"
    }

    /// Truncates oversized tool output on a UTF-8 boundary so a single result can
    /// never overflow the model context, appending a marker the model can see.
    static func boundedContent(_ content: String, limitBytes: Int) -> String {
        guard content.lengthOfBytes(using: .utf8) > limitBytes else {
            return content
        }
        if let data = content.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return boundedJSONContent(content, limitBytes: limitBytes)
        }
        let marker = "\n…[truncated]"
        let budget = max(0, limitBytes - marker.lengthOfBytes(using: .utf8))
        var truncated = content
        while truncated.lengthOfBytes(using: .utf8) > budget, !truncated.isEmpty {
            truncated.removeLast()
        }
        return truncated + marker
    }

    private static func boundedJSONContent(
        _ content: String,
        limitBytes: Int
    ) -> String {
        let original = content.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let originalError = original?["error"] as? String
        let originalMessage = original?["message"] as? String

        func encoded(_ tail: String) -> Data? {
            var object: [String: Any] = ["output_truncated": true]
            if let originalError {
                object["error"] = originalError
                object["message"] = tail
            } else {
                object["content_tail"] = tail
            }
            return try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        var tail = originalError == nil ? content : originalMessage ?? ""
        while !tail.isEmpty {
            if let data = encoded(tail), data.count <= limitBytes {
                return String(decoding: data, as: UTF8.self)
            }
            tail.removeFirst(max(1, tail.count / 4))
        }
        if let originalError,
           let data = try? JSONSerialization.data(
                withJSONObject: [
                    "error": originalError,
                    "output_truncated": true
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
           ), data.count <= limitBytes {
            return String(decoding: data, as: UTF8.self)
        }
        return "{\"output_truncated\":true}"
    }
}

private actor ToolSerialGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isAcquired = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard isAcquired else {
            isAcquired = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isAcquired = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}