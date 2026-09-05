import CryptoKit
import Foundation
import LLMCore
import PDFKit

public enum HierarchicalDocumentToolError: Error, Equatable, LocalizedError, Sendable {
    case outsideAuthorizedRoot(String)
    case resourceNotFound(String)
    case unsupportedFileType(String)
    case fileTooLarge(Int)
    case lockedPDF
    case unreadablePDF
    case noExtractableText
    case tooManySourceUnits(Int)
    case unreadableTextEncoding
    case invalidCheckpointKey(String)
    case checkpointOutsideJobsRoot(String)
    case modelIdentityUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .outsideAuthorizedRoot(let path):
            "The path '\(path)' is outside the document analysis root."
        case .resourceNotFound(let path):
            "The document '\(path)' does not exist."
        case .unsupportedFileType(let type):
            "The document type '\(type)' is not supported for analysis."
        case .fileTooLarge(let limit):
            "The document exceeded the \(limit)-byte analysis limit."
        case .lockedPDF:
            "The PDF is locked and cannot be analyzed."
        case .unreadablePDF:
            "PDFKit could not open the PDF for analysis."
        case .noExtractableText:
            "The document does not contain extractable text."
        case .tooManySourceUnits(let limit):
            "The document exceeded the \(limit)-unit analysis limit."
        case .unreadableTextEncoding:
            "The document text encoding could not be decoded reliably."
        case .invalidCheckpointKey(let key):
            "The summary checkpoint key '\(key)' is invalid."
        case .checkpointOutsideJobsRoot(let path):
            "The summary checkpoint path '\(path)' is outside the managed jobs root."
        case .modelIdentityUnavailable(let model):
            "The immutable identity for model '\(model)' is unavailable. Try again before starting document analysis."
        }
    }
}

