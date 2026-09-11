import Foundation
import SwiftData

enum ConversationStore {
    static let managedStoreName = "conversations.store"

    static func makeContainer(
        stateDirectory: URL,
        legacyStoreURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PrivateAISchemaV2.self)
        let managedStoreURL = stateDirectory.appending(path: managedStoreName)

        if fileManager.fileExists(atPath: managedStoreURL.path) {
            return try makeContainer(schema: schema, storeURL: managedStoreURL)
        }

        let resolvedLegacyStoreURL = legacyStoreURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appending(path: "default.store")
        if let resolvedLegacyStoreURL,
           fileManager.fileExists(atPath: resolvedLegacyStoreURL.path),
           let legacyContainer = try? makeContainer(
               schema: schema,
               storeURL: resolvedLegacyStoreURL
           ) {
            return legacyContainer
        }

        return try makeContainer(schema: schema, storeURL: managedStoreURL)
    }

    private static func makeContainer(
        schema: Schema,
        storeURL: URL
    ) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(
            for: schema,
            migrationPlan: PrivateAISchemaMigrationPlan.self,
            configurations: configuration
        )
    }
}
