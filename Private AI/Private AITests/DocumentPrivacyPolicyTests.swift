import Foundation
import LLMCore
import PrivateAITools
import Testing
@testable import Private_AI

@Suite("Document Privacy Policy")
struct DocumentPrivacyPolicyTests {
    @Test("attachment conversations expose only the local document tool")
    func localOnlyToolCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try RuntimeLog(fileURL: root.appending(path: "app.jsonl"))
        let agent = try ChatAgent(
            log: log,
            localResourcesRoot: root,
            jobsRoot: root.appending(path: "jobs")
        )

        let privateNames = try await agent.availableToolNames(documentPrivacyMode: true)
        let generalNames = try await agent.availableToolNames(documentPrivacyMode: false)

        #expect(privateNames == ["document_analysis", "local_resources"])
        #expect(generalNames == ["apple_services", "web"])
    }

    @Test("managed workspace enables terminal by default outside document privacy mode")
    func terminalCatalogRespectsDocumentPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try RuntimeLog(fileURL: root.appending(path: "app.jsonl"))
        let backend = TerminalExecutionBackend(
            workerExecutableURL: root.appending(path: "unused-worker"),
            logsDirectory: root.appending(path: "execution-logs")
        )
        let agent = try ChatAgent(
            log: log,
            localResourcesRoot: root,
            jobsRoot: root.appending(path: "jobs"),
            terminalBackend: backend,
            defaultExecutionWorkspace: root
        )

        let generalNames = try await agent.availableToolNames(
            documentPrivacyMode: false
        )
        let privateNames = try await agent.availableToolNames(
            documentPrivacyMode: true
        )

        #expect(generalNames == ["apple_services", "terminal", "web"])
        #expect(privateNames == ["document_analysis", "local_resources"])
    }

    @Test("workspace bootstrap requires explicit acceptance mode")
    func workspaceBootstrapIsNotImplicit() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ExecutionWorkspaceBootstrap.workspace(environment: [:]) == nil)
        #expect(ExecutionWorkspaceBootstrap.workspace(environment: [
            "PRIVATEAI_EXECUTION_WORKSPACE": root.path
        ]) == nil)
        #expect(ExecutionWorkspaceBootstrap.workspace(environment: [
            "PRIVATEAI_RUN_TERMINAL_APP_ACCEPTANCE": "1",
            "PRIVATEAI_EXECUTION_WORKSPACE": root.path
        ]) == root.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test("prompt paths authorize only the named local file")
    func promptPathAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appending(path: "Agreement Copy (1).txt")
        let sibling = root.appending(path: "sibling.txt")
        try Data("document".utf8).write(to: document)
        try Data("sibling".utf8).write(to: sibling)
        let files = PromptLocalFileResolver.files(in: "\(document.path) 总结一下啊")
        let tool = LocalResourcesTool(
            access: .restricted(files),
            maximumTextCharacters: 2_000
        )

        #expect(files == [document.standardizedFileURL.resolvingSymlinksInPath()])
        _ = try await tool.execute(arguments: [
            "action": .string("read"),
            "path": .string(document.path)
        ])
        await #expect(throws: LocalResourcesToolError.self) {
            try await tool.execute(arguments: [
                "action": .string("read"),
                "path": .string(sibling.path)
            ])
        }
    }

    @Test("prompt path representations resolve to one canonical file")
    func promptPathRepresentations() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appending(path: "Agreement Copy (1).pdf")
        try Data("document".utf8).write(to: document)
        let canonical = document.standardizedFileURL.resolvingSymlinksInPath()
        let escaped = document.path.reduce(into: "") { result, character in
            if [" ", "(", ")"].contains(character) { result.append("\\") }
            result.append(character)
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath = document.path.hasPrefix(homePath)
            ? "~" + document.path.dropFirst(homePath.count)
            : document.path
        let prompts = [
            document.path + " 总结一下啊",
            "(base) user@Mac ~ % \(escaped)\n\n帮我看看这个文件是啥的",
            "Open '\(document.path)' please",
            document.absoluteString + " summarize",
            tildePath + " summarize"
        ]

        for prompt in prompts {
            #expect(PromptLocalFileResolver.files(in: prompt) == [canonical])
        }
    }

    @Test("path authorization rejects prefixes and ambiguous shell escaping")
    func promptPathAmbiguity() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "private.txt")
        let short = root.appending(path: "report.txt")
        let long = root.appending(path: "report.txt final.pdf")
        let literalBackslash = root.appending(path: "literal\\ file.txt")
        let unescaped = root.appending(path: "literal file.txt")
        try Data("prefix".utf8).write(to: prefix)
        try Data("short".utf8).write(to: short)
        try Data("long".utf8).write(to: long)
        try Data("literal".utf8).write(to: literalBackslash)
        try Data("unescaped".utf8).write(to: unescaped)

        #expect(PromptLocalFileResolver.files(in: prefix.path + "-not-this-file") == [])
        #expect(PromptLocalFileResolver.files(in: prefix.path + ":other") == [])
        #expect(PromptLocalFileResolver.files(in: long.path + " summarize") == [])
        try FileManager.default.removeItem(at: long)
        #expect(PromptLocalFileResolver.files(in: long.path + " summarize") == [])
        #expect(PromptLocalFileResolver.files(in: short.path + " summarize") == [
            short.standardizedFileURL.resolvingSymlinksInPath()
        ])
        #expect(PromptLocalFileResolver.files(in: literalBackslash.path) == [
            unescaped.standardizedFileURL.resolvingSymlinksInPath()
        ])
        #expect(PromptLocalFileResolver.files(in: "'\(literalBackslash.path)'") == [
            literalBackslash.standardizedFileURL.resolvingSymlinksInPath()
        ])
        #expect(PromptLocalFileResolver.files(in: "file://example.invalid/etc/hosts") == [])
    }

    @Test("path resolver enforces a global file-probe budget")
    func promptPathBudget() {
        let prompt = (0..<100).map { "/tmp/missing-\($0).txt" }.joined(separator: " ")
        var probes = 0

        let files = PromptLocalFileResolver.files(
            in: [prompt, prompt],
            isRegularFile: { _ in
                probes += 1
                return false
            }
        )

        #expect(files.isEmpty)
        #expect(probes <= PromptLocalFileResolver.maximumFileProbes)
    }

    @Test("absolute executable paths do not enable document privacy mode")
    func executablePathIsNotDocument() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionlessDocument = root.appending(path: "README")
        try Data("document".utf8).write(to: extensionlessDocument)

        #expect(PromptLocalFileResolver.files(
            in: "Run /usr/bin/du -sk in the workspace"
        ).isEmpty)
        #expect(PromptLocalFileResolver.files(
            in: "Read \(extensionlessDocument.path)"
        ) == [extensionlessDocument.standardizedFileURL.resolvingSymlinksInPath()])
    }

    @Test("current prompt takes priority over document history")
    func currentPromptPriority() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentDocument = root.appending(path: "current.txt")
        try Data("current".utf8).write(to: currentDocument)
        let history = (0..<100).map { "/tmp/missing-history-\($0).txt" }

        let files = PromptLocalFileResolver.files(
            in: [currentDocument.path + " summarize"] + history
        )

        #expect(files == [currentDocument.standardizedFileURL.resolvingSymlinksInPath()])
    }

    @Test("document tool history keeps later turns in document privacy mode")
    func documentHistoryPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try RuntimeLog(fileURL: root.appending(path: "app.jsonl"))
        let agent = try ChatAgent(
            log: log,
            localResourcesRoot: root,
            jobsRoot: root.appending(path: "jobs")
        )

        #expect(DocumentConversationPolicy.hasDocumentToolHistory(
            toolNames: ["local_resources"]
        ))
        #expect(DocumentConversationPolicy.hasDocumentToolHistory(
            toolNames: [DocumentConversationPolicy.localDocumentReferenceMarker]
        ))
        #expect(!DocumentConversationPolicy.hasDocumentToolHistory(
            toolNames: ["web", "apple_services"]
        ))
        #expect(try await agent.availableToolNames(
            documentPrivacyMode: true,
            managedAttachmentAccess: false
        ) == ["document_analysis", "local_resources"])
    }

}