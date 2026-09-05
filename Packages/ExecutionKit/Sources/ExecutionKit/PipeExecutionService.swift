import Foundation
import Subprocess
#if canImport(Darwin)
import Darwin
#endif

public enum ExecutionServiceError: Error, Equatable, LocalizedError, Sendable {
    case duplicateJob(ExecutionJobID)
    case unknownJob(ExecutionJobID)
    case unsupportedInteraction(ExecutionInteraction)
    case tooManyActiveJobs(Int)
    case workingDirectoryOutsideWorkspace(String)
    case processIdentityUnavailable(Int32)
    case processGroupCleanupFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .duplicateJob(let jobID):
            "Execution job '\(jobID.rawValue.uuidString)' already exists."
        case .unknownJob(let jobID):
            "Execution job '\(jobID.rawValue.uuidString)' does not exist."
        case .unsupportedInteraction(let interaction):
            "Execution interaction '\(interaction.rawValue)' is not available in the pipe executor."
        case .tooManyActiveJobs(let limit):
            "The execution worker already has the maximum of \(limit) active jobs."
        case .workingDirectoryOutsideWorkspace(let path):
            "The initial working directory '\(path)' is outside the authorized workspace."
        case .processIdentityUnavailable(let processID):
            "Could not establish the execution process identity for PID \(processID)."
        case .processGroupCleanupFailed(let processGroupID):
            "Could not safely clean execution process group \(processGroupID)."
        }
    }
}

