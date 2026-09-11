import Foundation
import SwiftData

enum PersistedMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case thinking
    case tool
    case modelInput
    case toolCall
    case toolResult
    case modelOutput
}

enum PersistedMessageStatus: String, Codable, Sendable {
    case complete
    case streaming
    case failed
    case interrupted
}

@Model
final class MessageRecord {
    @Attribute(.unique) var id: UUID
    var sequence: Int64
    var roleRawValue: String
    var content: String
    var statusRawValue: String
    var createdAt: Date
    var errorMessage: String?
    var toolName: String?
    var conversation: ConversationRecord?
    @Relationship(deleteRule: .cascade, inverse: \ConversationArtifactRecord.message)
    var attachments: [ConversationArtifactRecord]

    var role: PersistedMessageRole {
        get { PersistedMessageRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    var status: PersistedMessageStatus {
        get { PersistedMessageStatus(rawValue: statusRawValue) ?? .complete }
        set { statusRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        sequence: Int64,
        role: PersistedMessageRole,
        content: String,
        status: PersistedMessageStatus,
        createdAt: Date = .now,
        errorMessage: String? = nil,
        toolName: String? = nil,
        conversation: ConversationRecord? = nil,
        attachments: [ConversationArtifactRecord] = []
    ) {
        self.id = id
        self.sequence = sequence
        self.roleRawValue = role.rawValue
        self.content = content
        self.statusRawValue = status.rawValue
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.toolName = toolName
        self.conversation = conversation
        self.attachments = attachments
    }
}