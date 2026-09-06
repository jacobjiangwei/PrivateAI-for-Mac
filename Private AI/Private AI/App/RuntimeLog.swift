import Foundation

nonisolated struct ManagedRuntimeDirectory {
    let root: URL
    let workspaces: URL
    let defaultWorkspace: URL
    let logs: URL
    let artifacts: URL
    let jobs: URL
    let state: URL
    let browserFrames: URL

    init(fileManager: FileManager = .default) throws {
        root = fileManager.homeDirectoryForCurrentUser.appending(path: ".privateAI", directoryHint: .isDirectory)
        workspaces = root.appending(path: "workspaces", directoryHint: .isDirectory)
        defaultWorkspace = workspaces.appending(path: "default", directoryHint: .isDirectory)
        logs = root.appending(path: "logs", directoryHint: .isDirectory)
        artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        state = root.appending(path: "state", directoryHint: .isDirectory)
        browserFrames = logs.appending(path: "browser-frames", directoryHint: .isDirectory)
        for directory in ["workspaces", "jobs", "logs", "artifacts", "state", "logs/browser-frames"] {
            try fileManager.createDirectory(
                at: root.appending(path: directory, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        try fileManager.createDirectory(
            at: defaultWorkspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: defaultWorkspace.path
        )
    }
}

actor RuntimeLog {
    let fileURL: URL
    let runsDirectory: URL
    let sessionID = UUID()
    private var sequence: UInt64 = 0
    private let maximumStringCharacters = 100_000

    init(directory: ManagedRuntimeDirectory) throws {
        try self.init(
            fileURL: directory.logs.appending(path: "app.jsonl"),
            runsDirectory: directory.logs.appending(path: "runs", directoryHint: .isDirectory)
        )
    }

    init(fileURL: URL, runsDirectory: URL? = nil) throws {
        self.fileURL = fileURL
        self.runsDirectory = runsDirectory
            ?? fileURL.deletingLastPathComponent().appending(path: "runs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: self.runsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: self.runsDirectory.path
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    static func preparePrivacyMigration(
        logsDirectory: URL,
        stateDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let marker = stateDirectory.appending(path: "runtime-log-privacy-v1")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        if fileManager.fileExists(atPath: logsDirectory.path) {
            try fileManager.removeItem(at: logsDirectory)
        }
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: logsDirectory.path
        )
        try Data("1\n".utf8).write(to: marker, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    func record(
        _ event: String,
        level: String = "info",
        category: String = "app",
        runID: UUID? = nil,
        conversationID: UUID? = nil,
        round: Int? = nil,
        data: [String: Any] = [:]
    ) {
        sequence += 1
        var payload: [String: Any] = [
            "category": category,
            "data": sanitized(data),
            "event": event,
            "level": level,
            "sequence": sequence,
            "session_id": sessionID.uuidString,
            "timestamp": Date().ISO8601Format()
        ]
        if let runID { payload["run_id"] = runID.uuidString }
        if let conversationID { payload["conversation_id"] = conversationID.uuidString }
        if let round { payload["round"] = round }
        let destination = runID.map(runFileURLValue) ?? fileURL
          if !FileManager.default.fileExists(atPath: destination.path) {
            try? Data().write(to: destination, options: .atomic)
                        try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: destination.path
                        )
          }
          guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: destination)
        else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            return
        }
    }

    func record(_ event: String, fields: [String: String]) {
        record(event, data: fields)
    }

    func runFileURL(for runID: UUID) -> URL {
        runFileURLValue(runID)
    }

    private func runFileURLValue(_ runID: UUID) -> URL {
        runsDirectory.appending(path: "\(runID.uuidString.lowercased()).jsonl")
    }

    private func sanitized(_ value: Any, key: String = "") -> Any {
        let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let sensitiveKeys: Set<String> = [
            "authorization", "cookie", "password", "passphrase", "private_key",
            "secret", "token", "api_key", "access_key", "session_key",
            "access_token", "refresh_token", "id_token", "bearer_token"
        ]
        let sensitiveSuffixes = ["_password", "_passphrase", "_secret", "_api_key", "_private_key"]
        if sensitiveKeys.contains(normalizedKey)
            || sensitiveSuffixes.contains(where: normalizedKey.hasSuffix)
        {
            return "[REDACTED]"
        }
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitized(entry.value, key: entry.key)
            }
        case let dictionary as [String: String]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitized(entry.value, key: entry.key)
            }
        case let array as [Any]:
            return array.map { sanitized($0) }
        case let string as String:
            if string.count > maximumStringCharacters {
                return String(string.prefix(maximumStringCharacters)) + "\n[TRUNCATED]"
            }
            return string
        case is NSNull, is NSNumber:
            return value
        default:
            return String(describing: value)
        }
    }
}