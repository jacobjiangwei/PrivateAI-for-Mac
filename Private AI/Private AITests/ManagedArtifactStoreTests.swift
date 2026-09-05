import CoreGraphics
import CoreText
import Foundation
import LLMCore
import PrivateAITools
import SwiftData
import Testing
@testable import Private_AI

@Suite("Managed Artifact Store", .serialized)
struct ManagedArtifactStoreTests {
    @Test("imports, deduplicates, and reads a managed document after source removal")
    func managedCopy() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifactRoot = fixtureRoot.appending(path: "artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appending(path: "source.txt")
        try Data("abc".utf8).write(to: source)
        let store = try ManagedArtifactStore(root: artifactRoot)

        let first = try await store.importFile(from: source)
        let second = try await store.importFile(from: source)

        #expect(first.contentHash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(first.relativePath == second.relativePath)
        #expect(first.byteCount == 3)
        try FileManager.default.removeItem(at: source)

        let managedURL = try await store.resolve(relativePath: first.relativePath)
        let tool = LocalResourcesTool(access: .restricted([artifactRoot]))
        let output = try await tool.execute(arguments: [
            "action": .string("read"),
            "path": .string(managedURL.path)
        ])
        #expect(output.contains("abc"))
    }

    @Test("imports a PDF and exposes its real text layer through PDFKit")
    func managedPDF() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifactRoot = fixtureRoot.appending(path: "artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appending(path: "ground-truth.pdf")
        try createTextPDF(at: source, text: "PrivateAI attachment verdict: IRIS-73")
        let store = try ManagedArtifactStore(root: artifactRoot)

        let imported = try await store.importFile(from: source)
        let managedURL = try await store.resolve(relativePath: imported.relativePath)
        let tool = LocalResourcesTool(access: .restricted([artifactRoot]))
        let output = try await tool.execute(arguments: [
            "action": .string("read"),
            "path": .string(managedURL.path),
            "page_start": .number(1),
            "page_end": .number(1)
        ])

        #expect(imported.format == .pdf)
        #expect(output.contains("IRIS-73"))
    }

    @Test(
        "model reads an imported PDF and uses its ground truth in the final answer",
        .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
    )
    @MainActor
    func managedAttachmentThroughAgent() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifactRoot = fixtureRoot.appending(path: "artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appending(path: "agent-ground-truth.pdf")
        let factCodes = ["IRIS-73", "JADE-91"]
        try createTextPDF(at: source, pages: [
            "Page one verdict code: IRIS-73. Preserve it exactly in the whole-document summary.",
            "Page two verdict code: JADE-91. Preserve it exactly in the whole-document summary."
        ])
        let store = try ManagedArtifactStore(root: artifactRoot)
        let imported = try await store.importFile(from: source)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ConversationRecord.self,
            MessageRecord.self,
            ArtifactBlobRecord.self,
            ConversationArtifactRecord.self,
            configurations: configuration
        )
        let database = ConversationDatabase(container: container)
        let conversation = try database.createConversation(modelName: "qwen3.8:latest")
        let turn = try database.appendUserTurn(
            to: conversation,
            prompt: "Summarize the entire attached PDF and list the exact verdict code from every page.",
            attachments: [imported]
        )
        let prompt = AttachmentModelContentBuilder.content(for: turn.user)
        let jobsRoot = fixtureRoot.appending(path: "jobs", directoryHint: .isDirectory)
        let log = try RuntimeLog(fileURL: fixtureRoot.appending(path: "app.jsonl"))
        let agent = try ChatAgent(
            log: log,
            localResourcesRoot: artifactRoot,
            jobsRoot: jobsRoot
        )
        let recorder = AttachmentEventRecorder()

        let result = try await agent.respond(
            prompt: prompt,
            history: [],
            model: "qwen3.8:latest",
            runID: UUID(),
            conversationID: conversation.id,
            documentPrivacyMode: true
        ) { event in
            await recorder.append(event)
        }
        let events = await recorder.events
        let startedNames = events.compactMap { event -> String? in
            guard case .toolStarted(let name, _) = event else { return nil }
            return name
        }
        let progressDetails = events.compactMap { event -> String? in
            guard case .toolProgress(let name, let detail) = event,
                  name == "document_analysis"
            else {
                return nil
            }
            return detail
        }
        let executions = events.compactMap { event -> ToolExecution? in
            guard case .toolFinished(let execution) = event else { return nil }
            return execution
        }