public actor PipeExecutionService {
    private struct JobHandle {
        let state: ExecutionJobState
        let executionTask: Task<Void, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let logsDirectory: URL
    private let observationLimitBytes: Int
    private let supervisorExecutableURL: URL?
    private let maximumLogBytesPerStream: Int
    private let maximumActiveJobs: Int
    private let maximumRetainedJobs: Int
    private let maximumTotalLogBytes: Int
    private let maximumJobDirectories: Int
    private let logRetentionInterval: TimeInterval
    private var jobs: [ExecutionJobID: JobHandle] = [:]
    private var jobOrder: [ExecutionJobID] = []
    private var activeJobIDs: Set<ExecutionJobID>
    private var hasUnidentifiedRecovery: Bool

    public init(
        logsDirectory: URL,
        supervisorExecutableURL: URL? = nil,
        observationLimitBytes: Int = 8 * 1_024,
        maximumLogBytesPerStream: Int = 64 * 1_024 * 1_024,
        maximumActiveJobs: Int = 1,
        maximumRetainedJobs: Int = 128,
        maximumTotalLogBytes: Int = 1_024 * 1_024 * 1_024,
        maximumJobDirectories: Int = 512,
        logRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        self.logsDirectory = logsDirectory.standardizedFileURL
        self.supervisorExecutableURL = supervisorExecutableURL?.standardizedFileURL
        self.observationLimitBytes = observationLimitBytes
        self.maximumLogBytesPerStream = maximumLogBytesPerStream
        self.maximumActiveJobs = maximumActiveJobs
        self.maximumRetainedJobs = maximumRetainedJobs
        self.maximumTotalLogBytes = maximumTotalLogBytes
        self.maximumJobDirectories = maximumJobDirectories
        self.logRetentionInterval = logRetentionInterval
        try FileManager.default.createDirectory(
            at: self.logsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try ExecutionJobMetadataStore.prepareCurrentFormat(in: self.logsDirectory)
        let recovery = ExecutionJobMetadataStore.recoverUnfinishedJobs(
            in: self.logsDirectory
        )
        activeJobIDs = recovery.unresolvedJobIDs
        hasUnidentifiedRecovery = recovery.hasUnidentifiedJobs
        ExecutionJobMetadataStore.pruneStoredJobs(
            in: self.logsDirectory,
            retentionInterval: logRetentionInterval,
            maximumTotalLogBytes: maximumTotalLogBytes,
            maximumJobDirectories: maximumJobDirectories
        )
    }

    nonisolated static func recoverJobsAfterWorkerTermination(
        logsDirectory: URL,
        jobIDs: Set<ExecutionJobID>
    ) -> ExecutionRecoveryResult {
        ExecutionJobMetadataStore.terminateAndMarkUnknown(
            in: logsDirectory.standardizedFileURL,
            jobIDs: jobIDs
        )
    }

    var retainedJobCount: Int { jobs.count }

    public func run(_ request: ExecutionRequest) async throws -> ExecutionObservation {
        guard request.interaction != .pseudoTerminal else {
            throw ExecutionServiceError.unsupportedInteraction(request.interaction)
        }
        guard jobs[request.jobID] == nil else {
            throw ExecutionServiceError.duplicateJob(request.jobID)
        }
        let prepared = try Self.prepareRequest(request)
        let validatedRequest = prepared.request
        let occupiedSlots = activeJobIDs.count + (hasUnidentifiedRecovery ? 1 : 0)
        guard occupiedSlots < maximumActiveJobs else {
            throw ExecutionServiceError.tooManyActiveJobs(maximumActiveJobs)
        }

        let state = try ExecutionJobState(
            request: validatedRequest,
            logsDirectory: logsDirectory,
            observationLimitBytes: observationLimitBytes,
            maximumLogBytesPerStream: maximumLogBytesPerStream
        )
        activeJobIDs.insert(request.jobID)
        let executionTask = Task {
            do {
                let termination = try await Self.execute(
                    validatedRequest,
                    workingDirectory: prepared.workingDirectory,
                    supervisorExecutableURL: supervisorExecutableURL,
                    state: state
                )
                await state.complete(termination)
            } catch is CancellationError {
                await state.completeCancellation()
            } catch {
                await state.completeFailure(error)
            }
            await self.jobDidFinish(request.jobID, state: state)
        }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(
                    for: .seconds(request.timeoutSeconds)
                )
            } catch {
                return
            }
            guard await state.requestCancellation(.timedOut) else { return }
            executionTask.cancel()
        }
        Task {
            await executionTask.value
            timeoutTask.cancel()
        }
        jobs[request.jobID] = JobHandle(
            state: state,
            executionTask: executionTask,
            timeoutTask: timeoutTask
        )
        jobOrder.append(request.jobID)

        let observation = try await observe(
            request.jobID,
            checkpointSeconds: request.checkpointSeconds
        )
        await pruneRetainedJobs()
        return observation
    }

    public func wait(
        _ request: ExecutionCheckpointRequest
    ) async throws -> ExecutionObservation {
        let observation = try await observe(
            request.jobID,
            checkpointSeconds: request.checkpointSeconds
        )
        await pruneRetainedJobs()
        return observation
    }

    public func stop(_ jobID: ExecutionJobID) async throws -> ExecutionObservation {
        guard let handle = jobs[jobID] else {
            throw ExecutionServiceError.unknownJob(jobID)
        }
        if await handle.state.requestCancellation(.cancelled) {
            handle.executionTask.cancel()
        }
        await handle.executionTask.value
        let observation = await handle.state.consumeObservation()
        await pruneRetainedJobs()
        return observation
    }

    @discardableResult
    public func cancelAll(reason: ExecutionStatus = .interrupted) async -> Bool {
        let activeHandles = Array(jobs)
        for (_, handle) in activeHandles {
            if await handle.state.requestCancellation(reason) {
                handle.executionTask.cancel()
            }
        }
        for (_, handle) in activeHandles {
            await handle.executionTask.value
        }
        let recovery = ExecutionJobMetadataStore.terminateAndMarkUnknown(
            in: logsDirectory,
            jobIDs: activeJobIDs
        )
        for (jobID, handle) in activeHandles
        where await handle.state.recoveryPending
            && !recovery.unresolvedJobIDs.contains(jobID) {
            await handle.state.acknowledgePersistedRecovery()
        }
        activeJobIDs = recovery.unresolvedJobIDs
        hasUnidentifiedRecovery = recovery.hasUnidentifiedJobs
        return recovery.isResolved
    }

    private func observe(
        _ jobID: ExecutionJobID,
        checkpointSeconds: Int
    ) async throws -> ExecutionObservation {
        guard let handle = jobs[jobID] else {
            throw ExecutionServiceError.unknownJob(jobID)
        }

        return try await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await handle.state.waitUntilTerminal()
                }
                group.addTask {
                    try? await ContinuousClock().sleep(
                        for: .seconds(checkpointSeconds)
                    )
                }
                _ = await group.next()
                group.cancelAll()
            }
            try Task.checkCancellation()
            return await handle.state.consumeObservation()
        } onCancel: {
            Task {
                await self.cancel(jobID, reason: .cancelled)
            }
        }
    }

    private func cancel(_ jobID: ExecutionJobID, reason: ExecutionStatus) async {
        guard let handle = jobs[jobID],
              await handle.state.requestCancellation(reason) else {
            return
        }
        handle.executionTask.cancel()
    }

    private func pruneRetainedJobs() async {
        maintainStoredJobs()
        guard jobs.count > maximumRetainedJobs else { return }
        var retainedOrder: [ExecutionJobID] = []
        for jobID in jobOrder {
            guard let handle = jobs[jobID] else { continue }
            if jobs.count > maximumRetainedJobs, await handle.state.isTerminal {
                handle.timeoutTask.cancel()
                jobs[jobID] = nil
            } else {
                retainedOrder.append(jobID)
            }
        }
        jobOrder = retainedOrder
    }

    private func jobDidFinish(
        _ jobID: ExecutionJobID,
        state: ExecutionJobState
    ) async {
        if !(await state.recoveryPending) {
            activeJobIDs.remove(jobID)
        }
        maintainStoredJobs()
    }

    private func maintainStoredJobs() {
        ExecutionJobMetadataStore.pruneStoredJobs(
            in: logsDirectory,
            retentionInterval: logRetentionInterval,
            maximumTotalLogBytes: maximumTotalLogBytes,
            maximumJobDirectories: maximumJobDirectories
        )
    }

    private nonisolated static func execute(
        _ request: ExecutionRequest,
        workingDirectory: ExecutionPreparedWorkingDirectory,
        supervisorExecutableURL: URL?,
        state: ExecutionJobState
    ) async throws -> TerminationStatus {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: true,
                allowedDurationToNextStep: .seconds(2)
            )
        ]
        platformOptions.preSpawnProcessConfigurator = { _, fileActions in
            guard fileActions != nil else {
                throw ExecutionServiceError.workingDirectoryOutsideWorkspace(
                    request.workingDirectory.path
                )
            }
            let inheritResult = posix_spawn_file_actions_addinherit_np(
                &fileActions,
                workingDirectory.fileDescriptor
            )
            let result = try addWorkingDirectoryAction(
                to: &fileActions,
                fileDescriptor: workingDirectory.fileDescriptor
            )
            guard inheritResult == 0,
                  result == 0,
                  posix_spawn_file_actions_addclose(
                    &fileActions,
                    workingDirectory.fileDescriptor
                  ) == 0 else {
                                let errorCode = inheritResult != 0 ? inheritResult : result
                                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
        }

        do {
            let termination: TerminationStatus
            if let supervisorExecutableURL {
                let result = try await Subprocess.run(
                    .path(.init(supervisorExecutableURL.path)),
                    arguments: Arguments(["--supervise-command", request.command]),
                    environment: environment(for: request, profileOutputPath: "/dev/null"),
                    workingDirectory: nil,
                    platformOptions: platformOptions,
                    input: .inputWriter,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    _ = execution.standardInputWriter
                    let identity = try await state.recordProcessGroup(
                        execution.processIdentifier.value
                    )
                    try await drainSupervisedOutput(
                        execution,
                        into: state,
                        supervisorIdentity: identity
                    )
                }
                termination = result.terminationStatus
            } else {
                let result = try await Subprocess.run(
                    .path("/bin/zsh"),
                    arguments: Arguments(["-dfc", request.command]),
                    environment: environment(for: request),
                    workingDirectory: nil,
                    platformOptions: platformOptions,
                    input: .none,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    _ = try await state.recordProcessGroup(
                        execution.processIdentifier.value
                    )
                    try await drainOutput(execution, into: state)
                }
                termination = result.terminationStatus
            }
            try await cleanRecordedSession(state)
            return termination
        } catch {
            do {
                try await cleanRecordedSession(state)
            } catch let cleanupError {
                throw cleanupError
            }
            throw error
        }
    }

    private nonisolated static func cleanRecordedSession(
        _ state: ExecutionJobState
    ) async throws {
        guard let identity = await state.recordedProcessIdentity else {
            if let processGroupID = await state.recordedProcessGroupID,
               processGroupID > 1,
               processGroupID != getpgrp() {
                kill(-processGroupID, SIGKILL)
            }
            throw ExecutionServiceError.processGroupCleanupFailed(
                await state.recordedProcessGroupID ?? 0
            )
        }
        do {
            try ExecutionProcessGroupController.terminate(recordedLeader: identity)
        } catch {
            throw ExecutionServiceError.processGroupCleanupFailed(
                identity.processGroupID
            )
        }
    }

    private nonisolated static func drainOutput<Input: InputProtocol>(
        _ execution: Execution<Input, SequenceOutput, SequenceOutput>,
        into state: ExecutionJobState
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await buffer in execution.standardOutput {
                    let data = buffer.withUnsafeBytes { Data($0) }
                    try await state.append(data, stream: .stdout)
                }
            }
            group.addTask {
                for try await buffer in execution.standardError {
                    let data = buffer.withUnsafeBytes { Data($0) }
                    try await state.append(data, stream: .stderr)
                }
            }
            try await group.waitForAll()
        }
    }

    private nonisolated static func drainSupervisedOutput<Input: InputProtocol>(
        _ execution: Execution<Input, SequenceOutput, SequenceOutput>,
        into state: ExecutionJobState,
        supervisorIdentity: ExecutionProcessIdentity
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await drainOutput(execution, into: state)
            }
            group.addTask {
                try await monitorSupervisor(supervisorIdentity)
            }
            try await group.waitForAll()
        }
    }

    private nonisolated static func monitorSupervisor(
        _ recordedIdentity: ExecutionProcessIdentity
    ) async throws {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            if let currentIdentity = ExecutionProcessIdentity(
                processID: recordedIdentity.processID
            ) {
                guard currentIdentity == recordedIdentity else {
                    throw ExecutionServiceError.processGroupCleanupFailed(
                        recordedIdentity.processGroupID
                    )
                }
            } else {
                do {
                    try ExecutionProcessGroupController.terminate(
                        recordedLeader: recordedIdentity
                    )
                } catch {
                    throw ExecutionServiceError.processGroupCleanupFailed(
                        recordedIdentity.processGroupID
                    )
                }
                return
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }

    private nonisolated static func prepareRequest(
        _ request: ExecutionRequest
    ) throws -> (
        request: ExecutionRequest,
        workingDirectory: ExecutionPreparedWorkingDirectory
    ) {
        let root = request.workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let workingDirectory = request.workingDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        let workingComponents = workingDirectory.pathComponents
        let rootComponents = root.pathComponents
        guard workingComponents.count >= rootComponents.count,
              Array(workingComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ExecutionServiceError.workingDirectoryOutsideWorkspace(
                workingDirectory.path
            )
        }
        let preparedDirectory = try ExecutionPreparedWorkingDirectory(
            workspaceRoot: root,
            workspaceIdentity: try request.workspaceIdentity
                ?? ExecutionDirectoryIdentity(directoryURL: root),
            relativeComponents: Array(workingComponents.dropFirst(rootComponents.count))
        )
        let validatedRequest = try ExecutionRequest(
            jobID: request.jobID,
            command: request.command,
            workspaceRoot: root,
            workspaceIdentity: request.workspaceIdentity,
            workingDirectory: workingDirectory,
            checkpointSeconds: request.checkpointSeconds,
            timeoutSeconds: request.timeoutSeconds,
            interaction: request.interaction,
            environment: request.environment
        )
        return (validatedRequest, preparedDirectory)
    }

    private nonisolated static func environment(
        for request: ExecutionRequest,
        profileOutputPath: String? = nil
    ) -> Environment {
        let inherited = ProcessInfo.processInfo.environment
        let allowedKeys = [
            "HOME", "LANG", "LC_ALL", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER"
        ]
        var values: [Environment.Key: String] = [:]
        for key in allowedKeys {
            if let value = inherited[key], let environmentKey = Environment.Key(rawValue: key) {
                values[environmentKey] = value
            }
        }
        for (key, value) in request.environment {
            if let environmentKey = Environment.Key(rawValue: key) {
                values[environmentKey] = value
            }
        }
        if let profileOutputPath,
           let profileKey = Environment.Key(rawValue: "LLVM_PROFILE_FILE") {
            values[profileKey] = profileOutputPath
        }
        return .custom(values)
    }
}

