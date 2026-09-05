import Foundation

public enum ExecutionWorkerAction: String, Codable, Equatable, Sendable {
    case run
    case wait
    case stop
}

public enum ExecutionWorkerProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidPayload(ExecutionWorkerAction)
    case invalidResponsePayload

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Execution worker protocol version \(version) is not supported."
        case .invalidPayload(let action):
            "Execution worker action '\(action.rawValue)' has an invalid payload."
        case .invalidResponsePayload:
            "Execution worker response must contain exactly one observation or error."
        }
    }
}

public struct ExecutionWorkerRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: UUID
    public let action: ExecutionWorkerAction
    public let executionRequest: ExecutionRequest?
    public let checkpointRequest: ExecutionCheckpointRequest?
    public let jobID: ExecutionJobID?

    public static func run(
        _ request: ExecutionRequest,
        requestID: UUID = UUID()
    ) -> ExecutionWorkerRequest {
        ExecutionWorkerRequest(
            requestID: requestID,
            action: .run,
            executionRequest: request
        )
    }

    public static func wait(
        _ request: ExecutionCheckpointRequest,
        requestID: UUID = UUID()
    ) -> ExecutionWorkerRequest {
        ExecutionWorkerRequest(
            requestID: requestID,
            action: .wait,
            checkpointRequest: request
        )
    }

    public static func stop(
        _ jobID: ExecutionJobID,
        requestID: UUID = UUID()
    ) -> ExecutionWorkerRequest {
        ExecutionWorkerRequest(
            requestID: requestID,
            action: .stop,
            jobID: jobID
        )
    }

    private init(
        requestID: UUID,
        action: ExecutionWorkerAction,
        executionRequest: ExecutionRequest? = nil,
        checkpointRequest: ExecutionCheckpointRequest? = nil,
        jobID: ExecutionJobID? = nil
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.requestID = requestID
        self.action = action
        self.executionRequest = executionRequest
        self.checkpointRequest = checkpointRequest
        self.jobID = jobID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ExecutionWorkerProtocolError.unsupportedVersion(protocolVersion)
        }
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        let action = try container.decode(ExecutionWorkerAction.self, forKey: .action)
        let executionRequest = try container.decodeIfPresent(
            ExecutionRequest.self,
            forKey: .executionRequest
        )
        let checkpointRequest = try container.decodeIfPresent(
            ExecutionCheckpointRequest.self,
            forKey: .checkpointRequest
        )
        let jobID = try container.decodeIfPresent(ExecutionJobID.self, forKey: .jobID)

        switch action {
        case .run:
            guard let executionRequest,
                  checkpointRequest == nil,
                  jobID == nil else {
                throw ExecutionWorkerProtocolError.invalidPayload(action)
            }
            self = ExecutionWorkerRequest.run(
                try executionRequest.validated(),
                requestID: requestID
            )
        case .wait:
            guard let checkpointRequest,
                  executionRequest == nil,
                  jobID == nil else {
                throw ExecutionWorkerProtocolError.invalidPayload(action)
            }
            self = ExecutionWorkerRequest.wait(
                try checkpointRequest.validated(),
                requestID: requestID
            )
        case .stop:
            guard let jobID,
                  executionRequest == nil,
                  checkpointRequest == nil else {
                throw ExecutionWorkerProtocolError.invalidPayload(action)
            }
            self = ExecutionWorkerRequest.stop(jobID, requestID: requestID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case action
        case executionRequest = "execution_request"
        case checkpointRequest = "checkpoint_request"
        case jobID = "job_id"
    }
}

