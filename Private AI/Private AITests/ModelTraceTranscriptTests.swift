import Foundation
import LLMCore
import SwiftData
import Testing
@testable import Private_AI

@MainActor
@Suite("Model Trace Transcript")
struct ModelTraceTranscriptTests {
    @Test("persists exact raw input with per-request timing without feeding it back")
    func rawInputPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ConversationStore.makeContainer(
            stateDirectory: directory, legacyStoreURL: directory.appending(path: "absent.store")
        )
        let database = ConversationDatabase(container: container)
        let transcript = ModelTraceTranscript(database: database)
        let conversation = try database.createConversation(modelName: "fixture")
        let turn = try database.appendUserTurn(to: conversation, prompt: "Question", attachments: [])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        let raw = #"{"messages":[{"role":"system","content":"PRIVATE-RAW"},{"role":"user","content":"Question"}],"tools":[{"function":{"name":"test"}}]}"#
        request.httpBody = Data(raw.utf8)
        let trace = ModelRequestTrace(request: request, purpose: .conversation(round: 1))
        try transcript.consume(.request(trace), in: conversation, before: turn.assistant)
        try transcript.consume(.output(id: trace.id, event: .thinking("Reasoning"), at: trace.createdAt.addingTimeInterval(2)), in: conversation, before: turn.assistant)
        try transcript.consume(.output(id: trace.id, event: .completed(ModelUsage(
            promptTokenCount: 123, promptDurationNanoseconds: 1_000_000_000, outputTokenCount: 10
        )), at: trace.createdAt.addingTimeInterval(3)), in: conversation, before: turn.assistant)
        try database.update(turn.assistant, content: "Answer", status: .complete)
        let reopened = ConversationDatabase(container: container)
        let restored = try #require(reopened.conversations().first)
        let input = try #require(restored.messages.first { $0.role == .modelInput })
        #expect(input.content == raw)
        #expect(input.status == .complete)
        #expect(input.toolName?.contains("Request TTFT 2.00s") == true)
        #expect(input.toolName?.contains("Input 123 tokens") == true)
        #expect(input.sequence < turn.assistant.sequence)
        let history = ChatCoordinator.modelHistory(for: restored)
        #expect(history.map(\.content) == ["Question", "Answer"])
        #expect(!history.contains { $0.content.contains("PRIVATE-RAW") })
    }

    @Test("retains auxiliary thinking and output and finalizes interrupted requests")
    func auxiliaryAndInterruption() throws {
        let schema = Schema(versionedSchema: PrivateAISchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let database = ConversationDatabase(container: container)
        let transcript = ModelTraceTranscript(database: database)
        let conversation = try database.createConversation(modelName: "fixture")
        let turn = try database.appendUserTurn(to: conversation, prompt: "Question", attachments: [])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpBody = Data("{}".utf8)
        let trace = ModelRequestTrace(request: request, purpose: .auxiliary)
        try transcript.consume(.request(trace), in: conversation, before: turn.assistant)
        try transcript.consume(.output(id: trace.id, event: .thinking("Partial reasoning"), at: Date()), in: conversation, before: turn.assistant)
        try transcript.consume(.output(id: trace.id, event: .text("Partial summary"), at: Date()), in: conversation, before: turn.assistant)
        try transcript.finish(in: conversation, status: .interrupted)
        let records = conversation.messages.filter { $0.role != .user && $0.role != .assistant }
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0.status == .interrupted })
        #expect(records.contains { $0.content == "Partial reasoning" })
        #expect(records.contains { $0.content == "Partial summary" })
        #expect(ChatCoordinator.modelHistory(for: conversation).count == 1)
    }
}