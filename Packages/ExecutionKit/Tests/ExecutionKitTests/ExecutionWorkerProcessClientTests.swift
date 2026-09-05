import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import ExecutionKit

@Suite(
    "Execution Worker Process Client",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_EXECUTOR_DIAGNOSTICS"] == "1")
)
struct ExecutionWorkerProcessClientTests {
    @Test("fresh cleanup does not block the first command")
    func freshCleanupAllowsFirstRun() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )

        let initiallyClean = await client.shutdown()
        let request = try ExecutionRequest(
            command: "printf first",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )
        let response = await client.handle(.run(request))
        await client.shutdown()

        #expect(initiallyClean)
        #expect(response.observation?.status == .succeeded)
        #expect(response.observation?.stdoutTail == "first")
    }

    @Test("executes a real command across the worker process boundary")
    func realWorkerProcess() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let startupFile = fixture.workspace.appending(path: ".zshenv")
        try Data("export PRIVATEAI_STARTUP_SECRET=must-not-load\n".utf8)
            .write(to: startupFile, options: .atomic)
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "printf 'process-client:%s:%s' \"${LLVM_PROFILE_FILE-unset}\" \"${PRIVATEAI_STARTUP_SECRET-unset}\"",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe,
            environment: ["HOME": fixture.workspace.path]
        )

        let response = await client.handle(.run(request))
        await client.shutdown()

        #expect(response.error == nil)
        #expect(
            response.observation?.status == .succeeded,
            "Unexpected worker observation: \(String(describing: response.observation))"
        )
        #expect(response.observation?.stdoutTail == "process-client:unset:unset")
    }

    @Test("contains worker profile output outside the workspace")
    func workerProfileContainment() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        setenv("PRIVATEAI_TEST_SECRET", "must-not-leak", 1)
        defer { unsetenv("PRIVATEAI_TEST_SECRET") }
        let marker = fixture.root.appending(path: "worker-profile-path.txt")
        let fakeWorker = try fixture.makeEnvironmentRecordingWorker(marker: marker)
        let client = ExecutionWorkerProcessClient(
            executableURL: fakeWorker,
            logsDirectory: fixture.logs,
            responseGraceMilliseconds: 100,
            shutdownGraceMilliseconds: 100
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        _ = await client.handle(.run(request))
        await client.shutdown()

        let markerContents = try String(contentsOf: marker, encoding: .utf8)
        let markerLines = markerContents.split(separator: "\n").map(String.init)
        #expect(markerLines.count == 3)
        #expect(markerLines.first == "/dev/null")
        if markerLines.count == 3 {
            #expect(
                URL(fileURLWithPath: markerLines[1]).resolvingSymlinksInPath()
                    == fixture.logs.resolvingSymlinksInPath()
            )
            #expect(markerLines[2] == "unset")
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workspace.appending(path: "default.profraw").path
        ))
    }

    @Test("accepts stop while run is waiting for its checkpoint")
    func concurrentStop() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "printf started; /bin/sleep 30",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 30,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let run = Task {
            await client.handle(.run(request))
        }
        try await ContinuousClock().sleep(for: .milliseconds(300))

        let stopped = await client.handle(.stop(request.jobID))
        let runResponse = await run.value
        await client.shutdown()

        #expect(stopped.observation?.status == .cancelled)
        #expect(runResponse.observation?.status == .cancelled)
        #expect(runResponse.observation?.stdoutTail == "started")
    }

    @Test("Stop cleans an attached child after it changes process group")
    func stopCleansChangedProcessGroup() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/usr/bin/python3 -c 'import os, signal, time; os.setpgid(0, 0); signal.signal(signal.SIGTERM, signal.SIG_IGN); print(os.getpid(), flush=True); time.sleep(30)'",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let running = await client.handle(.run(request))
        let childPID = try #require(Int32(
            running.observation?.stdoutTail
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ), "Unexpected run response: \(running)")

        let stopped = await client.handle(.stop(request.jobID))
        await client.shutdown()

        #expect(stopped.observation?.status == .cancelled)
        #expect(await processDisappearedAfterShutdown(childPID))
    }

    @Test("returns a structured unavailable result when the worker cannot launch")
    func unavailableWorker() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: fixture.root.appending(path: "missing-worker"),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await client.handle(.run(request))

        #expect(response.observation == nil)
        #expect(response.error?.code == "worker_unavailable")
    }

    @Test("shutdown lets the worker cancel an active descendant")
    func shutdownKillsDescendant() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/bin/zsh -c 'trap \"\" TERM; while true; do /bin/sleep 1; done' & child=$!; printf '%s\\n' \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let running = await client.handle(.run(request))
        let childPID = try #require(Int32(
            running.observation?.stdoutTail
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ))

        await client.shutdown()

        #expect(await processDisappearedAfterShutdown(childPID))
    }

    @Test("times out a worker that remains alive without responding")
    func responseTimeout() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let fakeWorker = try fixture.makeUnresponsiveWorker()
        let client = ExecutionWorkerProcessClient(
            executableURL: fakeWorker,
            logsDirectory: fixture.logs,
            responseGraceMilliseconds: 100,
            shutdownGraceMilliseconds: 100
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await client.handle(.run(request))
        await client.shutdown()

        #expect(response.observation == nil)
        #expect(response.error?.code == "worker_response_timeout")
        #expect(await client.runningWorkerProcessIdentifier == nil)
    }

    @Test("malformed transport data returns only after worker shutdown")
    func malformedResponseShutdown() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let fakeWorker = try fixture.makeMalformedWorker()
        let client = ExecutionWorkerProcessClient(
            executableURL: fakeWorker,
            logsDirectory: fixture.logs,
            responseGraceMilliseconds: 100,
            shutdownGraceMilliseconds: 100
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await client.handle(.run(request))

        #expect(response.error?.code == "invalid_worker_response")
        #expect(await client.runningWorkerProcessIdentifier == nil)
    }

    @Test("a late valid frame cannot win after a malformed response")
    func lateResponseAfterMalformedFrame() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let requestID = UUID()
        let fakeWorker = try fixture.makeMalformedThenValidWorker(
            requestID: requestID
        )
        let client = ExecutionWorkerProcessClient(
            executableURL: fakeWorker,
            logsDirectory: fixture.logs,
            responseGraceMilliseconds: 500,
            shutdownGraceMilliseconds: 200
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await client.handle(.run(request, requestID: requestID))

        #expect(response.error?.code == "invalid_worker_response")
        #expect(response.observation == nil)
        #expect(await client.runningWorkerProcessIdentifier == nil)
    }

    @Test("abrupt worker termination kills the recorded process group")
    func abruptWorkerTermination() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let running = await client.handle(.run(request))
        let childPID = try #require(Int32(
            running.observation?.stdoutTail
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ))
        let workerPID = try #require(await client.runningWorkerProcessIdentifier)

        kill(workerPID, SIGKILL)

        #expect(await processDisappearedAfterShutdown(childPID))
        let metadataURL = fixture.logs
            .appending(path: request.jobID.rawValue.uuidString.lowercased())
            .appending(path: "job.json")
        #expect(await metadataEventuallyContains("unknown_outcome", at: metadataURL))
    }

    @Test("transport timeout recovers an active job from an unresponsive worker")
    func activeJobResponseTimeout() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs,
            responseGraceMilliseconds: 100,
            shutdownGraceMilliseconds: 100
        )
        let request = try ExecutionRequest(
            command: "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let running = await client.handle(.run(request))
        let childPID = try #require(Int32(
            running.observation?.stdoutTail
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ))
        let workerPID = try #require(await client.runningWorkerProcessIdentifier)
        kill(workerPID, SIGSTOP)

        let response = await client.handle(.wait(try ExecutionCheckpointRequest(
            jobID: request.jobID,
            checkpointSeconds: 1
        )))

        #expect(response.error?.code == "worker_response_timeout")
        #expect(await processDisappearedAfterShutdown(childPID))
        let metadataURL = fixture.logs
            .appending(path: request.jobID.rawValue.uuidString.lowercased())
            .appending(path: "job.json")
        #expect(await metadataEventuallyContains("unknown_outcome", at: metadataURL))
    }

    @Test("a new worker generation cannot drop unresolved prior ownership")
    func generationChangeRetainsUnresolvedOwnership() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let fakeWorker = try fixture.makeUnresponsiveWorker()
        let client = ExecutionWorkerProcessClient(
            executableURL: fakeWorker,
            logsDirectory: fixture.logs,
            responseGraceMilliseconds: 100,
            shutdownGraceMilliseconds: 100
        )
        let request = try ExecutionRequest(
            command: "pwd",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let first = await client.handle(.run(request))
        let blockedRequest = try ExecutionRequest(
            command: "printf second",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 30,
            interaction: .pipe
        )
        let blocked = await client.handle(.run(blockedRequest))
        let second = await client.handle(.stop(request.jobID))
        let cleanupProven = await client.shutdown()

        #expect(first.error?.code == "worker_response_timeout")
        #expect(blocked.error?.code == "worker_recovery_pending")
        #expect(second.error?.code == "worker_response_timeout")
        #expect(!cleanupProven)
    }

    @Test("supervisor cleans a background descendant after the shell exits")
    func shellExitCleansBackgroundDescendant() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/usr/bin/python3 -c 'import os, signal, time; os.setpgid(0, 0); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' >/dev/null 2>&1 & child=$!; /bin/sleep 0.1; printf '%s\\n' \"$child\"",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await client.handle(.run(request))
        let childPID = try #require(Int32(
            response.observation?.stdoutTail
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ))
        await client.shutdown()

        #expect(response.observation?.status == .succeeded)
        #expect(await processDisappearedAfterShutdown(childPID))
    }

    @Test("worker cleans attached descendants after supervisor death")
    func supervisorDeathCleansDescendants() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/usr/bin/python3 -c 'import os, signal, time; os.setpgid(0, 0); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' >/dev/null 2>&1 & child=$!; /bin/sleep 0.1; printf '%s %s\\n' \"$PPID\" \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let running = await client.handle(.run(request))
        let processIDs = try #require(running.observation?.stdoutTail.split(
            whereSeparator: { $0.isWhitespace }
        ).compactMap { Int32($0) })
        #expect(processIDs.count == 2)
        let supervisorPID = try #require(processIDs.first)
        let childPID = try #require(processIDs.last)

        kill(supervisorPID, SIGKILL)
        let completed = await client.handle(.wait(try ExecutionCheckpointRequest(
            jobID: request.jobID,
            checkpointSeconds: 5
        )))
        await client.shutdown()

        #expect(completed.observation?.status == .failed)
        #expect(await processDisappearedAfterShutdown(childPID))
    }

    @Test("supervised commands preserve native non-interactive zsh signal semantics")
    func nativeSignalDisposition() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/usr/bin/python3 -c 'import signal; print(signal.getsignal(signal.SIGINT) == signal.SIG_DFL, signal.getsignal(signal.SIGTERM) == signal.SIG_DFL)'",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await client.handle(.run(request))
        await client.shutdown()

        #expect(response.observation?.status == .succeeded)
        #expect(response.observation?.stdoutTail == "False True\n")
    }

    @Test("rapid Stop does not leave a TERM-resistant attached child")
    func rapidStop() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let client = ExecutionWorkerProcessClient(
            executableURL: try workerExecutable(),
            logsDirectory: fixture.logs
        )
        let request = try ExecutionRequest(
            command: "/bin/zsh -c 'trap \"\" TERM; while true; do /bin/sleep 1; done' & child=$!; printf '%s' \"$child\" > child.pid; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 30,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        let run = Task { await client.handle(.run(request)) }
        try await ContinuousClock().sleep(for: .milliseconds(10))

        let stopped = await client.handle(.stop(request.jobID))
        let runResponse = await run.value
        let cleanupProven = await client.shutdown()

        let jobDirectory = fixture.logs.appending(
            path: request.jobID.rawValue.uuidString.lowercased()
        )
        let metadataURL = jobDirectory.appending(path: "job.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let metadata = try #require(ExecutionJobMetadataStore.load(
                from: jobDirectory
            ))
            if metadata.status == .running {
                #expect(!cleanupProven)
            } else {
                #expect(metadata.status == .cancelled || metadata.status == .unknownOutcome)
            }
        } else {
            #expect(stopped.error?.code == "unknown_job")
            #expect(runResponse.error?.code == "request_cancelled")
        }
        let childPIDURL = fixture.workspace.appending(path: "child.pid")
        if let value = try? String(contentsOf: childPIDURL, encoding: .utf8),
           let childPID = Int32(value) {
            #expect(await processDisappearedAfterShutdown(childPID))
        }
    }

    @Test("a new worker startup recovers an orphan without client memory")
    func coldStartRecovery() async throws {
        let fixture = try WorkerProcessFixture()
        defer { fixture.remove() }
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let worker = Process()
        worker.executableURL = try workerExecutable()
        worker.arguments = ["--logs-directory", fixture.logs.path]
        worker.standardInput = inputPipe
        worker.standardOutput = outputPipe
        worker.standardError = FileHandle.nullDevice
        try worker.run()

        let request = try ExecutionRequest(
            command: "/bin/zsh -c 'trap \"\" TERM; while true; do /bin/sleep 1; done' & child=$!; printf '%s\\n' \"$child\"; wait",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )
        var data = try JSONEncoder().encode(ExecutionWorkerRequest.run(request))
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
        let response = try await firstWorkerResponse(
            from: outputPipe.fileHandleForReading
        )
        let childPID = try #require(Int32(
            response.observation?.stdoutTail
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ))

        kill(worker.processIdentifier, SIGKILL)
        worker.waitUntilExit()
        _ = try PipeExecutionService(logsDirectory: fixture.logs)

        #expect(await processDisappearedAfterShutdown(childPID))
        let metadataURL = fixture.logs
            .appending(path: request.jobID.rawValue.uuidString.lowercased())
            .appending(path: "job.json")
        #expect(await metadataEventuallyContains("unknown_outcome", at: metadataURL))
    }
}

