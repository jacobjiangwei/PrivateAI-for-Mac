import ExecutionKit
import Foundation
import LLMCore
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import PrivateAITools

@Suite(
    "Terminal Tool Integration and Contracts",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_EXECUTOR_DIAGNOSTICS"] == "1")
)
struct TerminalToolTests {
    @Test("advertises one strict run-wait-stop capability")
    func schema() throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()
        let function = tool.definition.function
        let schema = try #require(function.parameters.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)

        #expect(function.name == "terminal")
        #expect(function.description.contains("Only one terminal job can be active"))
        #expect(function.description.contains("do not propose multiple run calls"))
        #expect(function.description.contains("command-specific limits"))
        #expect(schema["additionalProperties"] == .bool(false))
        #expect(properties["action"] != nil)
        #expect(properties["command"] != nil)
        #expect(properties["job_id"] != nil)
        #expect(properties["checkpoint_seconds"] != nil)
    }

    @Test("runs a real zsh command through the execution handler")
    func realCommand() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        let result = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("printf '%s' \"$PWD\"")
        ])

        #expect(result["status"] == .string("succeeded"))
        #expect(result["exit_code"] == .number(0))
        #expect(result["stdout_tail"] == .string(try canonicalPath(
            fixture.workspace.path
        )))
        #expect(result["output_truncated"] == .bool(false))
    }

    @Test("runs a real loopback network diagnostic")
    func networkDiagnostic() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        let result = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("/sbin/ping -c 1 127.0.0.1")
        ])
        let output = try #require(result["stdout_tail"]?.stringValue)

        #expect(result["status"] == .string("succeeded"))
        #expect(result["exit_code"] == .number(0))
        #expect(output.contains("1 packets transmitted"))
        #expect(output.contains("0.0% packet loss"))
    }

    @Test("runs a real process inspection command")
    func processInspection() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        let result = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("/bin/ps -p $$ -o pid=,ppid=,comm=")
        ])
        let fields = result["stdout_tail"]?.stringValue?
            .split(whereSeparator: { $0.isWhitespace }) ?? []

        #expect(result["status"] == .string("succeeded"))
        #expect(fields.count >= 3)
        #expect(fields.first.flatMap { Int32($0) } != nil)
    }

    @Test("creates compiles and runs source code")
    func compileAndRunCode() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()
        let command = """
        printf 'print("compiled-terminal-ok")\n' > Demo.swift && \
        /usr/bin/xcrun swiftc Demo.swift -o demo && ./demo
        """

        let result = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string(command)
        ])

        #expect(result["status"] == .string("succeeded"))
        #expect(result["stdout_tail"] == .string("compiled-terminal-ok\n"))
        #expect(FileManager.default.isExecutableFile(
            atPath: fixture.workspace.appending(path: "demo").path
        ))
    }

    @Test("reports a missing executable as a real shell failure")
    func missingExecutable() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        let result = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("/privateai/definitely-missing-command")
        ])

        #expect(result["status"] == .string("failed"))
        #expect(result["exit_code"] == .number(127))
        #expect(result["stderr_tail"]?.stringValue?.contains("no such file") == true)
    }

    @Test("keeps a running job alive for wait and stop")
    func checkpointLifecycle() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        let running = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("printf begin; /bin/sleep 30"),
            "checkpoint_seconds": .number(1)
        ])
        let jobID = try #require(running["job_id"]?.stringValue)
        let stopped = try await executeObject(tool, arguments: [
            "action": .string("stop"),
            "job_id": .string(jobID)
        ])

        #expect(running["status"] == .string("running"))
        #expect(running["stdout_since_checkpoint"] == .string("begin"))
        #expect(running["available_actions"] == .array([.string("wait"), .string("stop")]))
        #expect(stopped["status"] == .string("cancelled"))
    }

    @Test("does not start a second command while a checkpointed job is running")
    func oneActiveJob() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()
        let running = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("/bin/sleep 30"),
            "checkpoint_seconds": .number(1)
        ])
        let jobID = try #require(running["job_id"]?.stringValue)

        await #expect(throws: TerminalToolError.jobAlreadyRunning(jobID)) {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string("pwd")
            ])
        }
        _ = try await tool.execute(arguments: [
            "action": .string("stop"),
            "job_id": .string(jobID)
        ])
    }

    @Test("rejects working directories outside the authorized workspace")
    func workspaceBoundary() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        await #expect(throws: TerminalToolError.workingDirectoryOutsideWorkspace("/tmp")) {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string("pwd"),
                "working_directory": .string("/tmp")
            ])
        }
    }

    @Test("rejects unknown and malformed job identifiers")
    func jobOwnership() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        await #expect(throws: TerminalToolError.invalidJobID("not-a-uuid")) {
            try await tool.execute(arguments: [
                "action": .string("wait"),
                "job_id": .string("not-a-uuid")
            ])
        }
        let foreignID = UUID().uuidString
        await #expect(throws: TerminalToolError.jobNotOwned(foreignID)) {
            try await tool.execute(arguments: [
                "action": .string("stop"),
                "job_id": .string(foreignID)
            ])
        }
    }

    @Test("strictly rejects action-specific extra arguments")
    func strictArguments() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        await #expect(throws: CapabilityToolError.unexpectedArguments(["job_id"])) {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string("pwd"),
                "job_id": .string(UUID().uuidString)
            ])
        }
    }

    @Test("rejects model-generated commands that cannot fit the next context")
    func modelCommandLimit() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        await #expect(throws: CapabilityToolError.invalidArgument("command")) {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string(String(
                    repeating: "x",
                    count: TerminalTool.maximumModelCommandBytes + 1
                ))
            ])
        }
    }

    @Test("returns bounded valid JSON while retaining the complete local log")
    func boundedModelResult() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()

        let content = try await tool.execute(arguments: [
            "action": .string("run"),
            "command": .string("/usr/bin/head -c 100000 /dev/zero")
        ])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        let result = try #require(value.objectValue)
        let logDirectory = try #require(result["log_directory"]?.stringValue)

        #expect(content.utf8.count <= TerminalTool.maximumResultBytes)
        #expect(result["status"] == .string("succeeded"))
        #expect(result["output_truncated"] == .bool(true))
        #expect(result["log_truncated"] == .bool(false))
        #expect(result["stdout_bytes_since_checkpoint"] == .number(100_000))
        #expect(try Data(contentsOf: URL(fileURLWithPath: logDirectory)
            .appending(path: "stdout.log")).count == 100_000)
    }

    @Test("cleanup stops a job that continued after its checkpoint")
    func cleanupStopsCheckpointedJob() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()
        let running = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string(
                "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait"
            ),
            "checkpoint_seconds": .number(1)
        ])
        let childPID = try #require(Int32(
            running["stdout_tail"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ))

        await tool.cancelAll()

        #expect(await terminalProcessDisappeared(childPID))
    }

    @Test("cancellation before the first checkpoint retains ownership until cleanup")
    func preCheckpointCancellation() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try fixture.makeTool()
        let pidFile = fixture.workspace.appending(path: "child.pid")
        let run = Task {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string(
                    "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > child.pid; wait"
                ),
                "checkpoint_seconds": .number(30)
            ])
        }
        let childPID = try await waitForChildPID(at: pidFile)

        run.cancel()
        _ = try? await run.value
        await tool.cancelAll()

        #expect(await terminalProcessDisappeared(childPID))
        let second = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("printf second")
        ])
        #expect(second["status"] == .string("succeeded"))
    }

    @Test("unknown outcome retains ownership when shutdown cannot prove cleanup")
    func unknownOutcomeRetainsOwnership() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let worker = UnresolvedWorker()
        let tool = try TerminalTool(workspace: fixture.workspace, worker: worker)
        let result = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("pwd")
        ])
        let jobID = try #require(result["job_id"]?.stringValue)

        await tool.cancelAll()

        await #expect(throws: TerminalToolError.jobAlreadyRunning(jobID)) {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string("printf second")
            ])
        }
        #expect(await worker.shutdownCount == 1)
    }

    @Test("cleanup blocks a concurrent command from acquiring ownership")
    func cleanupBlocksConcurrentRun() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let worker = BlockingShutdownWorker()
        let tool = try TerminalTool(workspace: fixture.workspace, worker: worker)
        _ = try await executeObject(tool, arguments: [
            "action": .string("run"),
            "command": .string("pwd")
        ])
        let cleanup = Task { await tool.cancelAll() }
        await worker.waitUntilShutdownStarts()

        await #expect(throws: TerminalToolError.cleanupInProgress) {
            try await tool.execute(arguments: [
                "action": .string("run"),
                "command": .string("printf second")
            ])
        }

        await worker.finishShutdown(result: false)
        await cleanup.value
    }

    @Test("worker stopping rejection does not retain phantom ownership")
    func workerStoppingDoesNotRetainOwnership() async throws {
        let fixture = try TerminalFixture()
        defer { fixture.remove() }
        let tool = try TerminalTool(
            workspace: fixture.workspace,
            worker: StoppingWorker()
        )
        let expected = TerminalToolError.workerFailure(
            code: "worker_stopping",
            message: "worker is stopping"
        )

        for _ in 0..<2 {
            await #expect(throws: expected) {
                try await tool.execute(arguments: [
                    "action": .string("run"),
                    "command": .string("pwd")
                ])
            }
        }
    }
}

