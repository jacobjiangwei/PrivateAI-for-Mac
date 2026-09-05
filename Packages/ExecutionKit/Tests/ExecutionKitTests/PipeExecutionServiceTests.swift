import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import ExecutionKit

@Suite(
    "Pipe Execution Service",
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_EXECUTOR_DIAGNOSTICS"] == "1")
)
struct PipeExecutionServiceTests {
    @Test("runs a real zsh command and captures both output streams")
    func realShellCommand() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "printf 'hello'; printf 'problem' >&2",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let observation = try await service.run(request)

        #expect(observation.status == .succeeded)
        #expect(observation.exitCode == 0)
        #expect(observation.stdoutSinceCheckpoint == "hello")
        #expect(observation.stderrSinceCheckpoint == "problem")
        #expect(observation.failureMessage == nil)
        #expect(try String(contentsOf: observation.logURL.appending(path: "stdout.log"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: observation.logURL.appending(path: "stderr.log"), encoding: .utf8) == "problem")
    }

    @Test("returns a running checkpoint without stopping the command")
    func runningCheckpoint() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "printf 'begin'; /bin/sleep 2; printf 'end'",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let first = try await service.run(request)
        let second = try await service.wait(ExecutionCheckpointRequest(
            jobID: request.jobID,
            checkpointSeconds: 3
        ))

        #expect(first.status == .running)
        #expect(first.stdoutSinceCheckpoint == "begin")
        #expect(second.status == .succeeded)
        #expect(second.stdoutSinceCheckpoint == "end")
        #expect(second.stdoutTail == "beginend")
    }

    @Test("reports a nonzero shell exit as a structured failure")
    func nonzeroExit() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "printf 'nope' >&2; exit 7",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let observation = try await service.run(request)

        #expect(observation.status == .failed)
        #expect(observation.exitCode == 7)
        #expect(observation.stderrTail == "nope")
    }

    @Test("drains large output while bounding model observations")
    func boundedObservationWithCompleteLog() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            observationLimitBytes: 1_024
        )
        let request = try ExecutionRequest(
            command: "/usr/bin/head -c 200000 /dev/zero; /bin/sleep 30",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let checkpoint = try await service.run(request)
        let stopped = try await service.stop(request.jobID)
        let stdoutLog = stopped.logURL.appending(path: "stdout.log")
        let attributes = try FileManager.default.attributesOfItem(atPath: stdoutLog.path)

        #expect(checkpoint.status == .running)
        #expect(checkpoint.stdoutBytesSinceCheckpoint == 200_000)
        #expect(checkpoint.stdoutSinceCheckpoint.utf8.count <= 1_024)
        #expect(checkpoint.outputTruncated)
        #expect(try Data(contentsOf: stdoutLog).count == 200_000)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(stopped.status == .cancelled)
    }

    @Test("timeout terminates a background descendant")
    func timeoutKillsDescendant() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 1,
            interaction: .pipe
        )

        let observation = try await service.run(request)
        let childPID = try #require(Int32(
            observation.stdoutTail.trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        #expect(observation.status == .timedOut)
        #expect(await processDisappeared(childPID))
    }

    @Test("stop terminates a background descendant immediately")
    func stopKillsDescendant() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let checkpoint = try await service.run(request)
        let childPID = try #require(Int32(
            checkpoint.stdoutTail.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let stopped = try await service.stop(request.jobID)

        #expect(checkpoint.status == .running)
        #expect(stopped.status == .cancelled)
        #expect(await processDisappeared(childPID))
    }

    @Test("stop preserves a result that already completed")
    func stopAfterCompletion() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "exit 0",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let completed = try await service.run(request)
        let stopped = try await service.stop(request.jobID)

        #expect(completed.status == .succeeded)
        #expect(stopped.status == .succeeded)
        #expect(stopped.exitCode == 0)
    }

    @Test("caps each persisted stream while continuing to drain output")
    func logStorageLimit() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumLogBytesPerStream: 4_096
        )
        let request = try ExecutionRequest(
            command: "/usr/bin/head -c 100000 /dev/zero",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let observation = try await service.run(request)
        let stdoutLog = observation.logURL.appending(path: "stdout.log")

        #expect(observation.status == .succeeded)
        #expect(observation.stdoutBytesSinceCheckpoint == 100_000)
        #expect(observation.logTruncated)
        #expect(try Data(contentsOf: stdoutLog).count == 4_096)
    }

    @Test("revalidates the initial working directory inside the worker")
    func workerWorkspaceBoundary() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "pwd",
            workspaceRoot: fixture.workspace,
            workingDirectory: outside,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        await #expect(throws: ExecutionServiceError.workingDirectoryOutsideWorkspace(
            outside.path
        )) {
            try await service.run(request)
        }
    }

    @Test("binds workspace authorization to its directory identity")
    func workspaceIdentityBoundary() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "pwd",
            workspaceRoot: fixture.workspace,
            workspaceIdentity: ExecutionDirectoryIdentity(directoryURL: outside),
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        await #expect(throws: ExecutionServiceError.workingDirectoryOutsideWorkspace(
            fixture.workspace.path
        )) {
            try await service.run(request)
        }
    }

    @Test("enforces the active job limit")
    func activeJobLimit() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumActiveJobs: 1
        )
        let first = try ExecutionRequest(
            command: "/bin/sleep 30",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let second = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )

        let running = try await service.run(first)
        await #expect(throws: ExecutionServiceError.tooManyActiveJobs(1)) {
            try await service.run(second)
        }
        _ = try await service.stop(first.jobID)

        #expect(running.status == .running)
    }

    @Test("bounds retained in-memory job handles")
    func retainedJobLimit() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumRetainedJobs: 1
        )

        for index in 0..<3 {
            let request = try ExecutionRequest(
                command: "printf \(index)",
                workingDirectory: fixture.workspace,
                checkpointSeconds: 5,
                timeoutSeconds: 30,
                interaction: .pipe
            )
            let observation = try await service.run(request)
            #expect(observation.status == .succeeded)
        }

        #expect(await service.retainedJobCount == 1)
    }

    @Test("bounds aggregate stored log bytes across completed jobs")
    func aggregateLogLimit() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumLogBytesPerStream: 4_096,
            maximumTotalLogBytes: 5_000,
            maximumJobDirectories: 10
        )

        for _ in 0..<3 {
            let request = try ExecutionRequest(
                command: "/usr/bin/head -c 4096 /dev/zero",
                workingDirectory: fixture.workspace,
                checkpointSeconds: 5,
                timeoutSeconds: 30,
                interaction: .pipe
            )
            #expect(try await service.run(request).status == .succeeded)
        }
        let jobDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.logs,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let totalLogBytes = try jobDirectories.reduce(0) { total, directory in
            let stdout = directory.appending(path: "stdout.log")
            let size = try stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return total + size
        }

        #expect(totalLogBytes <= 5_000)
        #expect(jobDirectories.count == 1)
    }

    @Test("failed recovery remains retryable")
    func failedRecoveryRemainsRunning() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let jobID = ExecutionJobID()
        let directory = fixture.logs.appending(
            path: jobID.rawValue.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try ExecutionJobMetadataStore.write(
            ExecutionJobMetadata(
                version: ExecutionJobMetadata.currentVersion,
                jobID: jobID,
                status: .running,
                processGroupID: nil,
                processIdentity: nil,
                startedAt: .now,
                finishedAt: nil,
                stdoutLogBytes: 0,
                stderrLogBytes: 0,
                logTruncated: false
            ),
            to: directory
        )

        ExecutionJobMetadataStore.recoverUnfinishedJobs(in: fixture.logs)
        let recovered = try #require(ExecutionJobMetadataStore.load(from: directory))

        #expect(recovered.status == .running)
        #expect(recovered.finishedAt == nil)

        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumActiveJobs: 1
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )
        await #expect(throws: ExecutionServiceError.tooManyActiveJobs(1)) {
            try await service.run(request)
        }
    }

    @Test("corrupt job metadata blocks new execution and is not pruned")
    func corruptMetadataFailsClosed() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let jobID = ExecutionJobID()
        let directory = fixture.logs.appending(
            path: jobID.rawValue.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: directory.appending(path: ExecutionJobMetadataStore.filename)
        )

        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumActiveJobs: 1,
            maximumJobDirectories: 0,
            logRetentionInterval: 0
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        await #expect(throws: ExecutionServiceError.tooManyActiveJobs(1)) {
            try await service.run(request)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(!(await service.cancelAll()))
    }

    @Test("migrates pre-metadata logs without weakening current corruption checks")
    func migratesLegacyUntrackedLogs() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let legacyJobID = UUID().uuidString.lowercased()
        let legacyJob = fixture.logs.appending(
            path: legacyJobID,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: legacyJob,
            withIntermediateDirectories: true
        )
        try Data("legacy output".utf8).write(
            to: legacyJob.appending(path: "stdout.log")
        )

        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let request = try ExecutionRequest(
            command: "printf current",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )
        let observation = try await service.run(request)
        let archived = fixture.logs
            .appending(path: ".legacy-untracked", directoryHint: .isDirectory)
            .appending(path: legacyJobID, directoryHint: .isDirectory)

        #expect(observation.status == .succeeded)
        #expect(try String(
            contentsOf: archived.appending(path: "stdout.log"),
            encoding: .utf8
        ) == "legacy output")
        #expect(FileManager.default.fileExists(
            atPath: fixture.logs.appending(path: ".execution-metadata-v1").path
        ))
    }

    @Test("terminal metadata write failure retains ownership until recovery")
    func terminalMetadataWriteFailure() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumActiveJobs: 1
        )
        let request = try ExecutionRequest(
            command: "printf done; /bin/sleep 2",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )
        let running = try await service.run(request)
        let jobDirectory = fixture.logs.appending(
            path: request.jobID.rawValue.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: jobDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: jobDirectory.path
            )
        }

        let completed = try await service.wait(ExecutionCheckpointRequest(
            jobID: request.jobID,
            checkpointSeconds: 3
        ))
        let second = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        #expect(running.status == .running)
        #expect(completed.status == .unknownOutcome)
        await #expect(throws: ExecutionServiceError.tooManyActiveJobs(1)) {
            try await service.run(second)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: jobDirectory.path
        )
        #expect(await service.cancelAll())
    }

    @Test("missing active job directory cannot produce cleanup proof")
    func missingActiveJobDirectoryFailsClosed() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(
            logsDirectory: fixture.logs,
            maximumActiveJobs: 1
        )
        let request = try ExecutionRequest(
            command: "printf done; /bin/sleep 2",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )
        #expect(try await service.run(request).status == .running)
        let jobDirectory = fixture.logs.appending(
            path: request.jobID.rawValue.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.removeItem(at: jobDirectory)

        let completed = try await service.wait(ExecutionCheckpointRequest(
            jobID: request.jobID,
            checkpointSeconds: 3
        ))
        let second = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        #expect(completed.status == .unknownOutcome)
        #expect(!(await service.cancelAll()))
        await #expect(throws: ExecutionServiceError.tooManyActiveJobs(1)) {
            try await service.run(second)
        }
    }

    @Test("unavailable logs directory cannot produce cleanup proof")
    func unavailableLogsDirectoryFailsClosed() throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appending(
            path: "missing-logs",
            directoryHint: .isDirectory
        )

        let recovery = ExecutionJobMetadataStore.recoverUnfinishedJobs(in: missing)

        #expect(!recovery.isResolved)
        #expect(recovery.hasUnidentifiedJobs)
    }
}

private func processDisappeared(_ processID: Int32) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if kill(processID, 0) == -1, errno == ESRCH {
            return true
        }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return kill(processID, 0) == -1 && errno == ESRCH
}

private final class ExecutionFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let logs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "privateai-execution-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}