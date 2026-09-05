import ExecutionKit
import Foundation
import LLMCore

public struct TerminalExecutionBackend: Sendable {
    fileprivate let worker: ExecutionWorkerProcessClient

    public init(workerExecutableURL: URL, logsDirectory: URL) {
        worker = ExecutionWorkerProcessClient(
            executableURL: workerExecutableURL,
            logsDirectory: logsDirectory
        )
    }

    @discardableResult
    public func shutdown() async -> Bool {
        await worker.shutdown()
    }
}

public enum TerminalToolError: Error, Equatable, LocalizedError, Sendable {
    case workingDirectoryNotFound(String)
    case workingDirectoryOutsideWorkspace(String)
    case jobNotOwned(String)
    case invalidJobID(String)
    case jobAlreadyRunning(String)
    case cleanupInProgress
    case workerFailure(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .workingDirectoryNotFound(let path):
            "The working directory '\(path)' does not exist or is not a directory."
        case .workingDirectoryOutsideWorkspace(let path):
            "The working directory '\(path)' is outside the authorized workspace."
        case .jobNotOwned(let jobID):
            "Execution job '\(jobID)' does not belong to this terminal session."
        case .invalidJobID(let jobID):
            "Execution job ID '\(jobID)' is not a valid UUID."
        case .jobAlreadyRunning(let jobID):
            "Execution job '\(jobID)' is still running. Wait for or stop it before starting another command."
        case .cleanupInProgress:
            "Terminal cleanup is still in progress."
        case .workerFailure(let code, let message):
            "Execution worker failed (\(code)): \(message)"
        }
    }
}