        #expect(startedNames.contains("document_analysis"))
        #expect(!progressDetails.isEmpty)
        #expect(executions.contains {
            $0.name == "document_analysis"
                && $0.succeeded
                && factCodes.allSatisfy($0.content.contains)
        })
        for code in factCodes {
            #expect(result.text.contains(code))
        }
    }

    @Test("rejects oversized input without leaving a staged file")
    func sizeLimitCleanup() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifactRoot = fixtureRoot.appending(path: "artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let exact = fixtureRoot.appending(path: "exact.txt")
        let source = fixtureRoot.appending(path: "large.txt")
        try Data("123".utf8).write(to: exact)
        try Data("1234".utf8).write(to: source)
        let store = try ManagedArtifactStore(root: artifactRoot, maximumFileBytes: 3)

        let imported = try await store.importFile(from: exact)
        #expect(imported.byteCount == 3)

        await #expect(throws: ManagedArtifactStoreError.fileTooLarge(3)) {
            try await store.importFile(from: source)
        }

        let staging = artifactRoot.appending(path: "staging", directoryHint: .isDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test("reconciles restart debris without deleting current pending imports")
    func reconciliation() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifactRoot = fixtureRoot.appending(path: "artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appending(path: "pending.txt")
        try Data("pending".utf8).write(to: source)
        let firstSession = try ManagedArtifactStore(root: artifactRoot)
        let imported = try await firstSession.importFile(from: source)

        let pendingResult = try await firstSession.reconcile(referencedRelativePaths: [])
        let pendingURL = try await firstSession.resolve(relativePath: imported.relativePath)
        #expect(pendingResult.removedOrphanFiles == 0)
        #expect(FileManager.default.fileExists(atPath: pendingURL.path))

        let stagingFile = artifactRoot.appending(path: "staging/interrupted")
        try Data("partial".utf8).write(to: stagingFile)
        let nextSession = try ManagedArtifactStore(root: artifactRoot)
        let result = try await nextSession.reconcile(
            referencedRelativePaths: ["blobs/ff/missing/content.txt"]
        )

        #expect(result.removedStagingFiles == 1)
        #expect(result.removedOrphanFiles == 1)
        #expect(result.missingReferencedPaths == ["blobs/ff/missing/content.txt"])
        #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
    }

    @Test("released pending imports become eligible for cleanup")
    func releasedLeaseCleanup() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifactRoot = fixtureRoot.appending(path: "artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appending(path: "discarded.txt")
        try Data("discarded".utf8).write(to: source)
        let store = try ManagedArtifactStore(root: artifactRoot)
        let imported = try await store.importFile(from: source)
        let managedURL = try await store.resolve(relativePath: imported.relativePath)

        await store.release([imported])
        let result = try await store.reconcile(referencedRelativePaths: [])

        #expect(result.removedOrphanFiles == 1)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
    }

    @Test("enforces batch and managed path boundaries")
    func boundaries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedArtifactStore(root: root, maximumFilesPerImport: 1)

        await #expect(throws: ManagedArtifactStoreError.tooManyFiles(1)) {
            try await store.importFiles(from: [root.appending(path: "a.txt"), root.appending(path: "b.txt")])
        }
        await #expect(throws: ManagedArtifactStoreError.invalidManagedPath("../outside.txt")) {
            try await store.resolve(relativePath: "../outside.txt")
        }
    }
}

private actor AttachmentEventRecorder {
    private(set) var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        events.append(event)
    }
}

private func createTextPDF(at url: URL, text: String) throws {
    try createTextPDF(at: url, pages: [text])
}

private func createTextPDF(at url: URL, pages: [String]) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for text in pages {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
            context
        )
        context.endPDFPage()
    }
    context.closePDF()
}