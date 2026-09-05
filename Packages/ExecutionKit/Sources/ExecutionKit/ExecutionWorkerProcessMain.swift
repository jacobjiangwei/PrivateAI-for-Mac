import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ExecutionWorkerProcessMain {
    public static func run(arguments: [String] = CommandLine.arguments) async -> Int32 {
        if arguments.count == 3, arguments[1] == "--supervise-command" {
            return ExecutionCommandSupervisor.run(command: arguments[2])
        }
        do {
            let logsDirectory = try parseLogsDirectory(arguments: arguments)
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logsDirectory.path
            )
            let workerLock = try ExecutionWorkerInstanceLock(
                url: logsDirectory.appending(path: "worker.lock")
            )
            defer { withExtendedLifetime(workerLock) {} }
            let service = try PipeExecutionService(
                logsDirectory: logsDirectory,
                supervisorExecutableURL: URL(fileURLWithPath: arguments[0])
            )
            let handler = ExecutionWorkerHandler(service: service)
            let output = ExecutionWorkerOutput(fileHandle: .standardOutput)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await line in FileHandle.standardInput.bytes.lines {
                    group.addTask {
                        let response = await response(
                            for: Data(line.utf8),
                            handler: handler
                        )
                        try await output.write(response)
                    }
                }
                group.cancelAll()
                _ = await service.cancelAll(reason: .interrupted)
                try await group.waitForAll()
            }
            return EXIT_SUCCESS
        } catch {
            let message = "PrivateAIExecutionWorker failed: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            return EXIT_FAILURE
        }
    }

    private static func parseLogsDirectory(arguments: [String]) throws -> URL {
        guard arguments.count == 3,
              arguments[1] == "--logs-directory",
              arguments[2].hasPrefix("/") else {
            throw ExecutionWorkerMainError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[2], isDirectory: true)
    }

    private static func response(
        for data: Data,
        handler: ExecutionWorkerHandler
    ) async -> ExecutionWorkerResponse {
        do {
            let request = try JSONDecoder().decode(ExecutionWorkerRequest.self, from: data)
            return await handler.handle(request)
        } catch {
            return .failure(
                requestID: requestID(in: data) ?? zeroRequestID,
                code: "invalid_protocol_request",
                message: error.localizedDescription
            )
        }
    }

    private static func requestID(in data: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["request_id"] as? String else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private static let zeroRequestID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

private actor ExecutionWorkerOutput {
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func write(_ response: ExecutionWorkerResponse) throws {
        var data = try encoder.encode(response)
        data.append(0x0A)
        try fileHandle.write(contentsOf: data)
    }
}

private enum ExecutionWorkerMainError: Error, LocalizedError {
    case invalidArguments
    case workerAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: PrivateAIExecutionWorker --logs-directory /absolute/path"
        case .workerAlreadyRunning:
            "Another execution worker already owns this logs directory."
        }
    }
}

private final class ExecutionWorkerInstanceLock {
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ExecutionWorkerMainError.workerAlreadyRunning
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}