public struct ExecutionWorkerFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ExecutionWorkerResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let observation: ExecutionObservation?
    public let error: ExecutionWorkerFailure?

    private init(
        protocolVersion: Int,
        requestID: UUID,
        observation: ExecutionObservation?,
        error: ExecutionWorkerFailure?
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.observation = observation
        self.error = error
    }

    public static func success(
        requestID: UUID,
        observation: ExecutionObservation
    ) -> ExecutionWorkerResponse {
        ExecutionWorkerResponse(
            protocolVersion: ExecutionWorkerRequest.currentProtocolVersion,
            requestID: requestID,
            observation: observation,
            error: nil
        )
    }

    public static func failure(
        requestID: UUID,
        code: String,
        message: String
    ) -> ExecutionWorkerResponse {
        ExecutionWorkerResponse(
            protocolVersion: ExecutionWorkerRequest.currentProtocolVersion,
            requestID: requestID,
            observation: nil,
            error: ExecutionWorkerFailure(code: code, message: message)
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == ExecutionWorkerRequest.currentProtocolVersion else {
            throw ExecutionWorkerProtocolError.unsupportedVersion(protocolVersion)
        }
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        let observation = try container.decodeIfPresent(
            ExecutionObservation.self,
            forKey: .observation
        )
        let error = try container.decodeIfPresent(
            ExecutionWorkerFailure.self,
            forKey: .error
        )
        guard (observation == nil) != (error == nil) else {
            throw ExecutionWorkerProtocolError.invalidResponsePayload
        }
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.observation = observation
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case observation
        case error
    }
}

public protocol ExecutionWorkerServing: Sendable {
    func handle(_ request: ExecutionWorkerRequest) async -> ExecutionWorkerResponse
    @discardableResult func shutdown() async -> Bool
}

public actor ExecutionWorkerHandler: ExecutionWorkerServing {
    private let service: PipeExecutionService
    private var cancelledBeforeStart = Set<ExecutionJobID>()
    private var cancellationOrder: [ExecutionJobID] = []

    public init(service: PipeExecutionService) {
        self.service = service
    }

    @discardableResult
    public func shutdown() async -> Bool {
        await service.cancelAll(reason: .cancelled)
    }

    public func handle(_ request: ExecutionWorkerRequest) async -> ExecutionWorkerResponse {
        do {
            let observation: ExecutionObservation
            switch request.action {
            case .run:
                let jobID = request.executionRequest!.jobID
                if cancelledBeforeStart.remove(jobID) != nil {
                    cancellationOrder.removeAll { $0 == jobID }
                    return .failure(
                        requestID: request.requestID,
                        code: "request_cancelled",
                        message: "The execution job was stopped before it started."
                    )
                }
                observation = try await service.run(request.executionRequest!)
            case .wait:
                observation = try await service.wait(request.checkpointRequest!)
            case .stop:
                do {
                    observation = try await service.stop(request.jobID!)
                } catch ExecutionServiceError.unknownJob {
                    rememberCancellation(request.jobID!)
                    throw ExecutionServiceError.unknownJob(request.jobID!)
                }
            }
            return .success(requestID: request.requestID, observation: observation)
        } catch {
            return .failure(
                requestID: request.requestID,
                code: errorCode(error),
                message: error.localizedDescription
            )
        }
    }

    private func rememberCancellation(_ jobID: ExecutionJobID) {
        guard cancelledBeforeStart.insert(jobID).inserted else { return }
        cancellationOrder.append(jobID)
        if cancellationOrder.count > 128 {
            cancelledBeforeStart.remove(cancellationOrder.removeFirst())
        }
    }

    private func errorCode(_ error: any Error) -> String {
        switch error {
        case ExecutionServiceError.duplicateJob:
            "duplicate_job"
        case ExecutionServiceError.unknownJob:
            "unknown_job"
        case ExecutionServiceError.unsupportedInteraction:
            "unsupported_interaction"
        case ExecutionServiceError.tooManyActiveJobs:
            "too_many_active_jobs"
        case ExecutionServiceError.workingDirectoryOutsideWorkspace:
            "working_directory_outside_workspace"
        case is ExecutionContractError:
            "invalid_request"
        default:
            "execution_failed"
        }
    }
}