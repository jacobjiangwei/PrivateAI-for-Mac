import Foundation
import PrivateAITools
import SwiftData

@MainActor
final class AppDependencies {
    let container: ModelContainer
    let database: ConversationDatabase
    let ollama: OllamaServiceController
    let agent: ChatAgent
    let runtimeDirectory: ManagedRuntimeDirectory
    let runtimeLog: RuntimeLog
    let artifactStore: ManagedArtifactStore
    let terminalBackend: TerminalExecutionBackend?
    let browser: BrowserCoordinator
    let initialExecutionWorkspace: URL?

    init() throws {
        runtimeDirectory = try ManagedRuntimeDirectory()
        try RuntimeLog.preparePrivacyMigration(
            logsDirectory: runtimeDirectory.logs,
            stateDirectory: runtimeDirectory.state
        )
        runtimeLog = try RuntimeLog(directory: runtimeDirectory)
        artifactStore = try ManagedArtifactStore(root: runtimeDirectory.artifacts)
        browser = BrowserCoordinator(framesDirectory: runtimeDirectory.browserFrames)
        let resolvedTerminalBackend: TerminalExecutionBackend?
        if let workerExecutable = Self.executionWorkerURL() {
            resolvedTerminalBackend = TerminalExecutionBackend(
                workerExecutableURL: workerExecutable,
                logsDirectory: runtimeDirectory.logs.appending(
                    path: "execution",
                    directoryHint: .isDirectory
                )
            )
        } else {
            resolvedTerminalBackend = nil
        }
        terminalBackend = resolvedTerminalBackend
        #if DEBUG
        initialExecutionWorkspace = resolvedTerminalBackend == nil
            ? nil
            : ExecutionWorkspaceBootstrap.workspace(
                environment: ProcessInfo.processInfo.environment
            ) ?? runtimeDirectory.defaultWorkspace
        #else
        initialExecutionWorkspace = resolvedTerminalBackend == nil
            ? nil
            : runtimeDirectory.defaultWorkspace
        #endif
        let schema = Schema(versionedSchema: PrivateAISchemaV2.self)
        container = try ModelContainer(
            for: schema,
            migrationPlan: PrivateAISchemaMigrationPlan.self
        )
        database = ConversationDatabase(container: container)
        ollama = OllamaServiceController(log: runtimeLog)
        agent = try ChatAgent(
            log: runtimeLog,
            localResourcesRoot: runtimeDirectory.artifacts,
            jobsRoot: runtimeDirectory.jobs,
            terminalBackend: terminalBackend,
            browserBackend: browser,
            defaultExecutionWorkspace: initialExecutionWorkspace
        )
        try database.sanitizeLegacyLocalResourceMessages()
        try database.markInterruptedMessages()
        Task {
            await runtimeLog.record("app.initialized", fields: [
                "managed_root": runtimeDirectory.root.path
            ])
            do {
                let referencedPaths = try database.referencedArtifactPaths()
                let result = try await artifactStore.reconcile(
                    referencedRelativePaths: referencedPaths
                )
                try database.removeUnreferencedArtifactBlobs()
                await runtimeLog.record("artifacts.reconciled", fields: [
                    "missing_references": String(result.missingReferencedPaths.count),
                    "removed_orphans": String(result.removedOrphanFiles),
                    "removed_staging": String(result.removedStagingFiles)
                ])
            } catch {
                await runtimeLog.record("artifacts.reconciliation_failed", fields: [
                    "error": String(describing: error)
                ])
            }
        }
    }

    private static func executionWorkerURL() -> URL? {
        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        else {
            return nil
        }
        let worker = executableDirectory.appending(path: "PrivateAIExecutionWorker")
        return FileManager.default.isExecutableFile(atPath: worker.path) ? worker : nil
    }

}

nonisolated enum ExecutionWorkspaceBootstrap {
    static func workspace(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        guard environment["PRIVATEAI_RUN_TERMINAL_APP_ACCEPTANCE"] == "1",
              let path = environment["PRIVATEAI_EXECUTION_WORKSPACE"] else {
            return nil
        }
        let workspace = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard workspace.path != "/",
              fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return workspace
    }
}