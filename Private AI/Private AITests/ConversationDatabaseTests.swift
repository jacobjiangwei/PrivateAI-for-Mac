import Foundation
import LLMCore
import PrivateAITools
import SwiftData
import Testing
@testable import Private_AI

@MainActor
@Suite("Conversation Database")
struct ConversationDatabaseTests {
    @Test("persists ordered messages and derives the initial title")
    func orderedMessages() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")

        let user = try database.appendMessage(
            to: conversation,
            role: .user,
            content: "Explain the local model architecture",
            status: .complete
        )
        let assistant = try database.appendMessage(
            to: conversation,
            role: .assistant,
            content: "Architecture result",
            status: .complete
        )

        #expect(user.sequence == 1)
        #expect(assistant.sequence == 2)
        #expect(conversation.title == "Explain the local model architecture")
        #expect(try database.conversations().first?.messages.count == 2)
    }

    @Test("marks unfinished assistant messages as interrupted")
    func interruptionRecovery() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")
        let assistant = try database.appendMessage(
            to: conversation,
            role: .assistant,
            content: "Partial response",
            status: .streaming
        )

        try database.markInterruptedMessages()

        #expect(assistant.status == .interrupted)
        #expect(assistant.errorMessage == "The previous response was interrupted.")
    }

    @Test("orders tool events before the final assistant response")
    func orderedToolTranscript() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")
        _ = try database.appendMessage(
            to: conversation,
            role: .user,
            content: "Complete the task",
            status: .complete
        )
        let assistant = try database.appendMessage(
            to: conversation,
            role: .assistant,
            content: "",
            status: .streaming
        )
        let firstTool = try database.appendMessage(
            to: conversation,
            role: .tool,
            content: "First tool",
            status: .streaming,
            toolName: "first"
        )
        try database.moveToEnd(assistant)
        let secondTool = try database.appendMessage(
            to: conversation,
            role: .tool,
            content: "Second tool",
            status: .streaming,
            toolName: "second"
        )
        try database.moveToEnd(assistant)

        let ordered = conversation.messages.sorted { $0.sequence < $1.sequence }
        #expect(ordered.map(\.role) == [.user, .tool, .tool, .assistant])
        #expect(ordered[1].id == firstTool.id)
        #expect(ordered[2].id == secondTool.id)
        #expect(ordered[3].id == assistant.id)
    }

    @Test("persists an attached user turn atomically and reuses artifact blobs")
    func attachedUserTurn() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")
        let imported = ImportedArtifact(
            displayName: "Report.md",
            storageKey: "abc.md",
            contentHash: "abc",
            relativePath: "blobs/ab/abc/content.md",
            format: .markdown,
            contentTypeIdentifier: "net.daringfireball.markdown",
            byteCount: 42
        )

        let first = try database.appendUserTurn(
            to: conversation,
            prompt: "Summarize this",
            attachments: [imported]
        )
        let second = try database.appendUserTurn(
            to: conversation,
            prompt: "Check it again",
            attachments: [imported]
        )

        #expect(first.user.content == "Summarize this")
        #expect(first.user.attachments.count == 1)
        #expect(first.user.attachments.first?.displayName == "Report.md")
        #expect(first.user.attachments.first?.sortOrder == 0)
        #expect(first.user.attachments.first?.blob?.relativePath == imported.relativePath)
        #expect(first.assistant.sequence == first.user.sequence + 1)
        #expect(first.assistant.status == .streaming)
        #expect(second.user.attachments.first?.blob === first.user.attachments.first?.blob)

        let modelContent = AttachmentModelContentBuilder.content(for: first.user)
        #expect(modelContent.contains("privateai.document_attachments"))
        #expect(modelContent.contains("blobs/ab/abc/content.md"))
        #expect(modelContent.contains("Summarize this"))
        #expect(!modelContent.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("persists local document privacy provenance on the user turn")
    func localDocumentReference() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")

        let turn = try database.appendUserTurn(
            to: conversation,
            prompt: "/tmp/document.txt summarize",
            attachments: [],
            containsLocalDocumentReference: true
        )

        #expect(turn.user.toolName == DocumentConversationPolicy.localDocumentReferenceMarker)
        #expect(DocumentConversationPolicy.hasDocumentToolHistory(
            toolNames: conversation.messages.compactMap(\.toolName)
        ))
    }

    @Test("local document tool transcript omits document paths, queries, and content")
    func privateDocumentToolTranscript() {
        let sentinel = "PRIVATE-DOCUMENT-SENTINEL"
        let arguments: [String: JSONValue] = [
            "action": .string("search"),
            "path": .string("/Users/private/report.pdf"),
            "query": .string(sentinel)
        ]
        let started = ToolTranscriptContent.started(
            name: "local_resources",
            arguments: arguments
        )
        let finished = ToolTranscriptContent.finished(ToolExecution(
            name: "local_resources",
            arguments: arguments,
            content: "{\"text\":\"\(sentinel)\"}",
            succeeded: true
        ))

        #expect(started.contains("search"))
        #expect(!started.contains("/Users/private"))
        #expect(!started.contains(sentinel))
        #expect(!finished.contains("/Users/private"))
        #expect(!finished.contains(sentinel))

        let invalid = ToolTranscriptContent.started(
            name: "local_resources",
            arguments: ["action": .string(sentinel)]
        )
        #expect(!invalid.contains(sentinel))

        let forgedArguments = ["query": JSONValue.string(sentinel)]
        let forgedStarted = ToolTranscriptContent.started(
            name: "web",
            arguments: forgedArguments,
            documentPrivacyMode: true
        )
        let forgedFinished = ToolTranscriptContent.finished(ToolExecution(
            name: "web",
            arguments: forgedArguments,
            content: sentinel,
            succeeded: false
        ), documentPrivacyMode: true)
        #expect(!forgedStarted.contains(sentinel))
        #expect(!forgedFinished.contains(sentinel))
    }

    @Test("browser transcript omits queries typed text and URL details")
    func browserTranscriptPrivacy() {
        let execution = ToolExecution(
            name: "browser",
            arguments: [
                "action": .string("type"),
                "session_id": .string("session"),
                "frame_id": .string("frame"),
                "x": .number(20),
                "y": .number(30),
                "text": .string("private search phrase")
            ],
            content: #"{"status":"ready","validated_origin":"https://example.com","page_url":"https://example.com/search?q=private","page_title":"private search phrase","frame_id":"frame","image_width":1280,"image_height":800}"#,
            succeeded: true,
            images: [ModelImage(data: Data([1, 2, 3]), width: 1_280, height: 800)]
        )

        let transcript = ToolTranscriptContent.finished(execution)

        #expect(transcript.contains("private search phrase") == false)
        #expect(transcript.contains("/search?q=") == false)
        #expect(transcript.contains("https://example.com") == true)
        #expect(transcript.contains("frame_id") == true)
        #expect(transcript.contains("screenshot was available") == true)
    }

    @Test("deleting a conversation leaves its artifact blob eligible for cleanup")
    func deletionReleasesBlobReference() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")
        let imported = ImportedArtifact(
            displayName: "notes.txt",
            storageKey: "delete.txt",
            contentHash: "delete",
            relativePath: "blobs/de/delete/content.txt",
            format: .plainText,
            contentTypeIdentifier: "public.plain-text",
            byteCount: 12
        )
        _ = try database.appendUserTurn(
            to: conversation,
            prompt: "Read it",
            attachments: [imported]
        )

        try database.delete(conversation)
        try database.removeUnreferencedArtifactBlobs()

        #expect(try database.referencedArtifactPaths().isEmpty)
    }

    private func makeDatabase() throws -> ConversationDatabase {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ConversationRecord.self,
            MessageRecord.self,
            ArtifactBlobRecord.self,
            ConversationArtifactRecord.self,
            configurations: configuration
        )
        return ConversationDatabase(container: container)
    }
}