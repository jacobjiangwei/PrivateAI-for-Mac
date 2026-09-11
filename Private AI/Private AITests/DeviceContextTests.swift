import Foundation
import LLMCore
import Testing
@testable import Private_AI

@Suite("Device Context")
struct DeviceContextTests {
    @Test("samples local dates across midnight without assuming UTC or the model training date")
    func localDate() throws {
        let formatter = ISO8601DateFormatter()
        let first = try #require(formatter.date(from: "2026-09-11T15:59:59Z"))
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let before = DeviceContext(now: first, timeZone: zone, locale: Locale(identifier: "zh_Hans_CN"), languages: ["zh-Hans", "en"])
        let after = DeviceContext(now: first.addingTimeInterval(2), timeZone: zone)
        #expect(before.localTime == "2026-09-11T23:59:59+08:00")
        #expect(after.localTime == "2026-09-12T00:00:01+08:00")
        #expect(before.utcOffsetSeconds == 28_800)
        #expect(before.locale == Locale(identifier: "zh_Hans_CN").identifier)
        #expect(before.languages == ["zh-Hans", "en"])
        let prompt = try before.prompt()
        #expect(prompt.utf8.count < 700)
        #expect(!prompt.contains("\n"))
        #expect(!prompt.contains(ProcessInfo.processInfo.hostName))
        #expect(!prompt.contains(NSHomeDirectory()))
    }

    @Test("uses the offset for the sampled instant including daylight saving time")
    func daylightSaving() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let before = try #require(formatter.date(from: "2026-03-08T06:59:59Z"))
        #expect(DeviceContext(now: before, timeZone: zone).utcOffsetSeconds == -18_000)
        #expect(DeviceContext(now: before.addingTimeInterval(2), timeZone: zone).utcOffsetSeconds == -14_400)
    }

    @Test("samples once for a user turn and leaves the original prompt unchanged")
    func requestContext() throws {
        let context = DeviceContext(now: Date(timeIntervalSince1970: 1_000))
        let userPrompt = "What is today?"
        let first = try context.appending(to: userPrompt)
        let toolRound = try context.appending(to: userPrompt)
        let nextTurn = try DeviceContext(now: Date(timeIntervalSince1970: 2_000)).appending(to: userPrompt)
        #expect(first == toolRound)
        #expect(nextTurn != first)
        #expect(first.hasPrefix(userPrompt + "\n\n"))
        #expect(first.components(separatedBy: "Current device context").count == 2)
        #expect(userPrompt == "What is today?")
    }
}