private actor StoppingWorker: ExecutionWorkerServing {
    func handle(_ request: ExecutionWorkerRequest) async -> ExecutionWorkerResponse {
        .failure(
            requestID: request.requestID,
            code: "worker_stopping",
            message: "worker is stopping"
        )
    }

    func shutdown() async -> Bool { true }
}

private actor UnresolvedWorker: ExecutionWorkerServing {
    private(set) var shutdownCount = 0

    func handle(_ request: ExecutionWorkerRequest) async -> ExecutionWorkerResponse {
        switch request.action {
        case .run:
            let execution = request.executionRequest!
            return .success(
                requestID: request.requestID,
                observation: ExecutionObservation(
                    jobID: execution.jobID,
                    status: .unknownOutcome,
                    command: execution.command,
                    workingDirectory: execution.workingDirectory,
                    elapsedSeconds: 0,
                    exitCode: nil,
                    stdoutSinceCheckpoint: "",
                    stderrSinceCheckpoint: "",
                    stdoutTail: "",
                    stderrTail: "",
                    stdoutBytesSinceCheckpoint: 0,
                    stderrBytesSinceCheckpoint: 0,
                    outputTruncated: false,
                    logURL: URL(fileURLWithPath: "/tmp/unresolved"),
                    failureMessage: "cleanup unverified"
                )
            )
        case .wait, .stop:
            return .failure(
                requestID: request.requestID,
                code: "unknown_job",
                message: "cleanup remains unresolved"
            )
        }
    }

    func shutdown() async -> Bool {
        shutdownCount += 1
        return false
    }
}

