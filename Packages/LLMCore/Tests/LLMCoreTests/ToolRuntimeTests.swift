import Foundation
import Testing
@testable import LLMCore

@Suite("Tool Runtime")
struct ToolRuntimeTests {
    @Test("advertises registered capability schemas")
    func advertisesDefinitions() async throws {
        let runtime = try ToolRuntime(tools: [TestTool()])
        let definitions = await runtime.definitions

        #expect(definitions.count == 1)
        #expect(definitions[0].type == "function")
        #expect(definitions[0].function.name == "web")
    }

    @Test("passes model arguments to the registered implementation")
    func executesWithArguments() async throws {
        let tool = TestTool()
        let runtime = try ToolRuntime(tools: [tool])
        let call = ToolCall(
            function: ToolFunctionCall(
                index: 0,
                name: "web",
                arguments: [
                    "action": .string("search"),
                    "query": .string("Suzhou weather"),
                    "maximum_results": .number(3)
                ]
            )
        )

        let execution = await runtime.execute(call)
        let receivedArguments = await tool.receivedArguments

        #expect(execution.succeeded)
        #expect(execution.name == "web")
        #expect(execution.arguments == call.function.arguments)
        #expect(execution.content == "fixture result")
        #expect(receivedArguments == call.function.arguments)
    }

    @Test("rejects duplicate model-facing tool names")
    func rejectsDuplicateNames() async throws {
        let first = TestTool()
        let second = TestTool()

        #expect(throws: ToolRuntimeError.duplicateTool("web")) {
            try ToolRuntime(
                tools: [
                    first,
                    second
                ]
            )
        }
    }

    @Test("rejects output limits too small for a valid error payload")
    func rejectsTinyOutputLimit() {
        #expect(throws: ToolRuntimeError.invalidOutputLimit(31)) {
            try ToolRuntime(tools: [], outputLimitBytes: 31)
        }
    }

    @Test("serializes a default tool across concurrent runtime calls")
    func serializesAcrossCalls() async throws {
        let tool = SerialRuntimeProbeTool()
        let runtime = try ToolRuntime(tools: [tool])
        let first = ToolCall(function: ToolFunctionCall(
            name: "serial_runtime_probe",
            arguments: ["value": .string("first")]
        ))
        let second = ToolCall(function: ToolFunctionCall(
            name: "serial_runtime_probe",
            arguments: ["value": .string("second")]
        ))

        async let firstExecution = runtime.execute(first)
        async let secondExecution = runtime.execute(second)
        let executions = await [firstExecution, secondExecution]

        #expect(executions.allSatisfy { $0.succeeded })
        #expect(await tool.maximumConcurrency == 1)
    }

    @Test("removes a cancelled call waiting on the serial gate")
    func cancelsSerialGateWaiter() async throws {
        let tool = BlockingSerialRuntimeTool()
        let runtime = try ToolRuntime(tools: [tool])
        let firstCall = ToolCall(function: ToolFunctionCall(
            name: "blocking_serial_runtime",
            arguments: ["value": .string("first")]
        ))
        let secondCall = ToolCall(function: ToolFunctionCall(
            name: "blocking_serial_runtime",
            arguments: ["value": .string("second")]
        ))

        let first = Task { await runtime.execute(firstCall) }
        await tool.waitUntilStarted()
        let second = Task { await runtime.execute(secondCall) }
        await Task.yield()
        second.cancel()
        await tool.releaseFirst()
        let firstExecution = await first.value
        let secondExecution = await second.value
        let thirdCall = ToolCall(function: ToolFunctionCall(
            name: "blocking_serial_runtime",
            arguments: ["value": .string("third")]
        ))
        let thirdExecution = await withTaskGroup(
            of: ToolExecution?.self,
            returning: ToolExecution?.self
        ) { group in
            group.addTask { await runtime.execute(thirdCall) }
            group.addTask {
                try? await ContinuousClock().sleep(for: .milliseconds(500))
                return nil
            }
            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }

        #expect(firstExecution.succeeded)
        #expect(!secondExecution.succeeded)
        #expect(thirdExecution?.succeeded == true)
        #expect(await tool.executionCount == 2)
    }

    @Test("keeps thrown and unknown-tool errors as bounded valid JSON")
    func boundsErrorJSON() async throws {
        let limit = 128
        let runtime = try ToolRuntime(
            tools: [LongErrorTool()],
            outputLimitBytes: limit
        )
        let thrown = await runtime.execute(ToolCall(function: ToolFunctionCall(
            name: "long_error",
            arguments: [:]
        )))
        let unknown = await runtime.execute(ToolCall(function: ToolFunctionCall(
            name: String(repeating: "\\\"\n", count: 1_000),
            arguments: [:]
        )))

        for execution in [thrown, unknown] {
            #expect(!execution.succeeded)
            #expect(execution.content.utf8.count <= limit)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(execution.content.utf8))
                    as? [String: String]
            )
            #expect(object["error"] != nil)
            #expect(execution.errorType?.isEmpty == false)
        }
    }

    @Test("truncates oversized tool output on a UTF-8 boundary instead of failing")
    func truncatesOversizedOutput() async throws {
        let limit = 64
        let runtime = try ToolRuntime(tools: [OversizedTool()], outputLimitBytes: limit)
        let call = ToolCall(
            function: ToolFunctionCall(index: 0, name: "oversized", arguments: [:])
        )

        let execution = await runtime.execute(call)

        #expect(execution.succeeded)
        #expect(execution.content.lengthOfBytes(using: .utf8) <= limit)
        #expect(execution.content.hasSuffix("…[truncated]"))
        // Valid UTF-8 (no split multibyte character) — round-trips through Data.
        #expect(String(data: Data(execution.content.utf8), encoding: .utf8) == execution.content)
    }

    @Test("keeps oversized structured output as valid bounded JSON")
    func truncatesJSONAsJSON() async throws {
        let limit = 128
        let runtime = try ToolRuntime(
            tools: [OversizedJSONTool()],
            outputLimitBytes: limit
        )
        let execution = await runtime.execute(ToolCall(function: ToolFunctionCall(
            name: "oversized_json",
            arguments: [:]
        )))

        #expect(execution.succeeded)
        #expect(execution.content.utf8.count <= limit)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(execution.content.utf8))
                as? [String: Any]
        )
        #expect(object["output_truncated"] as? Bool == true)
    }

    @Test("preserves error identity when structured failures are truncated again")
    func truncatesErrorJSONWithIdentity() throws {
        let content = String(decoding: try JSONSerialization.data(
            withJSONObject: [
                "error": "tool_failed",
                "message": String(repeating: "failure detail ", count: 200)
            ],
            options: [.sortedKeys]
        ), as: UTF8.self)

        let bounded = ToolRuntime.boundedContent(content, limitBytes: 128)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(bounded.utf8)) as? [String: Any]
        )

        #expect(bounded.utf8.count <= 128)
        #expect(object["error"] as? String == "tool_failed")
        #expect(object["output_truncated"] as? Bool == true)
        #expect(object["content_tail"] == nil)
    }

    @Test("leaves output within the limit unchanged")
    func keepsSmallOutput() async throws {
        let runtime = try ToolRuntime(tools: [TestTool()], outputLimitBytes: 1_024)
        let call = ToolCall(
            function: ToolFunctionCall(index: 0, name: "web", arguments: [:])
        )
        let execution = await runtime.execute(call)
        #expect(execution.content == "fixture result")
    }

    @Test("forwards tool diagnostics through the active run context")
    func forwardsDiagnostics() async throws {
        let runtime = try ToolRuntime(tools: [DiagnosticTool()])
        let recorder = DiagnosticRecorder()
        let call = ToolCall(
            function: ToolFunctionCall(index: 0, name: "diagnostic", arguments: [:])
        )

        let execution = await ToolDiagnostics.$handler.withValue({ diagnostic in
            await recorder.append(diagnostic)
        }) {
            await runtime.execute(call)
        }

        let diagnostics = await recorder.values
        #expect(execution.succeeded)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].event == "tool.phase")
        #expect(diagnostics[0].level == "warning")
        #expect(diagnostics[0].data == ["status": "waiting"])
    }

    @Test("runs tool cleanup outside caller cancellation")
    func cancellationIndependentCleanup() async throws {
        let tool = CleanupCancellationProbeTool()
        let runtime = try ToolRuntime(tools: [tool])
        let cleanup = Task {
            try? await ContinuousClock().sleep(for: .seconds(30))
            await runtime.cancelAll()
        }
        cleanup.cancel()

        await cleanup.value

        #expect(await tool.cleanupWasCalled)
        #expect(await tool.cleanupObservedCancellation == false)
    }
}

