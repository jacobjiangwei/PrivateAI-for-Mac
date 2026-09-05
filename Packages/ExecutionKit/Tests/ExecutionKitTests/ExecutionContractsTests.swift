import Foundation
import Testing
@testable import ExecutionKit

@Suite("Execution Contracts")
struct ExecutionContractsTests {
    @Test("uses a 60-second first model checkpoint")
    func defaultCheckpoint() throws {
        let request = try ExecutionRequest(
            command: "swift test",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            timeoutSeconds: 1_800
        )

        #expect(request.checkpointSeconds == 60)
        #expect(request.interaction == .automatic)
    }

    @Test("keeps a stable job identity across checkpoint requests")
    func stableJobIdentity() throws {
        let jobID = ExecutionJobID()
        let checkpoint = try ExecutionCheckpointRequest(
            jobID: jobID,
            checkpointSeconds: 120
        )

        #expect(checkpoint.jobID == jobID)
        #expect(checkpoint.checkpointSeconds == 120)
    }

    @Test("rejects commands that are empty or exceed the protocol limit")
    func invalidCommands() {
        #expect(throws: ExecutionContractError.emptyCommand) {
            try ExecutionRequest(
                command: "  \n",
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                timeoutSeconds: 60
            )
        }
        #expect(throws: ExecutionContractError.commandContainsNullByte) {
            try ExecutionRequest(
                command: "printf before\0printf after",
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                timeoutSeconds: 60
            )
        }
        #expect(throws: ExecutionContractError.commandTooLarge(
            maximumBytes: ExecutionRequest.maximumCommandBytes
        )) {
            try ExecutionRequest(
                command: String(repeating: "x", count: 64 * 1_024 + 1),
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                timeoutSeconds: 60
            )
        }
    }

    @Test("requires absolute working directories and bounded durations")
    func invalidExecutionBounds() {
        #expect(throws: ExecutionContractError.workingDirectoryMustBeAbsolute) {
            try ExecutionRequest(
                command: "pwd",
                workingDirectory: URL(string: "relative/path")!,
                timeoutSeconds: 60
            )
        }
        #expect(throws: ExecutionContractError.invalidCheckpointSeconds(301)) {
            try ExecutionRequest(
                command: "pwd",
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                checkpointSeconds: 301,
                timeoutSeconds: 60
            )
        }
        #expect(throws: ExecutionContractError.invalidTimeoutSeconds(0)) {
            try ExecutionRequest(
                command: "pwd",
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                timeoutSeconds: 0
            )
        }
    }

    @Test("round-trips versionable job observations")
    func observationCoding() throws {
        let observation = ExecutionObservation(
            jobID: ExecutionJobID(),
            status: .running,
            command: "swift test",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            elapsedSeconds: 60,
            exitCode: nil,
            stdoutSinceCheckpoint: "Building...",
            stderrSinceCheckpoint: "",
            stdoutTail: "Building...",
            stderrTail: "",
            stdoutBytesSinceCheckpoint: 11,
            stderrBytesSinceCheckpoint: 0,
            outputTruncated: false,
            logURL: URL(fileURLWithPath: "/tmp/jobs/1/output.log"),
            failureMessage: nil
        )

        let data = try JSONEncoder().encode(observation)
        let decoded = try JSONDecoder().decode(ExecutionObservation.self, from: data)

        #expect(decoded == observation)
    }
}