private actor BlockingShutdownWorker: ExecutionWorkerServing {
    private var shutdownStarted = false
    private var shutdownContinuation: CheckedContinuation<Bool, Never>?

    func handle(_ request: ExecutionWorkerRequest) async -> ExecutionWorkerResponse {
        switch request.action {
        case .run:
            let execution = request.executionRequest!
            return .success(
                requestID: request.requestID,
                observation: ExecutionObservation(
                    jobID: execution.jobID,
                    status: .unknownOutcome,
                    command: execution.command,
                    workingDirectory: execution.workingDirectory,
                    elapsedSeconds: 0,
                    exitCode: nil,
                    stdoutSinceCheckpoint: "",
                    stderrSinceCheckpoint: "",
                    stdoutTail: "",
                    stderrTail: "",
                    stdoutBytesSinceCheckpoint: 0,
                    stderrBytesSinceCheckpoint: 0,
                    outputTruncated: false,
                    logURL: URL(fileURLWithPath: "/tmp/unresolved"),
                    failureMessage: "cleanup unverified"
                )
            )
        case .wait, .stop:
            return .failure(
                requestID: request.requestID,
                code: "unknown_job",
                message: "cleanup remains unresolved"
            )
        }
    }

    func shutdown() async -> Bool {
        shutdownStarted = true
        return await withCheckedContinuation { shutdownContinuation = $0 }
    }

    func waitUntilShutdownStarts() async {
        while !shutdownStarted {
            try? await ContinuousClock().sleep(for: .milliseconds(1))
        }
    }

    func finishShutdown(result: Bool) {
        shutdownContinuation?.resume(returning: result)
        shutdownContinuation = nil
    }
}

private func waitForChildPID(at url: URL) async throws -> Int32 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           let processID = Int32(value) {
            return processID
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadNoSuchFile)
}

private func terminalProcessDisappeared(_ processID: Int32) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if kill(processID, 0) == -1, errno == ESRCH { return true }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return kill(processID, 0) == -1 && errno == ESRCH
}

private func canonicalPath(_ path: String) throws -> String {
    try path.withCString { pointer in
        guard let resolved = realpath(pointer, nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func executeObject(
    _ tool: TerminalTool,
    arguments: [String: JSONValue]
) async throws -> [String: JSONValue] {
    let content = try await tool.execute(arguments: arguments)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
    return try #require(value.objectValue)
}

private final class TerminalFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let logs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "privateai-terminal-tool-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
    }

    func makeTool() throws -> TerminalTool {
        let service = try PipeExecutionService(logsDirectory: logs)
        return try TerminalTool(
            workspace: workspace,
            worker: ExecutionWorkerHandler(service: service)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}