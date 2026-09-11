import AppKit
import CoreGraphics
import CoreText
import Foundation
import LLMCore
import PrivateAITools
import WebKit

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
            if environment["PRIVATEAI_ACCEPTANCE_TRACE"] == "1" {
                try await installTranscriptObservation()
            }
            try writeAcceptanceResult(["status": "sending"], to: resultURL)
            send()
            let timeoutSeconds = environment["PRIVATEAI_ACCEPTANCE_TIMEOUT_SECONDS"]
                .flatMap(Int.init) ?? 600
            let thinkingRateObserved = try await waitUntilGenerationFinishes(timeout: .seconds(timeoutSeconds))

            let assistant = try requireLastMessage(role: .assistant)
            let toolMessages = messages.filter { $0.role == .tool || $0.role == .toolResult }
            let visualTrace: [String: Any]
            if environment["PRIVATEAI_ACCEPTANCE_TRACE"] == "1" {
                visualTrace = try await inspectTranscript(assistant: assistant)
                try writeWindowSnapshot(beside: resultURL)
            } else {
                visualTrace = [:]
            }
            try writeAcceptanceResult(
                [
                    "status": "completed",
                    "conversation_id": selectedConversation?.id.uuidString ?? "",
                    "assistant_content": assistant.content,
                    "assistant_status": assistant.status.rawValue,
                    "assistant_error": assistant.errorMessage ?? "",
                    "thinking_rate_observed": thinkingRateObserved,
                    "visual_trace": visualTrace,
                    "metrics": [
                        "received_chunks": generationMetrics.receivedChunkCount,
                        "thinking_characters": generationMetrics.thinkingCharacterCount,
                        "output_tokens": generationMetrics.outputTokenCount,
                        "input_tokens": generationMetrics.promptTokenCount,
                        "request_count": generationMetrics.requestCount,
                        "request_bytes": generationMetrics.requestBytes,
                        "tool_schema_bytes": generationMetrics.toolSchemaBytes,
                        "ttft_seconds": generationMetrics.ttftSeconds ?? -1,
                        "first_answer_seconds": generationMetrics.firstAnswerSeconds ?? -1,
                        "final_tokens_per_second": generationMetrics.finalTokensPerSecond ?? -1
                    ],
                    "trace_messages": environment["PRIVATEAI_ACCEPTANCE_TRACE"] == "1" ? messages.map {
                        ["role": $0.role.rawValue, "content": $0.content, "status": $0.status.rawValue, "metadata": $0.toolName ?? ""]
                    } : [],
                    "attachment_count": messages
                        .filter { $0.role == .user }
                        .flatMap(\.attachments)
                        .count,
                    "native_ground_truth": nativeGroundTruth ?? NSNull(),
                    "browser_activity": [
                        "title": browser.title,
                        "origin": browser.origin,
                        "page_url": browser.latestPageURL,
                        "frame_id": browser.latestFrameID?.uuidString ?? ""
                    ],
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
        if environment["PRIVATEAI_ACCEPTANCE_KEEP_OPEN"] != "1" {
            NSApplication.shared.terminate(nil)
        }
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

    private func waitUntilGenerationFinishes(timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var thinkingRateObserved = false
        while clock.now < deadline {
            if generationMetrics.firstAnswerSeconds == nil,
               generationMetrics.thinkingCharacterCount > 0,
               (generationMetrics.estimatedTokensPerSecond(at: Date()) ?? 0) > 0 {
                thinkingRateObserved = true
            }
            if !isGenerating { return thinkingRateObserved }
            try await clock.sleep(for: .milliseconds(100))
        }
        stop()
        throw AcceptanceScenarioError.generationTimedOut
    }

    private func installTranscriptObservation() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let webView = TranscriptWebView.acceptanceWebView, !webView.isLoading {
                if let width = ProcessInfo.processInfo.environment["PRIVATEAI_ACCEPTANCE_WINDOW_WIDTH"].flatMap(Double.init) {
                    webView.window?.setContentSize(NSSize(width: max(760, width), height: 820))
                }
                _ = try await webView.callAsyncJavaScript(
                    """
                    window.traceObservation = {thinkingUpdates: 0, answerUpdates: 0, thinkingVisibleUpdates: 0};
                    const lengths = new Map();
                    let frame = 0;
                    const observer = new MutationObserver(() => {
                      if (frame) return;
                      frame = requestAnimationFrame(() => {
                        frame = 0;
                        for (const article of document.querySelectorAll('article.thinking, article.assistant')) {
                          const content = article.querySelector('.content.streaming');
                          if (!content || content.classList.contains('waiting')) continue;
                          const length = content.textContent.length;
                          if (length <= (lengths.get(article.id) || 0)) continue;
                          lengths.set(article.id, length);
                          if (article.classList.contains('thinking')) {
                            traceObservation.thinkingUpdates++;
                            const rect = content.getBoundingClientRect();
                            if (rect.bottom > 0 && rect.top < innerHeight) traceObservation.thinkingVisibleUpdates++;
                          } else { traceObservation.answerUpdates++; }
                        }
                      });
                    });
                    observer.observe(document.getElementById('messages'), {childList: true, subtree: true, characterData: true});
                    """,
                    arguments: [:], in: nil, contentWorld: .page
                )
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AcceptanceScenarioError.transcriptUnavailable
    }

    private func inspectTranscript(assistant: MessageRecord) async throws -> [String: Any] {
        guard let webView = TranscriptWebView.acceptanceWebView else {
            throw AcceptanceScenarioError.transcriptUnavailable
        }
        let rawMessages = messages.filter { $0.role == .modelInput || $0.role == .toolCall || $0.role == .toolResult }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let result = try await webView.callAsyncJavaScript(
                """
                const complete = !document.querySelector('article.assistant .content.streaming');
                                const rawMatches = raw.every(message => {
                                    const article = document.getElementById('message-' + message.id);
                                    return article?.renderedMessage.content === message.content
                                        && article?.querySelector('pre')?.textContent === rawDisplayText(message);
                                });
                                const inputs = Array.from(document.querySelectorAll('article.modelInput'));
                                const formattedInputs = inputs.filter(article => {
                                    try {
                                        return article.querySelector('pre')?.textContent === JSON.stringify(JSON.parse(article.renderedMessage.content), null, 2)
                                            && article.querySelectorAll('details').length === 1;
                                    } catch { return false; }
                                }).length;
                const answer = document.getElementById('message-' + assistantID)?.querySelector('.content')?.textContent || '';
                                return {complete, rawMatches, answer, formattedInputs, inputCount: inputs.length, observation: window.traceObservation || {},
                  roles: Array.from(document.querySelectorAll('article'), article => article.className),
                  overflow: document.documentElement.scrollWidth > innerWidth};
                """,
                arguments: [
                    "raw": rawMessages.map { ["id": $0.id.uuidString, "role": $0.role.rawValue, "content": $0.content] },
                    "assistantID": assistant.id.uuidString
                ], in: nil, contentWorld: .page
            )
            if let values = result as? [String: Any], values["complete"] as? Bool == true,
               values["rawMatches"] as? Bool == true, !(values["answer"] as? String ?? "").isEmpty {
                return values
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AcceptanceScenarioError.transcriptUnavailable
    }

    private func writeWindowSnapshot(beside result: URL) throws {
        guard let view = TranscriptWebView.acceptanceWebView?.window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AcceptanceScenarioError.transcriptUnavailable
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AcceptanceScenarioError.transcriptUnavailable
        }
        try data.write(to: result.deletingPathExtension().appendingPathExtension("png"))
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
    case transcriptUnavailable
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
        case .transcriptUnavailable:
            "The production transcript was not rendered before the deadline."
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