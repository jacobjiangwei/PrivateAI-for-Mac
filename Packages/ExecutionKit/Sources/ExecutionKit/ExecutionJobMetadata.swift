import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ExecutionProcessIdentity: Codable, Equatable {
    let processID: Int32
    let processGroupID: Int32
    let sessionID: Int32?
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init?(processID: Int32) {
        var information = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &information) {
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard result == MemoryLayout<proc_bsdinfo>.size,
              information.pbi_pid == UInt32(processID) else {
            return nil
        }
                let sessionID = getsid(processID)
                guard sessionID >= 0 else { return nil }
        self.processID = processID
        processGroupID = Int32(information.pbi_pgid)
                self.sessionID = sessionID
        startSeconds = information.pbi_start_tvsec
        startMicroseconds = information.pbi_start_tvusec
    }
}

enum ExecutionProcessGroupController {
    static func terminate(
        recordedLeader: ExecutionProcessIdentity,
        excluding excludedProcessIDs: Set<pid_t> = []
    ) throws {
        guard recordedLeader.processID > 1,
              recordedLeader.processGroupID == recordedLeader.processID,
              recordedLeader.sessionID == recordedLeader.processID,
                            recordedLeader.processID != getpgrp()
                                || excludedProcessIDs.contains(getpid()) else {
            throw ExecutionProcessGroupError.invalidLeader(recordedLeader.processID)
        }
        if let currentLeader = ExecutionProcessIdentity(
            processID: recordedLeader.processID
        ), currentLeader != recordedLeader {
            throw ExecutionProcessGroupError.leaderIdentityChanged(
                recordedLeader.processID
            )
        }
        for _ in 0..<8 {
            let members = try sessionMembers(
                sessionID: recordedLeader.processID
            ).filter { !excludedProcessIDs.contains($0.processID) }
            if members.isEmpty { return }
            signal(members, SIGSTOP)
            usleep(1_000)
        }
        for _ in 0..<32 {
            let members = try sessionMembers(
                sessionID: recordedLeader.processID
            ).filter { !excludedProcessIDs.contains($0.processID) }
            if members.isEmpty { return }
            signal(members, SIGKILL)
            usleep(1_000)
        }
        let finalMembers = try sessionMembers(
            sessionID: recordedLeader.processID
        ).filter { !excludedProcessIDs.contains($0.processID) }
        guard finalMembers.isEmpty else {
            throw ExecutionProcessGroupError.membersRemain(
                finalMembers.map(\.processID)
            )
        }
    }

    private static func signal(
        _ members: [ExecutionProcessIdentity],
        _ signalNumber: Int32
    ) {
        for member in members
        where ExecutionProcessIdentity(processID: member.processID) == member {
            kill(member.processID, signalNumber)
        }
    }

    private static func sessionMembers(
        sessionID: pid_t
    ) throws -> [ExecutionProcessIdentity] {
        var capacity = 1_024
        for _ in 0..<4 {
            let requestedBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard requestedBytes > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            capacity = max(
                capacity,
                Int(requestedBytes) / MemoryLayout<pid_t>.size * 2 + 256
            )
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let populatedBytes = processIDs.withUnsafeMutableBytes {
                proc_listpids(
                    UInt32(PROC_ALL_PIDS),
                    0,
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            guard populatedBytes > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard populatedBytes < processIDs.count * MemoryLayout<pid_t>.size else {
                capacity *= 2
                continue
            }
            return processIDs.prefix(Int(populatedBytes) / MemoryLayout<pid_t>.size)
                .compactMap {
                    guard $0 > 1,
                          let identity = ExecutionProcessIdentity(processID: $0),
                          identity.sessionID == sessionID else {
                        return nil
                    }
                    return identity
                }
        }
        throw POSIXError(.ENOMEM)
    }
}

enum ExecutionProcessGroupError: Error, LocalizedError {
    case missingIdentity
    case invalidLeader(pid_t)
    case leaderIdentityChanged(pid_t)
    case membersRemain([pid_t])

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            "The execution session identity was not recorded."
        case .invalidLeader(let processID):
            "Process \(processID) is not the recorded execution session leader."
        case .leaderIdentityChanged(let processID):
            "Process \(processID) no longer matches the recorded execution identity."
        case .membersRemain(let processIDs):
            "Execution session members remain after cleanup: \(processIDs)."
        }
    }
}

struct ExecutionJobMetadata: Codable {
    static let currentVersion = 1

    let version: Int
    let jobID: ExecutionJobID
    var status: ExecutionStatus
    var processGroupID: Int32?
    var processIdentity: ExecutionProcessIdentity?
    let startedAt: Date
    var finishedAt: Date?
    var stdoutLogBytes: Int
    var stderrLogBytes: Int
    var logTruncated: Bool
}

struct ExecutionRecoveryResult {
    var unresolvedJobIDs = Set<ExecutionJobID>()
    var hasUnidentifiedJobs = false

    var isResolved: Bool {
        unresolvedJobIDs.isEmpty && !hasUnidentifiedJobs
    }
}

enum ExecutionJobMetadataStore {
    static let filename = "job.json"
    private static let formatMarkerFilename = ".execution-metadata-v1"
    private static let legacyDirectoryName = ".legacy-untracked"

