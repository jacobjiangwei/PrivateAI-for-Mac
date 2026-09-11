//
//  Private_AIUITests.swift
//  Private AIUITests
//
//  Created by jacob on 2026/8/29.
//

import XCTest

final class Private_AIUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testModelTransparencyAndNewConversationFocus() throws {
        let app = XCUIApplication()
        app.launch()

        let performance = app.descendants(matching: .any)["generation.metrics.section"]
        guard performance.waitForExistence(timeout: 60) else {
            throw XCTSkip("Ollama did not become ready, so model UI could not be exercised.")
        }
        XCTAssertTrue(app.staticTexts["generation.ttft"].exists)
        XCTAssertTrue(app.staticTexts["generation.tokenRate"].exists)

        let transparencyButton = app.buttons["model.transparency.button"]
        XCTAssertTrue(transparencyButton.exists)
        transparencyButton.click()
        let transparencyPanel = app.descendants(matching: .any)["model.transparency.panel"]
        XCTAssertTrue(transparencyPanel.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["System prompt"].exists)
        XCTAssertTrue(app.staticTexts["Version 5"].exists)

        app.typeKey(.escape, modifierFlags: [])
        app.buttons["conversation.new.button"].click()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["chat.attachment.button"].exists)
        // TODO: Assert focus through an App-owned test probe; never inject keyboard input.
    }

    @MainActor
    func testWebToolInputOutputPrecedesFinalAnswerAndScrollsToLatest() throws {
        let app = XCUIApplication()
        app.launch()

        guard app.descendants(matching: .any)["generation.metrics.section"]
            .waitForExistence(timeout: 60)
        else {
            throw XCTSkip("Ollama did not become ready, so the Tool E2E could not run.")
        }

        app.buttons["conversation.new.button"].click()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        throw XCTSkip(
            "TODO: Drive this scenario through an App-owned test API without keyboard injection, then verify the Tool transcript and product log."
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testLiveGenerationMetricsAndRawTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "privateai-trace-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("TRACE_UI_DIRECTORY=\(directory.path)")
        let total = (1...12).reduce(0) { $0 + $1 * $1 }
        let zone = TimeZone.current
        let offset = zone.secondsFromGMT()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = zone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let capacity = try XCTUnwrap(filesystem[.systemSize] as? NSNumber).uint64Value
        let scenarios: [(name: String, prompt: String, expected: [String], width: Int)] = [
            ("math", "List the integers from 1 through 12 and their squares. Explain how to sum those squares and end with TOTAL=<integer>.", ["TOTAL=\(total)"], 1040),
            ("date", "What is today's local date and this Mac's time zone, UTC offset in seconds, and locale? End with TODAY=YYYY-MM-DD, TZ_IDENTIFIER=<identifier>, UTC_OFFSET_SECONDS=<integer>, and LOCALE=<identifier> on separate lines.", ["TODAY=\(today)", "TZ_IDENTIFIER=\(zone.identifier)", "UTC_OFFSET_SECONDS=\(offset)", "LOCALE=\(Locale.current.identifier)"], 800),
            ("storage", "Check the total capacity of the filesystem volume containing my home folder in exact bytes. Do not modify anything. End with TOTAL_BYTES=<integer>.", ["TOTAL_BYTES=\(capacity)"], 1040)
        ]
        for scenario in scenarios {
            let resultURL = directory.appending(path: "\(scenario.name)-\(UUID().uuidString).json")
            let app = XCUIApplication()
            app.launchEnvironment = [
                "PRIVATEAI_RUN_APP_ACCEPTANCE": "1",
                "PRIVATEAI_ACCEPTANCE_TRACE": "1",
                "PRIVATEAI_ACCEPTANCE_KEEP_OPEN": "1",
                "PRIVATEAI_ACCEPTANCE_RESULT": resultURL.path,
                "PRIVATEAI_ACCEPTANCE_PROMPT": scenario.prompt,
                "PRIVATEAI_ACCEPTANCE_TIMEOUT_SECONDS": "300",
                "PRIVATEAI_ACCEPTANCE_WINDOW_WIDTH": String(scenario.width)
            ]
            app.launch()
            defer { app.terminate() }
            let rate = app.staticTexts["generation.tokenRate"]
            let firstAnswer = app.staticTexts["generation.firstAnswer"]
            let thinking = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard rate.exists, firstAnswer.exists else { return false }
                let rateText = rate.value as? String ?? rate.label
                let answerText = firstAnswer.value as? String ?? firstAnswer.label
                return rateText.hasPrefix("~") && !rateText.hasPrefix("~0.0") && answerText == "Pending"
            }, object: nil)
            let thinkingResult = XCTWaiter.wait(for: [thinking], timeout: 180)
            XCTAssertEqual(thinkingResult, .completed, "rate=\(rate.debugDescription) answer=\(firstAnswer.debugDescription) result=\(resultURL.path) app=\(app.debugDescription)")
            try app.screenshot().pngRepresentation.write(to: directory.appending(path: "\(scenario.name)-thinking.png"))
            let thinkingSnapshot = XCTAttachment(screenshot: app.screenshot())
            thinkingSnapshot.name = "\(scenario.name)-thinking"
            thinkingSnapshot.lifetime = .keepAlways
            add(thinkingSnapshot)

            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: resultURL),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return ["completed", "failed"].contains(result["status"] as? String ?? "")
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 300), .completed)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
            XCTAssertEqual(result["status"] as? String, "completed", String(describing: result["error"]))
            XCTAssertEqual(result["thinking_rate_observed"] as? Bool, true)
            let visual = try XCTUnwrap(result["visual_trace"] as? [String: Any])
            XCTAssertEqual(visual["rawMatches"] as? Bool, true)
            XCTAssertEqual(visual["overflow"] as? Bool, false)
            let answer = try XCTUnwrap(visual["answer"] as? String)
            for expected in scenario.expected { XCTAssertTrue(answer.contains(expected), answer) }
            let observation = try XCTUnwrap(visual["observation"] as? [String: Int])
            XCTAssertGreaterThan(observation["thinkingVisibleUpdates"] ?? 0, 1)
            XCTAssertGreaterThan(observation["answerUpdates"] ?? 0, 1)
            let rateText = rate.value as? String ?? rate.label
            XCTAssertFalse(rateText.hasPrefix("~"))
            XCTAssertTrue(rateText.contains("tok/s"), rate.debugDescription)
            let records = try XCTUnwrap(result["trace_messages"] as? [[String: String]])
            if scenario.name == "date" {
                XCTAssertFalse(records.contains { $0["role"] == "toolCall" })
                let requests = records.filter { $0["role"] == "modelInput" && ($0["metadata"] ?? "").contains("Conversation round") }
                XCTAssertEqual(requests.count, 1)
                XCTAssertTrue(requests[0]["content"]?.contains(today) == true)
            }
            if scenario.name == "storage" {
                let roles = try XCTUnwrap(visual["roles"] as? [String])
                for role in ["user", "modelInput", "thinking", "toolCall", "toolResult", "assistant"] {
                    XCTAssertTrue(roles.contains(role), roles.description)
                }
                let output = try XCTUnwrap(records.first { $0["role"] == "toolResult" }?["content"])
                let nextInput = try XCTUnwrap(records.last { $0["role"] == "modelInput" }?["content"])
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(nextInput.utf8)) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertTrue(messages.contains { $0["role"] as? String == "tool" && $0["content"] as? String == output })
                let inputs = records.filter { $0["role"] == "modelInput" && ($0["metadata"] ?? "").contains("Conversation round") }
                let contexts = try inputs.map { record -> String in
                    let raw = try XCTUnwrap(record["content"])
                    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                    let history = try XCTUnwrap(request["messages"] as? [[String: Any]])
                    let prompt = try XCTUnwrap(history.last { $0["role"] as? String == "user" }?["content"] as? String)
                    let parts = prompt.components(separatedBy: "Current device context")
                    XCTAssertEqual(parts.count, 2)
                    return parts.last ?? ""
                }
                XCTAssertGreaterThan(contexts.count, 1)
                XCTAssertEqual(Set(contexts).count, 1)
            }
            try app.screenshot().pngRepresentation.write(to: directory.appending(path: "\(scenario.name)-complete.png"))
            let completedSnapshot = XCTAttachment(screenshot: app.screenshot())
            completedSnapshot.name = "\(scenario.name)-complete"
            completedSnapshot.lifetime = .keepAlways
            add(completedSnapshot)
            print("TRACE_UI_ACCEPTANCE \(scenario.name) result=\(resultURL.path)")
            app.terminate()
        }
    }
}
