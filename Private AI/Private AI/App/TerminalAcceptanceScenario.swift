import AppKit
import CoreGraphics
import CoreText
import Foundation
import LLMCore
import PrivateAITools

@MainActor
extension ChatCoordinator {
    func runAcceptanceScenarioIfConfigured() async {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["PRIVATEAI_RUN_APP_ACCEPTANCE"] == "1",
              let resultPath = environment["PRIVATEAI_ACCEPTANCE_RESULT"],
              let prompt = environment["PRIVATEAI_ACCEPTANCE_PROMPT"] else {
            return
        }
        let resultURL = URL(fileURLWithPath: resultPath)

        do {
            try writeAcceptanceResult(["status": "starting"], to: resultURL)
            try await waitUntilReady(timeout: .seconds(90))
            try writeAcceptanceResult(["status": "ready"], to: resultURL)
            newConversation()
            let fixtureAttachment = try acceptanceFixtureAttachment(
                environment: environment
            )
            defer {
                if let fixtureAttachment {
                    try? FileManager.default.removeItem(at: fixtureAttachment)
                }
            }
            let attachmentURL = fixtureAttachment ?? environment[
                "PRIVATEAI_ACCEPTANCE_ATTACHMENT_PATH"
            ].map { URL(fileURLWithPath: $0) }
            if let attachmentURL {
                guard importAttachments(from: [attachmentURL]) else {
                    throw AcceptanceScenarioError.attachmentImportRejected
                }
                try await waitUntilAttachmentImportFinishes(timeout: .seconds(30))
                guard pendingAttachments.count == 1 else {
                    throw AcceptanceScenarioError.attachmentImportFailed(
                        attachmentError ?? "The attachment was not imported."
                    )
                }
            }
            let nativeGroundTruth = try await nativeGroundTruthIfRequested(
                environment: environment
            )
            draft = prompt
            guard canSend else {
                throw AcceptanceScenarioError.cannotSend
            }
            try writeAcceptanceResult(["status": "sending"], to: resultURL)
            send()
            let timeoutSeconds = environment["PRIVATEAI_ACCEPTANCE_TIMEOUT_SECONDS"]
                .flatMap(Int.init) ?? 600
            try await waitUntilGenerationFinishes(timeout: .seconds(timeoutSeconds))

            let assistant = try requireLastMessage(role: .assistant)
            let toolMessages = messages.filter { $0.role == .tool }
            try writeAcceptanceResult(
                [
                    "status": "completed",
                    "conversation_id": selectedConversation?.id.uuidString ?? "",
                    "assistant_content": assistant.content,
                    "assistant_status": assistant.status.rawValue,
                    "assistant_error": assistant.errorMessage ?? "",
                    "attachment_count": messages
                        .filter { $0.role == .user }
                        .flatMap(\.attachments)
                        .count,
                    "native_ground_truth": nativeGroundTruth ?? NSNull(),
                    "terminal_activity": terminalActivity.map {
                        [
                            "command": $0.command,
                            "working_directory": $0.workingDirectory,
                            "status": $0.status,
                            "elapsed_seconds": $0.observedElapsedSeconds
                        ] as [String: Any]
                    } ?? NSNull(),
                    "tool_messages": toolMessages.map {
                        [
                            "name": $0.toolName ?? "",
                            "content": $0.content,
                            "status": $0.status.rawValue
                        ]
                    }
                ],
                to: resultURL
            )
        } catch {
            try? writeAcceptanceResult(
                [
                    "status": "failed",
                    "error": error.localizedDescription
                ],
                to: resultURL
            )
        }
        NSApplication.shared.terminate(nil)
        #endif
    }

    #if DEBUG
    private func waitUntilReady(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if ollama.state.isReady, !ollama.selectedModel.isEmpty { return }
            try await clock.sleep(for: .milliseconds(100))
        }
        throw AcceptanceScenarioError.ollamaUnavailable
    }

    private func waitUntilGenerationFinishes(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !isGenerating { return }
            try await clock.sleep(for: .milliseconds(100))
        }
        stop()
        throw AcceptanceScenarioError.generationTimedOut
    }

    private func waitUntilAttachmentImportFinishes(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !isImportingAttachments { return }
            try await clock.sleep(for: .milliseconds(100))
        }
        throw AcceptanceScenarioError.attachmentImportTimedOut
    }

    private func nativeGroundTruthIfRequested(
        environment: [String: String]
    ) async throws -> [String: Any]? {
        guard environment["PRIVATEAI_ACCEPTANCE_NATIVE_GROUND_TRUTH"] == "1" else {
            return nil
        }
        let tool = AppleServicesTool()
        let timeZone = try await tool.execute(arguments: [
            "action": .string("time_zone")
        ])
        let location = try await tool.execute(arguments: [
            "action": .string("current_location")
        ])
        return [
            "time_zone": try JSONSerialization.jsonObject(with: Data(timeZone.utf8)),
            "current_location": try JSONSerialization.jsonObject(with: Data(location.utf8))
        ]
    }

    private func acceptanceFixtureAttachment(
        environment: [String: String]
    ) throws -> URL? {
        guard let fixture = environment["PRIVATEAI_ACCEPTANCE_FIXTURE"] else {
            return nil
        }
        guard fixture == "small_pdf" else {
            throw AcceptanceScenarioError.unknownFixture(fixture)
        }
        let url = FileManager.default.temporaryDirectory.appending(
            path: "privateai-small-pdf-\(UUID().uuidString).pdf"
        )
        try createAcceptancePDF(
            at: url,
            pages: [
                "Page one verification code: ORCHID-42.",
                "Page two verification code: IRIS-73."
            ]
        )
        return url
    }

    private func createAcceptancePDF(at url: URL, pages: [String]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw AcceptanceScenarioError.fixtureCreationFailed
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AcceptanceScenarioError.fixtureCreationFailed
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: attributes
                )),
                context
            )
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func requireLastMessage(role: PersistedMessageRole) throws -> MessageRecord {
        guard let message = messages.last(where: { $0.role == role }) else {
            throw AcceptanceScenarioError.assistantMessageMissing
        }
        return message
    }

    private func writeAcceptanceResult(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
    #endif
}

#if DEBUG
private enum AcceptanceScenarioError: Error, LocalizedError {
    case assistantMessageMissing
    case attachmentImportFailed(String)
    case attachmentImportRejected
    case attachmentImportTimedOut
    case cannotSend
    case generationTimedOut
    case fixtureCreationFailed
    case ollamaUnavailable
    case unknownFixture(String)

    var errorDescription: String? {
        switch self {
        case .assistantMessageMissing:
            "The production conversation has no assistant message."
        case .attachmentImportFailed(let message):
            "The acceptance attachment import failed: \(message)"
        case .attachmentImportRejected:
            "The acceptance attachment import was rejected."
        case .attachmentImportTimedOut:
            "The acceptance attachment import did not finish before the deadline."
        case .cannotSend:
            "The production composer could not start the acceptance request."
        case .generationTimedOut:
            "The production Agent run did not finish before the acceptance deadline."
        case .fixtureCreationFailed:
            "The acceptance PDF fixture could not be created."
        case .ollamaUnavailable:
            "Ollama did not become ready before the acceptance deadline."
        case .unknownFixture(let fixture):
            "Unknown acceptance fixture: \(fixture)."
        }
    }
}
#endif