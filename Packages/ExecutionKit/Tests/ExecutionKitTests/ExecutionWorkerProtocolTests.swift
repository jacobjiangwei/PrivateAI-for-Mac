import Foundation
import Testing
@testable import ExecutionKit

@Suite("Execution Worker Protocol")
struct ExecutionWorkerProtocolTests {
    @Test("round-trips a versioned run request")
    func runRequestRoundTrip() throws {
        let requestID = UUID()
        let execution = try ExecutionRequest(
            command: "swift test",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            timeoutSeconds: 1_800
        )
        let request = ExecutionWorkerRequest.run(execution, requestID: requestID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(request)
        let decoded = try JSONDecoder().decode(ExecutionWorkerRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.requestID == requestID)
    }

    @Test("rejects unsupported protocol versions")
    func unsupportedVersion() throws {
        let data = Data("""
        {
          "protocol_version": 2,
          "request_id": "00000000-0000-0000-0000-000000000001",
          "action": "stop",
          "job_id": { "rawValue": "00000000-0000-0000-0000-000000000002" }
        }
        """.utf8)

        #expect(throws: ExecutionWorkerProtocolError.unsupportedVersion(2)) {
            try JSONDecoder().decode(ExecutionWorkerRequest.self, from: data)
        }
    }

    @Test("rejects action and payload mismatches")
    func invalidPayload() throws {
        let execution = try ExecutionRequest(
            command: "pwd",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            timeoutSeconds: 60
        )
        let encoded = try JSONEncoder().encode(ExecutionWorkerRequest.run(execution))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["action"] = "wait"
        let malformed = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ExecutionWorkerProtocolError.invalidPayload(.wait)) {
            try JSONDecoder().decode(ExecutionWorkerRequest.self, from: malformed)
        }
    }

    @Test("revalidates decoded execution requests")
    func decodedRequestValidation() throws {
        let execution = try ExecutionRequest(
            command: "pwd",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            timeoutSeconds: 60
        )
        let encoded = try JSONEncoder().encode(ExecutionWorkerRequest.run(execution))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var payload = try #require(object["execution_request"] as? [String: Any])
        payload["command"] = "  "
        object["execution_request"] = payload
        let malformed = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ExecutionContractError.emptyCommand) {
            try JSONDecoder().decode(ExecutionWorkerRequest.self, from: malformed)
        }
    }

    @Test("handler executes a real request and preserves request identity")
    func handlerExecutesRequest() async throws {
        let fixture = try WorkerProtocolFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let handler = ExecutionWorkerHandler(service: service)
        let requestID = UUID()
        let execution = try ExecutionRequest(
            command: "printf worker",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 5,
            timeoutSeconds: 30,
            interaction: .pipe
        )

        let response = await handler.handle(.run(execution, requestID: requestID))

        #expect(response.requestID == requestID)
        #expect(response.observation?.status == .succeeded)
        #expect(response.observation?.stdoutTail == "worker")
        #expect(response.error == nil)
    }

    @Test("handler returns a structured error for an unknown job")
    func handlerUnknownJob() async throws {
        let fixture = try WorkerProtocolFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let handler = ExecutionWorkerHandler(service: service)

        let response = await handler.handle(.stop(ExecutionJobID()))

        #expect(response.observation == nil)
        #expect(response.error?.code == "unknown_job")
    }

    @Test("rejects response protocol versions and ambiguous payloads")
    func responseEnvelopeValidation() throws {
        let requestID = UUID()
        let wrongVersion = Data("""
        {"protocol_version":2,"request_id":"\(requestID.uuidString)","error":{"code":"x","message":"y"}}
        """.utf8)
        #expect(throws: ExecutionWorkerProtocolError.unsupportedVersion(2)) {
            try JSONDecoder().decode(ExecutionWorkerResponse.self, from: wrongVersion)
        }

        let ambiguous = Data("""
        {"protocol_version":1,"request_id":"\(requestID.uuidString)"}
        """.utf8)
        #expect(throws: ExecutionWorkerProtocolError.invalidResponsePayload) {
            try JSONDecoder().decode(ExecutionWorkerResponse.self, from: ambiguous)
        }
    }

    @Test("a stop received before run prevents that job from starting")
    func stopBeforeRun() async throws {
        let fixture = try WorkerProtocolFixture()
        defer { fixture.remove() }
        let service = try PipeExecutionService(logsDirectory: fixture.logs)
        let handler = ExecutionWorkerHandler(service: service)
        let execution = try ExecutionRequest(
            command: "/bin/sleep 30",
            workingDirectory: fixture.workspace,
            checkpointSeconds: 1,
            timeoutSeconds: 60,
            interaction: .pipe
        )

        let stop = await handler.handle(.stop(execution.jobID))
        let run = await handler.handle(.run(execution))

        #expect(stop.error?.code == "unknown_job")
        #expect(run.error?.code == "request_cancelled")
        #expect(!FileManager.default.fileExists(atPath: fixture.logs.appending(
            path: execution.jobID.rawValue.uuidString.lowercased()
        ).path))
    }
}

private final class WorkerProtocolFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let logs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "privateai-worker-protocol-tests-\(UUID().uuidString)",
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