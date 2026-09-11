import Foundation
import SwiftData

@MainActor
final class ConversationDatabase {
    private let context: ModelContext

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = true
    }

    func conversations() throws -> [ConversationRecord] {
        var descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        return try context.fetch(descriptor)
    }

    func createConversation(modelName: String) throws -> ConversationRecord {
        let conversation = ConversationRecord(modelName: modelName)
        context.insert(conversation)
        try context.save()
        return conversation
    }

    func appendUserTurn(
        to conversation: ConversationRecord,
        prompt: String,
        attachments: [ImportedArtifact],
        containsLocalDocumentReference: Bool = false
    ) throws -> (user: MessageRecord, assistant: MessageRecord) {
        do {
            let firstSequence = (conversation.messages.map(\.sequence).max() ?? 0) + 1
            let user = MessageRecord(
                sequence: firstSequence,
                role: .user,
                content: prompt,
                status: .complete,
                toolName: containsLocalDocumentReference
                    ? DocumentConversationPolicy.localDocumentReferenceMarker
                    : nil,
                conversation: conversation
            )
            context.insert(user)
            conversation.messages.append(user)

            for (sortOrder, imported) in attachments.enumerated() {
                let blob = try artifactBlob(for: imported)
                let reference = ConversationArtifactRecord(
                    displayName: imported.displayName,
                    sortOrder: sortOrder,
                    message: user,
                    blob: blob
                )
                context.insert(reference)
                user.attachments.append(reference)
                blob.references.append(reference)
            }

            let assistant = MessageRecord(
                sequence: firstSequence + 1,
                role: .assistant,
                content: "",
                status: .streaming,
                conversation: conversation
            )
            context.insert(assistant)
            conversation.messages.append(assistant)
            conversation.updatedAt = .now
            if conversation.title == "New conversation" {
                conversation.title = String(prompt.prefix(48))
            }
            try context.save()
            return (user, assistant)
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    func appendMessage(
        to conversation: ConversationRecord,
        role: PersistedMessageRole,
        content: String,
        status: PersistedMessageStatus,
        toolName: String? = nil
    ) throws -> MessageRecord {
        let sequence = (conversation.messages.map(\.sequence).max() ?? 0) + 1
        let message = MessageRecord(
            sequence: sequence,
            role: role,
            content: content,
            status: status,
            toolName: toolName,
            conversation: conversation
        )
        context.insert(message)
        conversation.messages.append(message)
        conversation.updatedAt = .now
        if role == .user, conversation.title == "New conversation" {
            conversation.title = String(content.prefix(48))
        }
        try context.save()
        return message
    }

    func update(
        _ message: MessageRecord,
        content: String? = nil,
        status: PersistedMessageStatus? = nil,
        errorMessage: String? = nil
    ) throws {
        if let content {
            message.content = content
        }
        if let status {
            message.status = status
        }
        message.errorMessage = errorMessage
        message.conversation?.updatedAt = .now
        try context.save()
    }

    func appendStreamingContent(_ delta: String, to message: MessageRecord) {
        message.content.append(delta)
    }

    func moveToEnd(_ message: MessageRecord) throws {
        guard let conversation = message.conversation else { return }
        message.sequence = (conversation.messages.map(\.sequence).max() ?? 0) + 1
        conversation.updatedAt = .now
        try context.save()
    }

    func delete(_ conversation: ConversationRecord) throws {
        context.delete(conversation)
        try context.save()
    }

    func markInterruptedMessages() throws {
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.statusRawValue == "streaming" }
        )
        for message in try context.fetch(descriptor) {
            message.status = .interrupted
            message.errorMessage = "The previous response was interrupted."
        }
        try context.save()
    }

    func sanitizeLegacyLocalResourceMessages() throws {
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.toolName == "local_resources" && $0.roleRawValue == "tool" }
        )
        var changed = false
        for message in try context.fetch(descriptor) {
            let safeMarker = "Document content was available to the model for this run"
            guard !message.content.contains(safeMarker) else { continue }
            message.content = "Legacy local document Tool details were removed during the privacy upgrade."
            changed = true
        }
        if changed {
            try context.save()
        }
    }

    func referencedArtifactPaths() throws -> Set<String> {
        let references = try context.fetch(FetchDescriptor<ConversationArtifactRecord>())
        return Set(references.compactMap { $0.blob?.relativePath })
    }

    func removeUnreferencedArtifactBlobs() throws {
        let blobs = try context.fetch(FetchDescriptor<ArtifactBlobRecord>())
        for blob in blobs where blob.references.isEmpty {
            context.delete(blob)
        }
        try context.save()
    }

    private func artifactBlob(for imported: ImportedArtifact) throws -> ArtifactBlobRecord {
        let storageKey = imported.storageKey
        var descriptor = FetchDescriptor<ArtifactBlobRecord>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let blob = ArtifactBlobRecord(
            storageKey: imported.storageKey,
            contentHash: imported.contentHash,
            relativePath: imported.relativePath,
            format: imported.format,
            contentTypeIdentifier: imported.contentTypeIdentifier,
            byteCount: imported.byteCount
        )
        context.insert(blob)
        return blob
    }
}