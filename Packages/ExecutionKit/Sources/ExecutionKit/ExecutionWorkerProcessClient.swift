import Foundation

public actor ExecutionWorkerProcessClient: ExecutionWorkerServing {
    private struct PendingResponse {
        let generationID: UUID
        let request: ExecutionWorkerRequest
        let continuation: CheckedContinuation<ExecutionWorkerResponse, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let logsDirectory: URL
    private let responseGraceMilliseconds: Int
    private let shutdownGraceMilliseconds: Int
    private var generationID: UUID?
    private var isShuttingDown = false
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardError: FileHandle?
    private var responseTask: Task<Void, Never>?
    private var pendingResponses: [UUID: PendingResponse] = [:]
    private var activeJobs: [ExecutionJobID: UUID] = [:]
    private var hasUnidentifiedRecovery = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        executableURL: URL,
        logsDirectory: URL,
        responseGraceMilliseconds: Int = 15_000,
        shutdownGraceMilliseconds: Int = 5_000
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.logsDirectory = logsDirectory.standardizedFileURL
        self.responseGraceMilliseconds = responseGraceMilliseconds
        self.shutdownGraceMilliseconds = shutdownGraceMilliseconds
    }

    public func handle(
        _ request: ExecutionWorkerRequest
    ) async -> ExecutionWorkerResponse {
        guard !Task.isCancelled else {
            return .failure(
                requestID: request.requestID,
                code: "request_cancelled",
                message: "The execution request was cancelled."
            )
        }
        guard !isShuttingDown else {
            return .failure(
                requestID: request.requestID,
                code: "worker_stopping",
                message: "The execution worker is stopping."
            )
        }
        if request.action == .run,
           !activeJobs.isEmpty || hasUnidentifiedRecovery {
            return .failure(
                requestID: request.requestID,
                code: "worker_recovery_pending",
                message: "A previous execution still requires verified cleanup."
            )
        }
        do {
            try startIfNeeded()
        } catch {
            return .failure(
                requestID: request.requestID,
                code: "worker_unavailable",
                message: error.localizedDescription
            )
        }
        guard let generationID else {
            return .failure(
                requestID: request.requestID,
                code: "worker_unavailable",
                message: "The execution worker did not start."
            )
        }
        guard pendingResponses[request.requestID] == nil else {
            return .failure(
                requestID: request.requestID,
                code: "duplicate_request_id",
                message: "A worker request with this identifier is already pending."
            )
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(
                            for: .milliseconds(self?.responseTimeoutMilliseconds(
                                for: request
                            ) ?? 1)
                        )
                    } catch {
                        return
                    }
                    await self?.requestTimedOut(
                        requestID: request.requestID,
                        generationID: generationID
                    )
                }
                pendingResponses[request.requestID] = PendingResponse(
                    generationID: generationID,
                    request: request,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                if let jobID = request.executionRequest?.jobID {
                    activeJobs[jobID] = generationID
                }
                do {
                    try write(request, generationID: generationID)
                } catch {
                    Task {
                        await self.shutdown(
                            generationID: generationID,
                            code: "worker_transport_failed",
                            message: error.localizedDescription
                        )
                    }
                }
                if Task.isCancelled {
                    cancelRequest(request, generationID: generationID)
                }
            }
        } onCancel: {
            Task {
                await self.cancelRequest(request, generationID: generationID)
            }
        }
    }

    @discardableResult
    public func shutdown() async -> Bool {
        guard let generationID else {
            return recoverTrackedJobs()
        }
        await shutdown(
            generationID: generationID,
            code: "worker_stopped",
            message: "The execution worker stopped before returning a response."
        )
        return activeJobs.isEmpty && !hasUnidentifiedRecovery
    }

    var runningWorkerProcessIdentifier: Int32? {
        process?.isRunning == true ? process?.processIdentifier : nil
    }

    private func shutdown(
        generationID: UUID,
        code: String,
        message: String
    ) async {
        guard self.generationID == generationID else { return }
        if isShuttingDown {
            await withCheckedContinuation { shutdownWaiters.append($0) }
            return
        }
        isShuttingDown = true
        try? standardInput?.close()
        standardInput = nil
        let closingProcess = process
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .milliseconds(shutdownGraceMilliseconds)
        )
        while closingProcess?.isRunning == true, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        if closingProcess?.isRunning == true {
            closingProcess?.terminate()
            try? await clock.sleep(for: .milliseconds(250))
        }
        if closingProcess?.isRunning == true {
            kill(closingProcess?.processIdentifier ?? 0, SIGKILL)
            try? await clock.sleep(for: .milliseconds(50))
        }
        recoverActiveJobs(generationID: generationID)
        guard self.generationID == generationID else { return }
        failPendingResponses(
            generationID: generationID,
            code: code,
            message: message
        )
        responseTask?.cancel()
        responseTask = nil
        process = nil
        try? standardError?.close()
        standardError = nil
        self.generationID = nil
        isShuttingDown = false
        resumeShutdownWaiters()
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        guard generationID == nil else {
            throw ExecutionWorkerClientError.workerStopping
        }
        guard !isShuttingDown else {
            throw ExecutionWorkerClientError.workerStopping
        }

        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stderrURL = logsDirectory.appending(path: "worker.stderr.log")
        if !FileManager.default.fileExists(atPath: stderrURL.path) {
            FileManager.default.createFile(
                atPath: stderrURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        try stderrHandle.truncate(atOffset: 0)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let generationID = UUID()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--logs-directory", logsDirectory.path]
        process.currentDirectoryURL = logsDirectory
        process.environment = workerEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = stderrHandle
        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.workerTerminated(
                    generationID: generationID,
                    exitCode: terminatedProcess.terminationStatus
                )
            }
        }
        try process.run()

        self.process = process
        self.generationID = generationID
        standardInput = inputPipe.fileHandleForWriting
        standardError = stderrHandle
        responseTask = Task { [weak self] in
            do {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let response = try? JSONDecoder().decode(
                            ExecutionWorkerResponse.self,
                            from: data
                          ) else {
                                                await self?.shutdown(
                                                        generationID: generationID,
                                                        code: "invalid_worker_response",
                                                        message: "The execution worker returned malformed protocol data."
                                                )
                                                return
                    }
                    await self?.receive(response, generationID: generationID)
                }
            } catch {
                await self?.responseStreamFailed(error, generationID: generationID)
            }
        }
    }

    private func workerEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowedKeys = [
            "HOME", "LANG", "LC_ALL", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER"
        ]
        var environment = Dictionary(
            uniqueKeysWithValues: allowedKeys.compactMap { key in
                inherited[key].map { (key, $0) }
            }
        )
        environment["LLVM_PROFILE_FILE"] = "/dev/null"
        return environment
    }

    private func write(
        _ request: ExecutionWorkerRequest,
        generationID: UUID
    ) throws {
        guard self.generationID == generationID, let standardInput else {
            throw ExecutionWorkerClientError.workerNotRunning
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(request)
        data.append(0x0A)
        try standardInput.write(contentsOf: data)
    }

    private func cancelRequest(
        _ request: ExecutionWorkerRequest,
        generationID: UUID
    ) {
        finishPending(
            requestID: request.requestID,
            response: .failure(
                requestID: request.requestID,
                code: "request_cancelled",
                message: "The execution request was cancelled."
            )
        )
        guard let jobID = request.executionRequest?.jobID
                ?? request.checkpointRequest?.jobID
                ?? request.jobID,
              self.generationID == generationID,
              process?.isRunning == true else {
            return
        }
        try? write(.stop(jobID), generationID: generationID)
    }

    private func receive(_ response: ExecutionWorkerResponse, generationID: UUID) {
        guard let pending = pendingResponses[response.requestID],
                            pending.generationID == generationID,
                            !isShuttingDown else {
            return
        }
          if let observation = response.observation,
              observation.status != .running,
              observation.status != .unknownOutcome {
            activeJobs[observation.jobID] = nil
        } else if response.error != nil,
                  let jobID = pending.request.executionRequest?.jobID {
            activeJobs[jobID] = nil
        }
        finishPending(requestID: response.requestID, response: response)
    }

    private func responseStreamFailed(_ error: any Error, generationID: UUID) {
        Task {
            await shutdown(
                generationID: generationID,
                code: "worker_transport_failed",
                message: error.localizedDescription
            )
        }
    }

    private func workerTerminated(generationID: UUID, exitCode: Int32) {
        guard self.generationID == generationID else { return }
        if isShuttingDown { return }
        recoverActiveJobs(generationID: generationID)
        responseTask?.cancel()
        responseTask = nil
        process = nil
        standardInput = nil
        try? standardError?.close()
        standardError = nil
        failPendingResponses(
            generationID: generationID,
            code: "worker_terminated",
            message: "The execution worker exited with status \(exitCode)."
        )
        self.generationID = nil
        isShuttingDown = false
        resumeShutdownWaiters()
    }

    private func requestTimedOut(requestID: UUID, generationID: UUID) async {
        guard let pending = pendingResponses[requestID],
              pending.generationID == generationID else {
            return
        }
        await shutdown(
            generationID: generationID,
            code: "worker_response_timeout",
            message: "The execution worker did not respond before the transport deadline."
        )
    }

    private func finishPending(
        requestID: UUID,
        response: ExecutionWorkerResponse
    ) {
        guard let pending = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: response)
    }

    private func failPendingResponses(
        generationID: UUID,
        code: String,
        message: String
    ) {
        let requestIDs = pendingResponses.compactMap {
            $0.value.generationID == generationID ? $0.key : nil
        }
        for requestID in requestIDs {
            finishPending(
                requestID: requestID,
                response: .failure(
                    requestID: requestID,
                    code: code,
                    message: message
                )
            )
        }
    }

    private func recoverActiveJobs(generationID: UUID) {
        let jobIDs = Set(activeJobs.keys)
        let recovery = PipeExecutionService.recoverJobsAfterWorkerTermination(
            logsDirectory: logsDirectory,
            jobIDs: jobIDs
        )
        activeJobs = Dictionary(
            uniqueKeysWithValues: recovery.unresolvedJobIDs.map {
                ($0, generationID)
            }
        )
        hasUnidentifiedRecovery = recovery.hasUnidentifiedJobs
    }

    private func recoverTrackedJobs() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logsDirectory.path
            )
        } catch {
            hasUnidentifiedRecovery = true
            return false
        }
        let jobIDs = Set(activeJobs.keys)
        let recovery = PipeExecutionService.recoverJobsAfterWorkerTermination(
            logsDirectory: logsDirectory,
            jobIDs: jobIDs
        )
        let recoveryGenerationID = generationID ?? UUID()
        activeJobs = Dictionary(
            uniqueKeysWithValues: recovery.unresolvedJobIDs.map {
                ($0, recoveryGenerationID)
            }
        )
        hasUnidentifiedRecovery = recovery.hasUnidentifiedJobs
        return recovery.isResolved
    }

    private func resumeShutdownWaiters() {
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func responseTimeoutMilliseconds(
        for request: ExecutionWorkerRequest
    ) -> Int {
        switch request.action {
        case .run:
            (request.executionRequest?.checkpointSeconds ?? 0) * 1_000
                + responseGraceMilliseconds
        case .wait:
            (request.checkpointRequest?.checkpointSeconds ?? 0) * 1_000
                + responseGraceMilliseconds
        case .stop:
            responseGraceMilliseconds
        }
    }
}

private enum ExecutionWorkerClientError: Error, LocalizedError {
    case workerNotRunning
    case workerStopping

    var errorDescription: String? {
        switch self {
        case .workerNotRunning:
            "The execution worker is not running."
        case .workerStopping:
            "The execution worker is stopping."
        }
    }
}