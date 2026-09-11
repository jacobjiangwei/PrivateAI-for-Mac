import Foundation

nonisolated struct DeviceContext: Encodable, Sendable {
    let localTime: String
    let timeZone: String
    let utcOffsetSeconds: Int
    let locale: String
    let languages: [String]
    let platform: String
    let architecture: String

    enum CodingKeys: String, CodingKey {
        case localTime = "local_time"
        case timeZone = "time_zone"
        case utcOffsetSeconds = "utc_offset_seconds"
        case locale, languages, platform, architecture
    }

    init(
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        languages: [String] = Locale.preferredLanguages,
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        localTime = formatter.string(from: now)
        self.timeZone = timeZone.identifier
        utcOffsetSeconds = timeZone.secondsFromGMT(for: now)
        self.locale = locale.identifier
        self.languages = Array(languages.prefix(3))
        platform = "macOS \(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "unknown"
        #endif
    }

    func prompt() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        return "Current device context (app-sampled at this user turn; use for today, not dates in history; no tool needed for these fields; locale is not location): \(json)"
    }

    func appending(to userPrompt: String) throws -> String {
        userPrompt + "\n\n" + (try prompt())
    }
}