public actor HierarchicalDocumentTool: LLMTool {
    public nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: PrivateAIToolPrompts.DocumentAnalysis.name,
            description: PrivateAIToolPrompts.DocumentAnalysis.tool,
            parameters: objectSchema(
                properties: [
                    "action": stringSchema(
                        description: PrivateAIToolPrompts.DocumentAnalysis.action,
                        values: ["summarize"]
                    ),
                    "path": stringSchema(
                        description: PrivateAIToolPrompts.DocumentAnalysis.path
                    ),
                    "task": stringSchema(
                        description: PrivateAIToolPrompts.DocumentAnalysis.task
                    )
                ],
                required: ["action", "path", "task"]
            )
        )
    )

    private static let extractorVersion = 1
    private let provider: any ModelProvider
    private let model: String
    private let authorizedRoots: [URL]
    private let jobsRoot: URL
    private let summarizerConfiguration: HierarchicalSummaryConfiguration
    private let maximumFileBytes: Int
    private let maximumSourceUnits: Int
    private let fileManager: FileManager
    private let sessionCacheIdentity = UUID().uuidString

    public init(
        provider: any ModelProvider,
        model: String,
        authorizedRoot: URL,
        jobsRoot: URL,
        summarizerConfiguration: HierarchicalSummaryConfiguration = HierarchicalSummaryConfiguration(),
        maximumFileBytes: Int = 20 * 1_024 * 1_024,
        maximumSourceUnits: Int = 1_000,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            provider: provider,
            model: model,
            authorizedRoots: [authorizedRoot],
            jobsRoot: jobsRoot,
            summarizerConfiguration: summarizerConfiguration,
            maximumFileBytes: maximumFileBytes,
            maximumSourceUnits: maximumSourceUnits,
            fileManager: fileManager
        )
    }

    public init(
        provider: any ModelProvider,
        model: String,
        authorizedRoots: [URL],
        jobsRoot: URL,
        summarizerConfiguration: HierarchicalSummaryConfiguration = HierarchicalSummaryConfiguration(),
        maximumFileBytes: Int = 20 * 1_024 * 1_024,
        maximumSourceUnits: Int = 1_000,
        fileManager: FileManager = .default
    ) throws {
        self.provider = provider
        self.model = model
        self.authorizedRoots = authorizedRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.jobsRoot = jobsRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.summarizerConfiguration = summarizerConfiguration
        self.maximumFileBytes = maximumFileBytes
        self.maximumSourceUnits = maximumSourceUnits
        self.fileManager = fileManager
        try Self.createPrivateDirectory(self.jobsRoot, fileManager: fileManager)
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        let values = CapabilityArguments(values: arguments)
        try values.requireOnly(["action", "path", "task"])
        let action = try values.requiredString("action", maximumBytes: 32)
        guard action == "summarize" else {
            throw CapabilityToolError.unsupportedAction(action)
        }
        let rawPath = try values.requiredString("path", maximumBytes: 4_096)
        let task = try values.requiredString("task", maximumBytes: 4_096)
        let document = try resolve(rawPath)
        let accessedSecurityScope = document.root.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                document.root.stopAccessingSecurityScopedResource()
            }
        }

        let digest = try hashFile(at: document.url)
        let modelIdentity = try await resolvedModelIdentity()
        let jobID = jobIdentifier(
            documentDigest: digest,
            modelIdentity: modelIdentity
        )
        let jobDirectory = jobsRoot.appending(path: jobID, directoryHint: .isDirectory)
        let store = try FileSummaryCheckpointStore(
            jobsRoot: jobsRoot,
            jobDirectory: jobDirectory
        )
        let source = try await loadMaterials(from: document.url)
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: model,
            configuration: summarizerConfiguration
        )
        let progressCounter = SummaryProgressCounter()

        await ToolDiagnostics.record("document.summary.started", data: [
            "job_id": jobID,
            "source_units": String(source.totalUnitCount)
        ])
        let result = try await summarizer.summarize(
            materials: source.materials,
            task: task,
            store: store
        ) { metadata in
            let checkpointCount = await progressCounter.increment()
            await ToolDiagnostics.record("document.summary.checkpoint", data: [
                "checkpoint_count": String(checkpointCount),
                "index": String(metadata.index),
                "job_id": jobID,
                "level": String(metadata.level),
                "source_count": String(metadata.sourceIDs.count)
            ])
        }
        await ToolDiagnostics.record("document.summary.finished", data: [
            "job_id": jobID,
            "model_requests": String(result.modelRequestCount),
            "reduction_levels": String(result.reductionLevels),
            "reused_summaries": String(result.reusedSummaryCount)
        ])

        return try encodeToolResult(.object([
            "kind": .string("hierarchical_document_summary"),
            "summary": .string(result.summary),
            "coverage": .string(source.coverage),
            "source_unit_count": .number(Double(source.totalUnitCount)),
            "summarized_unit_count": .number(Double(result.materialCount)),
            "skipped_empty_units": .number(Double(source.skippedEmptyUnits)),
            "reduction_levels": .number(Double(result.reductionLevels)),
            "model_request_count": .number(Double(result.modelRequestCount)),
            "reused_summary_count": .number(Double(result.reusedSummaryCount)),
            "checkpoint_job_id": .string(jobID)
        ]))
    }

    private func resolve(_ path: String) throws -> AuthorizedDocument {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates = expanded.hasPrefix("/")
            ? [URL(fileURLWithPath: expanded)]
            : authorizedRoots.map { $0.appending(path: expanded) }
        let authorized = candidates.lazy
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .compactMap { candidate in
                self.authorizedRoots.first(where: {
                    self.contains(candidate, root: $0)
                }).map {
                    AuthorizedDocument(url: candidate, root: $0)
                }
            }
        guard !authorized.isEmpty else {
            throw HierarchicalDocumentToolError.outsideAuthorizedRoot(path)
        }
        guard let document = authorized.first(where: {
            fileManager.fileExists(atPath: $0.url.path)
        }) else {
            throw HierarchicalDocumentToolError.resourceNotFound(path)
        }
        return document
    }

    private func loadMaterials(from url: URL) async throws -> DocumentMaterialSource {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard (values.fileSize ?? 0) <= maximumFileBytes else {
            throw HierarchicalDocumentToolError.fileTooLarge(maximumFileBytes)
        }
        let format = LocalDocumentFormat.detect(url: url)
        guard format.isSupported else {
            throw HierarchicalDocumentToolError.unsupportedFileType(
                values.contentType?.identifier ?? url.pathExtension
            )
        }
        if format == .pdf {
            return try await loadPDFMaterials(from: url)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumFileBytes else {
            throw HierarchicalDocumentToolError.fileTooLarge(maximumFileBytes)
        }
        guard let text = decodeText(data), isPlausibleText(text) else {
            throw HierarchicalDocumentToolError.unreadableTextEncoding
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HierarchicalDocumentToolError.noExtractableText
        }
        return DocumentMaterialSource(
            materials: [ContextMaterial(id: "document", title: "Document", text: text)],
            totalUnitCount: 1,
            skippedEmptyUnits: 0,
            coverage: "all_text_chunks"
        )
    }

    private func loadPDFMaterials(from url: URL) async throws -> DocumentMaterialSource {
        guard let document = PDFDocument(url: url) else {
            throw HierarchicalDocumentToolError.unreadablePDF
        }
        guard !document.isLocked else {
            throw HierarchicalDocumentToolError.lockedPDF
        }
        guard document.pageCount <= maximumSourceUnits else {
            throw HierarchicalDocumentToolError.tooManySourceUnits(maximumSourceUnits)
        }
        var materials: [ContextMaterial] = []
        var skipped = 0
        var extractedBytes = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = document.page(at: pageIndex)?.string ?? ""
            try Task.checkCancellation()
            extractedBytes += text.utf8.count
            guard extractedBytes <= summarizerConfiguration.maximumTotalInputBytes else {
                throw HierarchicalContextSummarizerError.inputTooLarge(
                    summarizerConfiguration.maximumTotalInputBytes
                )
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                skipped += 1
                continue
            }
            materials.append(ContextMaterial(
                id: "page-\(pageIndex + 1)",
                title: "Page \(pageIndex + 1)",
                text: text
            ))
        }
        guard !materials.isEmpty else {
            throw HierarchicalDocumentToolError.noExtractableText
        }
        return DocumentMaterialSource(
            materials: materials,
            totalUnitCount: document.pageCount,
            skippedEmptyUnits: skipped,
            coverage: "all_extractable_pdf_pages"
        )
    }

    private func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            .windowsCP1252, .isoLatin1
        ]
        return encodings.lazy.compactMap { String(data: data, encoding: $0) }.first
    }

    private func isPlausibleText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let suspicious = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value == 0 || (scalar.value < 0x20 && !"\n\r\t".unicodeScalars.contains(scalar)) {
                count += 1
            }
        }
        return suspicious * 100 <= text.unicodeScalars.count
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            byteCount += data.count
            guard byteCount <= maximumFileBytes else {
                throw HierarchicalDocumentToolError.fileTooLarge(maximumFileBytes)
            }
            hasher.update(data: data)
        }
        return hexString(hasher.finalize())
    }

    private func jobIdentifier(
        documentDigest: String,
        modelIdentity: String
    ) -> String {
        let options = summarizerConfiguration.options
        let identity = """
        core_pipeline=\(HierarchicalContextSummarizer.pipelineVersion)
        prompt=\(HierarchicalContextSummarizer.promptVersion)
        extractor=\(Self.extractorVersion)
        model=\(model)
        model_identity=\(modelIdentity)
        document=\(documentDigest)
        material_bytes=\(summarizerConfiguration.maximumMaterialBytes)
        reduction_bytes=\(summarizerConfiguration.maximumReductionInputBytes)
        leaf_items=\(summarizerConfiguration.maximumLeafItemsPerRequest)
        leaf_concurrency=\(summarizerConfiguration.maximumConcurrentLeafRequests)
        leaf_summary_characters=\(summarizerConfiguration.maximumLeafSummaryCharacters)
        items_per_group=\(summarizerConfiguration.maximumItemsPerGroup)
        summary_characters=\(summarizerConfiguration.maximumSummaryCharacters)
        summary_output_bytes=\(summarizerConfiguration.maximumSummaryOutputBytes)
        reduction_levels=\(summarizerConfiguration.maximumReductionLevels)
        total_input_bytes=\(summarizerConfiguration.maximumTotalInputBytes)
        segment_count=\(summarizerConfiguration.maximumSegmentCount)
        model_requests=\(summarizerConfiguration.maximumModelRequests)
        wall_clock_seconds=\(summarizerConfiguration.maximumWallClockSeconds)
        request_seconds=\(summarizerConfiguration.maximumRequestSeconds)
        keep_alive=\(summarizerConfiguration.keepAlive)
        context=\(options.numContext)
        temperature=\(options.temperature)
        predict=\(options.numPredict.map(String.init) ?? "nil")
        """
        return hexString(SHA256.hash(data: Data(identity.utf8)))
    }

    private func resolvedModelIdentity() async throws -> String {
        guard let identityProvider = provider as? any ModelIdentityProviding else {
            return "session:\(sessionCacheIdentity)"
        }
        let identity = try await identityProvider.immutableModelIdentity(for: model)
        guard !identity.isEmpty else {
            throw HierarchicalDocumentToolError.modelIdentityUnavailable(model)
        }
        return "immutable:\(identity)"
    }

    public nonisolated func stabilizedArguments(
        _ arguments: [String: JSONValue],
        previousArguments: [[String: JSONValue]]
    ) -> [String: JSONValue] {
        guard let canonical = canonicalArgumentsForStabilization(arguments),
              let path = canonical["path"]?.stringValue,
              let previous = previousArguments.first(where: {
                $0["action"]?.stringValue == "summarize"
                    && $0["path"]?.stringValue == path
                    && $0["task"]?.stringValue?.isEmpty == false
              }),
              let stableTask = previous["task"]
        else {
            return arguments
        }
        var stabilized = arguments
        stabilized["task"] = stableTask
        return stabilized
    }

    public nonisolated func canonicalArgumentsForStabilization(
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue]? {
        guard Set(arguments.keys) == ["action", "path", "task"],
              arguments["action"]?.stringValue?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ) == "summarize",
              let rawPath = boundedTrimmedString(arguments["path"], maximumBytes: 4_096),
              let task = boundedTrimmedString(arguments["task"], maximumBytes: 4_096)
        else {
            return nil
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let candidates = expanded.hasPrefix("/")
            ? [URL(fileURLWithPath: expanded)]
            : authorizedRoots.map { $0.appending(path: expanded) }
        guard let resolved = candidates.lazy
            .map({ $0.standardizedFileURL.resolvingSymlinksInPath() })
            .first(where: { candidate in
                authorizedRoots.contains { contains(candidate, root: $0) }
            })
        else {
            return nil
        }
        return [
            "action": .string("summarize"),
            "path": .string(resolved.path),
            "task": .string(task)
        ]
    }

    public nonisolated func successfulResultReuseKey(
        arguments: [String: JSONValue]
    ) -> String? {
        canonicalArgumentsForStabilization(arguments)?["path"]?.stringValue
    }

    private func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func boundedTrimmedString(
        _ value: JSONValue?,
        maximumBytes: Int
    ) -> String? {
        guard let result = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty,
              result.utf8.count <= maximumBytes
        else {
            return nil
        }
        return result
    }

    private nonisolated func contains(_ resource: URL, root: URL) -> Bool {
        let resourceComponents = resource.pathComponents
        let rootComponents = root.pathComponents
        return resourceComponents.count >= rootComponents.count
            && Array(resourceComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private actor FileSummaryCheckpointStore: HierarchicalSummaryStore {
    private let root: URL
    private let jobsRoot: URL
    private let fileManager = FileManager.default

    init(jobsRoot: URL, jobDirectory: URL) throws {
        self.jobsRoot = jobsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedJob = jobDirectory.standardizedFileURL
        if try Self.isSymbolicLink(standardizedJob) {
            throw HierarchicalDocumentToolError.checkpointOutsideJobsRoot(
                standardizedJob.path
            )
        }
        try FileManager.default.createDirectory(
            at: standardizedJob,
            withIntermediateDirectories: true
        )
        let resolvedJob = standardizedJob.resolvingSymlinksInPath()
        guard Self.contains(resolvedJob, root: self.jobsRoot) else {
            throw HierarchicalDocumentToolError.checkpointOutsideJobsRoot(
                standardizedJob.path
            )
        }
        root = resolvedJob
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
    }

    func loadSummary(for metadata: SummaryArtifactMetadata) async throws -> String? {
        let url = try summaryURL(for: metadata.key)
        if try Self.isSymbolicLink(url) {
            throw HierarchicalDocumentToolError.checkpointOutsideJobsRoot(url.path)
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(
                SummaryCheckpointEnvelope.self,
                from: data
              )
        else {
            return nil
        }
        guard envelope.metadata == metadata,
              envelope.summaryDigest == digest(envelope.summary)
        else {
            return nil
        }
        return envelope.summary
    }

    func saveSummary(_ summary: String, metadata: SummaryArtifactMetadata) async throws {
        let url = try summaryURL(for: metadata.key)
        if try Self.isSymbolicLink(url) {
            throw HierarchicalDocumentToolError.checkpointOutsideJobsRoot(url.path)
        }
        let envelope = SummaryCheckpointEnvelope(
            metadata: metadata,
            summary: summary,
            summaryDigest: digest(summary)
        )
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func summaryURL(for key: String) throws -> URL {
        guard !key.isEmpty,
              key.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              })
        else {
            throw HierarchicalDocumentToolError.invalidCheckpointKey(key)
        }
        let candidate = root.appending(path: key).appendingPathExtension("json")
            .standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard Self.contains(resolvedParent, root: jobsRoot) else {
            throw HierarchicalDocumentToolError.checkpointOutsideJobsRoot(candidate.path)
        }
        return candidate
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }

    private static func contains(_ resource: URL, root: URL) -> Bool {
        let resourceComponents = resource.pathComponents
        let rootComponents = root.pathComponents
        return resourceComponents.count >= rootComponents.count
            && Array(resourceComponents.prefix(rootComponents.count)) == rootComponents
    }
}

private struct SummaryCheckpointEnvelope: Codable {
    let metadata: SummaryArtifactMetadata
    let summary: String
    let summaryDigest: String
}

private struct AuthorizedDocument {
    let url: URL
    let root: URL
}

private struct DocumentMaterialSource {
    let materials: [ContextMaterial]
    let totalUnitCount: Int
    let skippedEmptyUnits: Int
    let coverage: String
}

private actor SummaryProgressCounter {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}