private final class ExecutionPreparedWorkingDirectory: @unchecked Sendable {
    let fileDescriptor: Int32

    init(
        workspaceRoot: URL,
        workspaceIdentity: ExecutionDirectoryIdentity,
        relativeComponents: [String]
    ) throws {
        let rootDescriptor = open(
            workspaceRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try ExecutionDirectoryIdentity(fileDescriptor: rootDescriptor)
            == workspaceIdentity else {
            close(rootDescriptor)
            throw ExecutionServiceError.workingDirectoryOutsideWorkspace(
                workspaceRoot.path
            )
        }

        var currentDescriptor = rootDescriptor
        do {
            for component in relativeComponents {
                let nextDescriptor = component.withCString {
                    openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            fileDescriptor = currentDescriptor
        } catch {
            close(currentDescriptor)
            throw error
        }
    }

    deinit {
        close(fileDescriptor)
    }
}

private typealias AddFchdirFunction = @convention(c) (
    UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    Int32
) -> Int32

private func addWorkingDirectoryAction(
    to fileActions: inout posix_spawn_file_actions_t?,
    fileDescriptor: Int32
) throws -> Int32 {
    if #available(macOS 26.0, *) {
        return posix_spawn_file_actions_addfchdir(&fileActions, fileDescriptor)
    }
    guard let processHandle = dlopen(nil, RTLD_LAZY),
          let symbol = dlsym(
            processHandle,
            "posix_spawn_file_actions_addfchdir_np"
          ) else {
        throw POSIXError(.ENOSYS)
    }
    let function = unsafeBitCast(symbol, to: AddFchdirFunction.self)
    return withUnsafeMutablePointer(to: &fileActions) {
        function($0, fileDescriptor)
    }
}

private enum ExecutionOutputStream {
    case stdout
    case stderr
}

private actor ExecutionJobState {
    private let request: ExecutionRequest
    private let startedAt = ContinuousClock().now
    private let logURL: URL
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let maximumLogBytesPerStream: Int
    private var stdoutSinceCheckpoint: BoundedByteBuffer
    private var stderrSinceCheckpoint: BoundedByteBuffer
    private var stdoutTail: BoundedByteBuffer
    private var stderrTail: BoundedByteBuffer
    private var stdoutBytesSinceCheckpoint = 0
    private var stderrBytesSinceCheckpoint = 0
    private var terminalStatus: ExecutionStatus?
    private var requestedCancellationStatus: ExecutionStatus?
    private var exitCode: Int32?
    private var failureMessage: String?
    private var logsClosed = false
    private var stdoutLogBytes = 0
    private var stderrLogBytes = 0
    private var logTruncated = false
    private var needsRecovery = false
    private var metadata: ExecutionJobMetadata
    private var terminalWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        request: ExecutionRequest,
        logsDirectory: URL,
        observationLimitBytes: Int,
        maximumLogBytesPerStream: Int
    ) throws {
        self.request = request
        let directory = logsDirectory.appending(
            path: request.jobID.rawValue.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let stdoutURL = directory.appending(path: "stdout.log")
        let stderrURL = directory.appending(path: "stderr.log")
        FileManager.default.createFile(
            atPath: stdoutURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        FileManager.default.createFile(
            atPath: stderrURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        logURL = directory
        stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        stderrHandle = try FileHandle(forWritingTo: stderrURL)
        self.maximumLogBytesPerStream = maximumLogBytesPerStream
        stdoutSinceCheckpoint = BoundedByteBuffer(limit: observationLimitBytes)
        stderrSinceCheckpoint = BoundedByteBuffer(limit: observationLimitBytes)
        stdoutTail = BoundedByteBuffer(limit: observationLimitBytes)
        stderrTail = BoundedByteBuffer(limit: observationLimitBytes)
        metadata = ExecutionJobMetadata(
            version: ExecutionJobMetadata.currentVersion,
            jobID: request.jobID,
            status: .running,
            processGroupID: nil,
            processIdentity: nil,
            startedAt: .now,
            finishedAt: nil,
            stdoutLogBytes: 0,
            stderrLogBytes: 0,
            logTruncated: false
        )
        try ExecutionJobMetadataStore.write(metadata, to: directory)
    }

    var isTerminal: Bool { terminalStatus != nil }
    var recoveryPending: Bool { needsRecovery }
    var recordedProcessIdentity: ExecutionProcessIdentity? {
        metadata.processIdentity
    }
    var recordedProcessGroupID: Int32? { metadata.processGroupID }

    func recordProcessGroup(_ processGroupID: Int32) throws -> ExecutionProcessIdentity {
        metadata.processGroupID = processGroupID
        try ExecutionJobMetadataStore.write(metadata, to: logURL)
        guard let identity = ExecutionProcessIdentity(processID: processGroupID),
              identity.processGroupID == processGroupID,
              identity.sessionID == processGroupID else {
            throw ExecutionServiceError.processIdentityUnavailable(processGroupID)
        }
        metadata.processIdentity = identity
        try ExecutionJobMetadataStore.write(metadata, to: logURL)
        return identity
    }

    func append(_ data: Data, stream: ExecutionOutputStream) throws {
        guard terminalStatus == nil else { return }
        switch stream {
        case .stdout:
            let written = try writeBounded(
                data,
                to: stdoutHandle,
                bytesWritten: stdoutLogBytes
            )
            stdoutLogBytes += written
            stdoutSinceCheckpoint.append(data)
            stdoutTail.append(data)
            stdoutBytesSinceCheckpoint += data.count
        case .stderr:
            let written = try writeBounded(
                data,
                to: stderrHandle,
                bytesWritten: stderrLogBytes
            )
            stderrLogBytes += written
            stderrSinceCheckpoint.append(data)
            stderrTail.append(data)
            stderrBytesSinceCheckpoint += data.count
        }
    }

    func requestCancellation(_ status: ExecutionStatus) -> Bool {
        guard terminalStatus == nil, requestedCancellationStatus == nil else {
            return false
        }
        requestedCancellationStatus = status
        return true
    }

    func waitUntilTerminal() async {
        guard terminalStatus == nil, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if terminalStatus != nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    terminalWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func complete(_ termination: TerminationStatus) {
        guard terminalStatus == nil else { return }
        if let requestedCancellationStatus {
            terminalStatus = requestedCancellationStatus
        } else {
            switch termination {
            case .exited(let code):
                exitCode = code
                terminalStatus = code == 0 ? .succeeded : .failed
            case .signaled(let signal):
                terminalStatus = .failed
                failureMessage = "The command terminated from signal \(signal)."
            }
        }
        closeLogs()
        if !finishMetadata() {
            recordMetadataPersistenceFailure()
        }
        resumeTerminalWaiters()
    }

    func completeCancellation() {
        guard terminalStatus == nil else { return }
        terminalStatus = requestedCancellationStatus ?? .cancelled
        closeLogs()
        if !finishMetadata() {
            recordMetadataPersistenceFailure()
        }
        resumeTerminalWaiters()
    }

    func completeFailure(_ error: any Error) {
        guard terminalStatus == nil else { return }
        let cleanupFailed: Bool
        if case ExecutionServiceError.processGroupCleanupFailed = error {
            cleanupFailed = true
        } else {
            cleanupFailed = false
        }
        if cleanupFailed {
            terminalStatus = .unknownOutcome
            failureMessage = error.localizedDescription
            needsRecovery = true
        } else if let requestedCancellationStatus {
            terminalStatus = requestedCancellationStatus
        } else {
            terminalStatus = .failed
            failureMessage = error is SubprocessError
                ? String(describing: error)
                : error.localizedDescription
        }
        closeLogs()
        if !finishMetadata(preserveForRecovery: cleanupFailed) {
            recordMetadataPersistenceFailure()
        }
        resumeTerminalWaiters()
    }

    func acknowledgePersistedRecovery() {
        guard needsRecovery else { return }
        needsRecovery = false
        metadata.status = .unknownOutcome
        metadata.finishedAt = .now
    }

    func consumeObservation() -> ExecutionObservation {
        let stdoutSince = stdoutSinceCheckpoint
        let stderrSince = stderrSinceCheckpoint
        let stdoutByteCount = stdoutBytesSinceCheckpoint
        let stderrByteCount = stderrBytesSinceCheckpoint
        stdoutSinceCheckpoint.removeAll()
        stderrSinceCheckpoint.removeAll()
        stdoutBytesSinceCheckpoint = 0
        stderrBytesSinceCheckpoint = 0

        return ExecutionObservation(
            jobID: request.jobID,
            status: terminalStatus ?? .running,
            command: request.command,
            workingDirectory: request.workingDirectory,
            elapsedSeconds: elapsedSeconds,
            exitCode: exitCode,
            stdoutSinceCheckpoint: stdoutSince.string,
            stderrSinceCheckpoint: stderrSince.string,
            stdoutTail: stdoutTail.string,
            stderrTail: stderrTail.string,
            stdoutBytesSinceCheckpoint: stdoutByteCount,
            stderrBytesSinceCheckpoint: stderrByteCount,
            outputTruncated: stdoutSince.wasTruncated
                || stderrSince.wasTruncated
                || stdoutTail.wasTruncated
                || stderrTail.wasTruncated
                || logTruncated,
            logTruncated: logTruncated,
            logURL: logURL,
            failureMessage: failureMessage
        )
    }

    private var elapsedSeconds: Double {
        let components = startedAt.duration(to: ContinuousClock().now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func closeLogs() {
        guard !logsClosed else { return }
        logsClosed = true
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    private func writeBounded(
        _ data: Data,
        to handle: FileHandle,
        bytesWritten: Int
    ) throws -> Int {
        let remaining = max(0, maximumLogBytesPerStream - bytesWritten)
        let writeCount = min(remaining, data.count)
        if writeCount > 0 {
            try handle.write(contentsOf: Data(data.prefix(writeCount)))
        }
        if writeCount < data.count { logTruncated = true }
        return writeCount
    }

    @discardableResult
    private func finishMetadata(preserveForRecovery: Bool = false) -> Bool {
        metadata.status = preserveForRecovery ? .running : terminalStatus ?? .unknownOutcome
        metadata.finishedAt = preserveForRecovery ? nil : .now
        metadata.stdoutLogBytes = stdoutLogBytes
        metadata.stderrLogBytes = stderrLogBytes
        metadata.logTruncated = logTruncated
        do {
            try ExecutionJobMetadataStore.write(metadata, to: logURL)
            return true
        } catch {
            return false
        }
    }

    private func recordMetadataPersistenceFailure() {
        terminalStatus = .unknownOutcome
        failureMessage = "The command ended, but its terminal state could not be persisted."
        needsRecovery = true
        _ = finishMetadata(preserveForRecovery: true)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        terminalWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeTerminalWaiters() {
        let waiters = terminalWaiters.values
        terminalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct BoundedByteBuffer {
    let limit: Int
    private(set) var data = Data()
    private(set) var wasTruncated = false

    mutating func append(_ value: Data) {
        guard limit > 0 else {
            wasTruncated = wasTruncated || !value.isEmpty
            return
        }
        if value.count >= limit {
            let discardedExistingData = !data.isEmpty
            data = Data(value.suffix(limit))
            wasTruncated = wasTruncated || discardedExistingData || value.count > limit
            return
        }
        data.append(value)
        if data.count > limit {
            data.removeFirst(data.count - limit)
            wasTruncated = true
        }
    }

    mutating func removeAll() {
        data.removeAll(keepingCapacity: true)
        wasTruncated = false
    }

    var string: String {
        String(decoding: data, as: UTF8.self)
    }
}