public actor TerminalTool: LLMTool {
    public static let maximumModelCommandBytes = 2 * 1_024
    public static let maximumResultBytes = 4 * 1_024

    public nonisolated let definition: ToolDefinition

    private let workspace: URL
    private let workspaceIdentity: ExecutionDirectoryIdentity
    private let worker: any ExecutionWorkerServing
    private let defaultTimeoutSeconds: Int
    private let fileManager: FileManager
    private var ownedJobs = Set<ExecutionJobID>()
    private var isCleaningUp = false

    public init(
        workspace: URL,
        worker: any ExecutionWorkerServing,
        defaultTimeoutSeconds: Int = 1_800,
        fileManager: FileManager = .default
    ) throws {
        let resolvedWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: resolvedWorkspace.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw TerminalToolError.workingDirectoryNotFound(resolvedWorkspace.path)
        }
        self.workspace = resolvedWorkspace
        workspaceIdentity = try ExecutionDirectoryIdentity(
            directoryURL: resolvedWorkspace
        )
        self.worker = worker
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.fileManager = fileManager
        definition = ToolDefinition(
            function: ToolFunctionDefinition(
                name: PrivateAIToolPrompts.Terminal.name,
                description: PrivateAIToolPrompts.Terminal.tool(
                    workspacePath: resolvedWorkspace.path
                ),
                parameters: objectSchema(
                    properties: [
                        "action": stringSchema(
                            description: PrivateAIToolPrompts.Terminal.action,
                            values: ["run", "wait", "stop"]
                        ),
                        "command": stringSchema(
                            description: PrivateAIToolPrompts.Terminal.command
                        ),
                        "working_directory": stringSchema(
                            description: PrivateAIToolPrompts.Terminal.workingDirectory
                        ),
                        "job_id": stringSchema(
                            description: PrivateAIToolPrompts.Terminal.jobID
                        ),
                        "checkpoint_seconds": integerSchema(
                            description: PrivateAIToolPrompts.Terminal.checkpointSeconds,
                            range: 1...300
                        ),
                        "timeout_seconds": integerSchema(
                            description: PrivateAIToolPrompts.Terminal.timeoutSeconds,
                            range: 1...86_400
                        )
                    ],
                    required: ["action"]
                )
            )
        )
    }

    public init(
        workspace: URL,
        backend: TerminalExecutionBackend,
        defaultTimeoutSeconds: Int = 1_800,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            workspace: workspace,
            worker: backend.worker,
            defaultTimeoutSeconds: defaultTimeoutSeconds,
            fileManager: fileManager
        )
    }

    public nonisolated func toolCallBudgetCost(
        arguments: [String: JSONValue]
    ) -> Int {
        switch arguments["action"]?.stringValue {
        case "wait", "stop": 0
        default: 1
        }
    }

    public func cancelAll() async {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }
        let jobs = ownedJobs
        for jobID in jobs {
            let response = await worker.handle(.stop(jobID))
            if let observation = response.observation,
                    observation.status != .running,
                    observation.status != .unknownOutcome {
                ownedJobs.remove(jobID)
            }
        }
        if await worker.shutdown() {
            ownedJobs.removeAll()
        }
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        guard !isCleaningUp else {
            throw TerminalToolError.cleanupInProgress
        }
        let values = CapabilityArguments(values: arguments)
        let action = try values.requiredString("action", maximumBytes: 16)
        let response: ExecutionWorkerResponse

        switch action {
        case "run":
            try values.requireOnly([
                "action", "command", "working_directory", "checkpoint_seconds",
                "timeout_seconds"
            ])
            if let activeJob = ownedJobs.first {
                throw TerminalToolError.jobAlreadyRunning(
                    activeJob.rawValue.uuidString.lowercased()
                )
            }
            let workingDirectory = try resolveWorkingDirectory(
                try values.optionalString("working_directory", maximumBytes: 4_096)
            )
            let request = try ExecutionRequest(
                command: try values.requiredString(
                    "command",
                    maximumBytes: Self.maximumModelCommandBytes
                ),
                workspaceRoot: workspace,
                workspaceIdentity: workspaceIdentity,
                workingDirectory: workingDirectory,
                checkpointSeconds: try values.optionalInteger(
                    "checkpoint_seconds",
                    range: 1...300
                ) ?? ExecutionRequest.defaultCheckpointSeconds,
                timeoutSeconds: try values.optionalInteger(
                    "timeout_seconds",
                    range: 1...86_400
                ) ?? defaultTimeoutSeconds,
                interaction: .pipe
            )
            ownedJobs.insert(request.jobID)
            response = await worker.handle(.run(request))
            if let error = response.error,
               Self.provesJobDidNotStart(error.code) {
                ownedJobs.remove(request.jobID)
            }
        case "wait":
            try values.requireOnly(["action", "job_id", "checkpoint_seconds"])
            let jobID = try ownedJobID(values)
            let request = try ExecutionCheckpointRequest(
                jobID: jobID,
                checkpointSeconds: try values.optionalInteger(
                    "checkpoint_seconds",
                    range: 1...300
                ) ?? ExecutionRequest.defaultCheckpointSeconds
            )
            response = await worker.handle(.wait(request))
        case "stop":
            try values.requireOnly(["action", "job_id"])
            response = await worker.handle(.stop(try ownedJobID(values)))
        default:
            throw CapabilityToolError.unsupportedAction(action)
        }

        if let error = response.error {
            throw TerminalToolError.workerFailure(code: error.code, message: error.message)
        }
        let observation = try requireObservation(response)
          if observation.status != .running,
              observation.status != .unknownOutcome {
            ownedJobs.remove(observation.jobID)
        }
        return try encodeObservation(observation)
    }

    private func resolveWorkingDirectory(_ path: String?) throws -> URL {
        let candidate = path.map { URL(fileURLWithPath: $0) } ?? workspace
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolved, root: workspace) else {
            throw TerminalToolError.workingDirectoryOutsideWorkspace(resolved.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TerminalToolError.workingDirectoryNotFound(resolved.path)
        }
        return resolved
    }

    private func ownedJobID(_ values: CapabilityArguments) throws -> ExecutionJobID {
        let value = try values.requiredString("job_id", maximumBytes: 64)
        guard let uuid = UUID(uuidString: value) else {
            throw TerminalToolError.invalidJobID(value)
        }
        let jobID = ExecutionJobID(rawValue: uuid)
        guard ownedJobs.contains(jobID) else {
            throw TerminalToolError.jobNotOwned(value)
        }
        return jobID
    }

    private func requireObservation(
        _ response: ExecutionWorkerResponse
    ) throws -> ExecutionObservation {
        guard let observation = response.observation else {
            throw TerminalToolError.workerFailure(
                code: "missing_observation",
                message: "The execution worker returned neither an observation nor an error."
            )
        }
        return observation
    }

    private func contains(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func toolResult(_ observation: ExecutionObservation) -> JSONValue {
        .object([
            "status": .string(observation.status.rawValue),
            "job_id": .string(observation.jobID.rawValue.uuidString.lowercased()),
            "command": .string(observation.command),
            "working_directory": .string(observation.workingDirectory.path),
            "elapsed_seconds": .number(observation.elapsedSeconds),
            "exit_code": observation.exitCode.map { .number(Double($0)) } ?? .null,
            "stdout_since_checkpoint": .string(observation.stdoutSinceCheckpoint),
            "stderr_since_checkpoint": .string(observation.stderrSinceCheckpoint),
            "stdout_tail": .string(observation.stdoutTail),
            "stderr_tail": .string(observation.stderrTail),
            "stdout_bytes_since_checkpoint": .number(
                Double(observation.stdoutBytesSinceCheckpoint)
            ),
            "stderr_bytes_since_checkpoint": .number(
                Double(observation.stderrBytesSinceCheckpoint)
            ),
            "output_truncated": .bool(observation.outputTruncated),
            "log_truncated": .bool(observation.logTruncated),
            "log_directory": .string(observation.logURL.path),
            "failure_message": observation.failureMessage.map(JSONValue.string) ?? .null,
            "available_actions": observation.status == .running
                ? .array([.string("wait"), .string("stop")])
                : .array([])
        ])
    }

    private func encodeObservation(_ observation: ExecutionObservation) throws -> String {
        guard case .object(var object) = toolResult(observation) else {
            return "{}"
        }
        let dynamicKeys = [
            "stdout_since_checkpoint", "stderr_since_checkpoint", "stdout_tail",
            "stderr_tail", "command", "failure_message", "working_directory",
            "log_directory"
        ]
        var maximumDynamicBytes = 2_048

        while true {
            let encoded = try encodeToolResult(.object(object))
            if encoded.utf8.count <= Self.maximumResultBytes {
                return encoded
            }
            var changed = false
            for key in dynamicKeys {
                guard let value = object[key]?.stringValue,
                      value.utf8.count > maximumDynamicBytes else {
                    continue
                }
                object[key] = .string(boundedTail(value, maximumBytes: maximumDynamicBytes))
                changed = true
            }
            object["output_truncated"] = .bool(true)
            if maximumDynamicBytes > 64 {
                maximumDynamicBytes /= 2
            } else if !changed {
                throw TerminalToolError.workerFailure(
                    code: "result_too_large",
                    message: "The bounded execution metadata exceeded the model result limit."
                )
            }
        }
    }

    private func boundedTail(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        let marker = "...[truncated]\n"
        let budget = max(0, maximumBytes - marker.utf8.count)
        var tail = value
        while tail.utf8.count > budget, !tail.isEmpty {
            tail.removeFirst()
        }
        return marker + tail
    }

    private nonisolated static func provesJobDidNotStart(_ code: String) -> Bool {
        [
            "worker_unavailable",
            "worker_stopping",
            "worker_recovery_pending",
            "invalid_protocol_request",
            "invalid_request",
            "unsupported_interaction",
            "working_directory_outside_workspace",
            "too_many_active_jobs"
        ].contains(code)
    }
}