private func processDisappearedAfterShutdown(_ processID: Int32) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if kill(processID, 0) == -1, errno == ESRCH { return true }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return kill(processID, 0) == -1 && errno == ESRCH
}

private func metadataEventuallyContains(_ value: String, at url: URL) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if (try? String(contentsOf: url, encoding: .utf8).contains(value)) == true {
            return true
        }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return (try? String(contentsOf: url, encoding: .utf8).contains(value)) == true
}

private func firstWorkerResponse(
    from fileHandle: FileHandle
) async throws -> ExecutionWorkerResponse {
    for try await line in fileHandle.bytes.lines {
        return try JSONDecoder().decode(
            ExecutionWorkerResponse.self,
            from: Data(line.utf8)
        )
    }
    throw WorkerProcessTestError.workerClosedWithoutResponse
}

private func workerExecutable() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let executable = packageRoot.appending(
        path: ".build/debug/PrivateAIExecutionWorker"
    )
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw WorkerProcessTestError.workerNotBuilt(executable.path)
    }
    return executable
}

private enum WorkerProcessTestError: Error, LocalizedError {
    case workerNotBuilt(String)
    case workerClosedWithoutResponse

    var errorDescription: String? {
        switch self {
        case .workerNotBuilt(let path):
            "Build PrivateAIExecutionWorker before running this integration test: \(path)"
        case .workerClosedWithoutResponse:
            "The execution worker closed before returning a response."
        }
    }
}