private actor TestTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "web",
            description: "Fixture capability used only by ToolRuntime tests.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string")]),
                    "query": .object(["type": .string("string")]),
                    "maximum_results": .object(["type": .string("integer")])
                ])
            ])
        )
    )
    private(set) var receivedArguments: [String: JSONValue]?

    func execute(arguments: [String: JSONValue]) async throws -> String {
        receivedArguments = arguments
        return "fixture result"
    }
}

private actor DiagnosticTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "diagnostic",
            description: "Emits one diagnostic event.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        await ToolDiagnostics.record(
            "tool.phase",
            level: "warning",
            data: ["status": "waiting"]
        )
        return "done"
    }
}

private actor DiagnosticRecorder {
    private(set) var values: [ToolDiagnostic] = []

    func append(_ diagnostic: ToolDiagnostic) {
        values.append(diagnostic)
    }
}

private actor CleanupCancellationProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "cleanup_cancellation_probe",
            description: "Records cleanup cancellation state.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var cleanupWasCalled = false
    private(set) var cleanupObservedCancellation = false

    func cancelAll() {
        cleanupWasCalled = true
        cleanupObservedCancellation = Task.isCancelled
    }

    func execute(arguments: [String: JSONValue]) async throws -> String { "{}" }
}

private actor OversizedTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "oversized",
            description: "Returns output larger than the runtime limit, ending in a multibyte character.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Multibyte characters make the truncation boundary meaningful.
        String(repeating: "苏", count: 200)
    }
}

private actor OversizedJSONTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "oversized_json",
            description: "Returns oversized structured output.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "items": Array(repeating: "structured-output", count: 200)
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

private actor SerialRuntimeProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "serial_runtime_probe",
            description: "Checks serialization across ToolRuntime calls.",
            parameters: .object(["type": .string("object")])
        )
    )
    private var activeCount = 0
    private(set) var maximumConcurrency = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        activeCount -= 1
        return "done"
    }
}

private actor BlockingSerialRuntimeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "blocking_serial_runtime",
            description: "Blocks the first serial runtime call.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executionCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        if executionCount == 1 {
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return "done"
    }

    func waitUntilStarted() async {
        if executionCount > 0 { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct LongFixtureError: LocalizedError {
    var errorDescription: String? {
        String(repeating: "\\\"\n\t", count: 10_000)
    }
}

private struct LongErrorTool: LLMTool {
    let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "long_error",
            description: "Throws an oversized escaped error.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        throw LongFixtureError()
    }
}