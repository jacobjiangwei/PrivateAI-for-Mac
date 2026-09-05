import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ExecutionDirectoryIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(directoryURL: URL) throws {
        var information = Darwin.stat()
        let result = directoryURL.path.withCString {
            lstat($0, &information)
        }
        guard result == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTDIR)
        }
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
    }

    init(fileDescriptor: Int32) throws {
        var information = Darwin.stat()
        guard fstat(fileDescriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTDIR)
        }
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
    }
}

public struct ExecutionJobID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ExecutionInteraction: String, Codable, Equatable, Sendable {
    case automatic
    case pipe
    case pseudoTerminal = "pty"
}

public enum ExecutionStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case timedOut = "timed_out"
    case cancelled
    case interrupted
    case unknownOutcome = "unknown_outcome"
}

public enum ExecutionContractError: Error, Equatable, LocalizedError, Sendable {
    case emptyCommand
    case commandContainsNullByte
    case commandTooLarge(maximumBytes: Int)
    case workingDirectoryMustBeAbsolute
    case invalidCheckpointSeconds(Int)
    case invalidTimeoutSeconds(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "The command must not be empty."
        case .commandContainsNullByte:
            "The command must not contain a null byte."
        case .commandTooLarge(let maximumBytes):
            "The command must not exceed \(maximumBytes) UTF-8 bytes."
        case .workingDirectoryMustBeAbsolute:
            "The working directory must be an absolute file URL."
        case .invalidCheckpointSeconds(let seconds):
            "The checkpoint interval must be between 1 and 300 seconds, not \(seconds)."
        case .invalidTimeoutSeconds(let seconds):
            "The timeout must be between 1 and 86,400 seconds, not \(seconds)."
        }
    }
}

public struct ExecutionRequest: Codable, Equatable, Sendable {
    public static let maximumCommandBytes = 64 * 1_024
    public static let defaultCheckpointSeconds = 60

    public let jobID: ExecutionJobID
    public let command: String
    public let workspaceRoot: URL
    public let workspaceIdentity: ExecutionDirectoryIdentity?
    public let workingDirectory: URL
    public let checkpointSeconds: Int
    public let timeoutSeconds: Int
    public let interaction: ExecutionInteraction
    public let environment: [String: String]

    public init(
        jobID: ExecutionJobID = ExecutionJobID(),
        command: String,
        workspaceRoot: URL? = nil,
        workspaceIdentity: ExecutionDirectoryIdentity? = nil,
        workingDirectory: URL,
        checkpointSeconds: Int = Self.defaultCheckpointSeconds,
        timeoutSeconds: Int,
        interaction: ExecutionInteraction = .automatic,
        environment: [String: String] = [:]
    ) throws {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw ExecutionContractError.emptyCommand
        }
        guard !command.utf8.contains(0) else {
            throw ExecutionContractError.commandContainsNullByte
        }
        guard command.lengthOfBytes(using: .utf8) <= Self.maximumCommandBytes else {
            throw ExecutionContractError.commandTooLarge(
                maximumBytes: Self.maximumCommandBytes
            )
        }
        guard workingDirectory.isFileURL,
              workingDirectory.path.hasPrefix("/") else {
            throw ExecutionContractError.workingDirectoryMustBeAbsolute
        }
                let resolvedWorkspaceRoot = workspaceRoot ?? workingDirectory
                guard resolvedWorkspaceRoot.isFileURL,
                            resolvedWorkspaceRoot.path.hasPrefix("/") else {
                        throw ExecutionContractError.workingDirectoryMustBeAbsolute
                }
        guard (1...300).contains(checkpointSeconds) else {
            throw ExecutionContractError.invalidCheckpointSeconds(checkpointSeconds)
        }
        guard (1...86_400).contains(timeoutSeconds) else {
            throw ExecutionContractError.invalidTimeoutSeconds(timeoutSeconds)
        }

        self.jobID = jobID
        self.command = command
        self.workspaceRoot = resolvedWorkspaceRoot.standardizedFileURL
        self.workspaceIdentity = workspaceIdentity
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.checkpointSeconds = checkpointSeconds
        self.timeoutSeconds = timeoutSeconds
        self.interaction = interaction
        self.environment = environment
    }

    func validated() throws -> ExecutionRequest {
        try ExecutionRequest(
            jobID: jobID,
            command: command,
            workspaceRoot: workspaceRoot,
            workspaceIdentity: workspaceIdentity,
            workingDirectory: workingDirectory,
            checkpointSeconds: checkpointSeconds,
            timeoutSeconds: timeoutSeconds,
            interaction: interaction,
            environment: environment
        )
    }
}

public struct ExecutionCheckpointRequest: Codable, Equatable, Sendable {
    public let jobID: ExecutionJobID
    public let checkpointSeconds: Int

    public init(
        jobID: ExecutionJobID,
        checkpointSeconds: Int = ExecutionRequest.defaultCheckpointSeconds
    ) throws {
        guard (1...300).contains(checkpointSeconds) else {
            throw ExecutionContractError.invalidCheckpointSeconds(checkpointSeconds)
        }
        self.jobID = jobID
        self.checkpointSeconds = checkpointSeconds
    }

    func validated() throws -> ExecutionCheckpointRequest {
        try ExecutionCheckpointRequest(
            jobID: jobID,
            checkpointSeconds: checkpointSeconds
        )
    }
}

public struct ExecutionObservation: Codable, Equatable, Sendable {
    public let jobID: ExecutionJobID
    public let status: ExecutionStatus
    public let command: String
    public let workingDirectory: URL
    public let elapsedSeconds: Double
    public let exitCode: Int32?
    public let stdoutSinceCheckpoint: String
    public let stderrSinceCheckpoint: String
    public let stdoutTail: String
    public let stderrTail: String
    public let stdoutBytesSinceCheckpoint: Int
    public let stderrBytesSinceCheckpoint: Int
    public let outputTruncated: Bool
    public let logTruncated: Bool
    public let logURL: URL
    public let failureMessage: String?

    public init(
        jobID: ExecutionJobID,
        status: ExecutionStatus,
        command: String,
        workingDirectory: URL,
        elapsedSeconds: Double,
        exitCode: Int32?,
        stdoutSinceCheckpoint: String,
        stderrSinceCheckpoint: String,
        stdoutTail: String,
        stderrTail: String,
        stdoutBytesSinceCheckpoint: Int,
        stderrBytesSinceCheckpoint: Int,
        outputTruncated: Bool,
        logTruncated: Bool = false,
        logURL: URL,
        failureMessage: String? = nil
    ) {
        self.jobID = jobID
        self.status = status
        self.command = command
        self.workingDirectory = workingDirectory
        self.elapsedSeconds = elapsedSeconds
        self.exitCode = exitCode
        self.stdoutSinceCheckpoint = stdoutSinceCheckpoint
        self.stderrSinceCheckpoint = stderrSinceCheckpoint
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.stdoutBytesSinceCheckpoint = stdoutBytesSinceCheckpoint
        self.stderrBytesSinceCheckpoint = stderrBytesSinceCheckpoint
        self.outputTruncated = outputTruncated
        self.logTruncated = logTruncated
        self.logURL = logURL
        self.failureMessage = failureMessage
    }
}