    static func prepareCurrentFormat(in logsDirectory: URL) throws {
        let marker = logsDirectory.appending(path: formatMarkerFilename)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let legacyDirectory = logsDirectory.appending(
            path: legacyDirectoryName,
            directoryHint: .isDirectory
        )
        for directory in try jobDirectories(in: logsDirectory)
        where !FileManager.default.fileExists(
            atPath: directory.appending(path: filename).path
        ) {
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.moveItem(
                at: directory,
                to: legacyDirectory.appending(path: directory.lastPathComponent)
            )
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
    }

    static func write(_ metadata: ExecutionJobMetadata, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let destination = directory.appending(path: filename)
        try encoder.encode(metadata).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    static func load(from directory: URL) -> ExecutionJobMetadata? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appending(path: filename)),
              let metadata = try? decoder.decode(ExecutionJobMetadata.self, from: data),
              metadata.version == ExecutionJobMetadata.currentVersion else {
            return nil
        }
        return metadata
    }

    @discardableResult
    static func recoverUnfinishedJobs(in logsDirectory: URL) -> ExecutionRecoveryResult {
        var result = ExecutionRecoveryResult()
        let directories: [URL]
        do {
            directories = try jobDirectories(in: logsDirectory)
        } catch {
            result.hasUnidentifiedJobs = true
            return result
        }
        for directory in directories {
            guard var metadata = load(from: directory) else {
                recordUnidentifiedDirectory(directory, in: &result)
                continue
            }
            guard metadata.status == .running else {
                continue
            }
            do {
                try terminateRecordedProcessGroup(metadata)
                metadata.status = .unknownOutcome
                metadata.finishedAt = .now
                refreshLogMeasurements(&metadata, in: directory)
                try write(metadata, to: directory)
            } catch {
                metadata.status = .running
                metadata.finishedAt = nil
                refreshLogMeasurements(&metadata, in: directory)
                try? write(metadata, to: directory)
                result.unresolvedJobIDs.insert(metadata.jobID)
            }
        }
        return result
    }

    @discardableResult
    static func terminateAndMarkUnknown(
        in logsDirectory: URL,
        jobIDs: Set<ExecutionJobID>
    ) -> ExecutionRecoveryResult {
        var result = ExecutionRecoveryResult()
        for jobID in jobIDs {
            let directory = logsDirectory.appending(
                path: jobID.rawValue.uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            guard var metadata = load(from: directory), metadata.jobID == jobID else {
                result.unresolvedJobIDs.insert(jobID)
                continue
            }
            guard metadata.status == .running else {
                continue
            }
            do {
                try terminateRecordedProcessGroup(metadata)
                metadata.status = .unknownOutcome
                metadata.finishedAt = .now
                refreshLogMeasurements(&metadata, in: directory)
                try write(metadata, to: directory)
            } catch {
                metadata.status = .running
                metadata.finishedAt = nil
                refreshLogMeasurements(&metadata, in: directory)
                try? write(metadata, to: directory)
                result.unresolvedJobIDs.insert(metadata.jobID)
            }
        }
        let allRecovery = recoverUnfinishedJobs(in: logsDirectory)
        result.unresolvedJobIDs.formUnion(allRecovery.unresolvedJobIDs)
        result.hasUnidentifiedJobs = allRecovery.hasUnidentifiedJobs
        return result
    }

    static func pruneStoredJobs(
        in logsDirectory: URL,
        retentionInterval: TimeInterval,
        maximumTotalLogBytes: Int,
        maximumJobDirectories: Int,
        now: Date = .now
    ) {
        var completed: [(directory: URL, finishedAt: Date, logBytes: Int)] = []
        guard let directories = try? jobDirectories(in: logsDirectory) else { return }
        for directory in directories {
            guard let metadata = load(from: directory) else { continue }
            if metadata.status == .running { continue }
            let directoryDate = (try? directory.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let finishedAt = metadata.finishedAt ?? directoryDate
            if now.timeIntervalSince(finishedAt) >= retentionInterval {
                try? FileManager.default.removeItem(at: directory)
            } else {
                completed.append((
                    directory,
                    finishedAt,
                    actualLogBytes(in: directory)
                ))
            }
        }
        completed.sort { $0.finishedAt < $1.finishedAt }
        var totalLogBytes = completed.reduce(0) { $0 + $1.logBytes }
        var directoryCount = completed.count
        for item in completed where totalLogBytes > maximumTotalLogBytes
            || directoryCount > maximumJobDirectories {
            guard (try? FileManager.default.removeItem(at: item.directory)) != nil else {
                continue
            }
            totalLogBytes -= item.logBytes
            directoryCount -= 1
        }
    }

    private static func jobDirectories(in logsDirectory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }

    private static func recordUnidentifiedDirectory(
        _ directory: URL,
        in result: inout ExecutionRecoveryResult
    ) {
        if let uuid = UUID(uuidString: directory.lastPathComponent) {
            result.unresolvedJobIDs.insert(ExecutionJobID(rawValue: uuid))
        } else {
            result.hasUnidentifiedJobs = true
        }
    }

    private static func terminateRecordedProcessGroup(
        _ metadata: ExecutionJobMetadata
    ) throws {
        guard let recorded = metadata.processIdentity else {
            throw ExecutionProcessGroupError.missingIdentity
        }
        try ExecutionProcessGroupController.terminate(recordedLeader: recorded)
    }

    private static func refreshLogMeasurements(
        _ metadata: inout ExecutionJobMetadata,
        in directory: URL
    ) {
        metadata.stdoutLogBytes = logBytes(
            directory.appending(path: "stdout.log")
        )
        metadata.stderrLogBytes = logBytes(
            directory.appending(path: "stderr.log")
        )
    }

    private static func actualLogBytes(in directory: URL) -> Int {
        logBytes(directory.appending(path: "stdout.log"))
            + logBytes(directory.appending(path: "stderr.log"))
    }

    private static func logBytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}