private final class WorkerProcessFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let logs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "privateai-worker-client-tests-\(UUID().uuidString)",
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

    func makeUnresponsiveWorker() throws -> URL {
        let executable = root.appending(path: "unresponsive-worker.zsh")
        try Data("#!/bin/zsh\nwhile true; do /bin/sleep 1; done\n".utf8)
            .write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func makeEnvironmentRecordingWorker(marker: URL) throws -> URL {
        let executable = root.appending(path: "environment-recording-worker.zsh")
        let script = """
        #!/bin/zsh
                {
                    print -r -- "${LLVM_PROFILE_FILE-unset}"
                    pwd
                    print -r -- "${PRIVATEAI_TEST_SECRET-unset}"
                } > "\(marker.path)"
        while true; do /bin/sleep 1; done
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func makeMalformedWorker() throws -> URL {
        let executable = root.appending(path: "malformed-worker.zsh")
        try Data("#!/bin/zsh\nIFS= read -r line\nprint -r -- not-json\nwhile true; do /bin/sleep 1; done\n".utf8)
            .write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func makeMalformedThenValidWorker(requestID: UUID) throws -> URL {
        let executable = root.appending(path: "malformed-then-valid-worker.zsh")
        let script = """
        #!/bin/zsh
        IFS= read -r line
        print -r -- not-json
        /bin/sleep 0.05
        print -r -- '{"protocol_version":1,"request_id":"\(requestID.uuidString)","error":{"code":"late_success","message":"must be ignored"}}'
        while true; do /bin/sleep 1; done
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return executable
    }
}