import Foundation
import SwiftData
import Testing
@testable import Private_AI

@MainActor
@Suite("Conversation Store", .serialized)
struct ConversationStoreTests {
    @Test("creates new conversations in the managed state directory")
    func newStoreUsesManagedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let container = try ConversationStore.makeContainer(
            stateDirectory: fixture.stateDirectory,
            legacyStoreURL: fixture.legacyStoreURL
        )
        try insertConversation(title: "Managed", into: container)

        #expect(FileManager.default.fileExists(atPath: fixture.managedStoreURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.legacyStoreURL.path))
    }

    @Test("ignores an incompatible legacy default store")
    func incompatibleLegacyStoreUsesManagedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try seedForeignStore(at: fixture.legacyStoreURL)

        let container = try ConversationStore.makeContainer(
            stateDirectory: fixture.stateDirectory,
            legacyStoreURL: fixture.legacyStoreURL
        )
        try insertConversation(title: "Recovered", into: container)

        #expect(FileManager.default.fileExists(atPath: fixture.managedStoreURL.path))
        #expect(try foreignValues(at: fixture.legacyStoreURL) == ["unrelated"])
    }

    @Test("continues using a compatible legacy store")
    func compatibleLegacyStorePreservesConversations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try seedLegacyConversation(title: "Existing", at: fixture.legacyStoreURL)

        let container = try ConversationStore.makeContainer(
            stateDirectory: fixture.stateDirectory,
            legacyStoreURL: fixture.legacyStoreURL
        )
        let conversations = try ModelContext(container).fetch(
            FetchDescriptor<ConversationRecord>()
        )

        #expect(conversations.map(\.title) == ["Existing"])
        #expect(!FileManager.default.fileExists(atPath: fixture.managedStoreURL.path))
    }

    private func insertConversation(title: String, into container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(ConversationRecord(title: title))
        try context.save()
    }

    private func seedLegacyConversation(title: String, at storeURL: URL) throws {
        let schema = Schema(versionedSchema: PrivateAISchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PrivateAISchemaMigrationPlan.self,
            configurations: configuration
        )
        try insertConversation(title: title, into: container)
    }

    private func seedForeignStore(at storeURL: URL) throws {
        let schema = Schema([ForeignStoreRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.insert(ForeignStoreRecord(value: "unrelated"))
        try context.save()
    }

    private func foreignValues(at storeURL: URL) throws -> [String] {
        let schema = Schema([ForeignStoreRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return try ModelContext(container).fetch(FetchDescriptor<ForeignStoreRecord>())
            .map(\.value)
    }
}

@Model
private final class ForeignStoreRecord {
    @Attribute(.unique) var id: UUID
    var value: String

    init(id: UUID = UUID(), value: String) {
        self.id = id
        self.value = value
    }
}

private struct Fixture {
    let root: URL
    let stateDirectory: URL
    let legacyStoreURL: URL

    var managedStoreURL: URL {
        stateDirectory.appending(path: ConversationStore.managedStoreName)
    }

    init(fileManager: FileManager = .default) throws {
        root = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        stateDirectory = root.appending(path: "state", directoryHint: .isDirectory)
        legacyStoreURL = root.appending(path: "default.store")
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }
}
