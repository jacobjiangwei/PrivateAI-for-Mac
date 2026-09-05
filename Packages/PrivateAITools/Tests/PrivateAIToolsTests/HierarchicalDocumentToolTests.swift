import CoreGraphics
import CoreText
import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Hierarchical Document Tool", .serialized)
struct HierarchicalDocumentToolTests {
    @Test("requires canonical paths in the model-facing schema")
    func canonicalPathSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = try HierarchicalDocumentTool(
            provider: DocumentFactProvider(),
            model: "fixture",
            authorizedRoot: root,
            jobsRoot: root.appending(path: "jobs", directoryHint: .isDirectory)
        )
        let pathDescription = tool.definition.function.parameters.objectValue?["properties"]?
            .objectValue?["path"]?.objectValue?["description"]?.stringValue

        #expect(tool.definition.function.description.contains("only when the user explicitly requests"))
        #expect(tool.definition.function.description.contains("quick preview"))
        #expect(pathDescription?.lowercased().contains("canonical absolute posix path") == true)
        #expect(pathDescription?.contains("shell-escaped") == true)
        #expect(pathDescription?.contains("file://") == true)
        #expect(pathDescription?.contains("unescaped absolute form") == true)
    }

    @Test("summarizes every PDF page, reduces recursively, and resumes from files")
    func summarizePDFAndResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "large.pdf")
        try createSummaryPDF(at: pdf, pages: (1...8).map { "FACT-\($0)" })
        let provider = DocumentFactProvider()
        let tool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs,
            summarizerConfiguration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 1,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300,
                maximumReductionLevels: 8,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let arguments: [String: JSONValue] = [
            "action": .string("summarize"),
            "path": .string("large.pdf"),
            "task": .string("Preserve every fact code.")
        ]

        let diagnosticRecorder = DocumentDiagnosticRecorder()
        let firstOutput = try await ToolDiagnostics.$handler.withValue({ diagnostic in
            await diagnosticRecorder.append(diagnostic)
        }) {
            try await tool.execute(arguments: arguments)
        }
        let first = try decodeObject(firstOutput)
        let requestsAfterFirstRun = await provider.requestCount
        let second = try decodeObject(await tool.execute(arguments: arguments))
        let jobID = try #require(first["checkpoint_job_id"]?.stringValue)
        let jobDirectory = jobs.appending(path: jobID)

        for fact in 1...8 {
            #expect(first["summary"]?.stringValue?.contains("FACT-\(fact)") == true)
        }
        #expect(first["coverage"] == .string("all_extractable_pdf_pages"))
        #expect(first["source_unit_count"] == .number(8))
        #expect(first["model_request_count"] == .number(15))
        #expect(second["model_request_count"] == .number(0))
        #expect(await provider.requestCount == requestsAfterFirstRun)
        let diagnostics = await diagnosticRecorder.values
        let checkpointCounts: [Int] = diagnostics.compactMap { diagnostic in
            guard diagnostic.event == "document.summary.checkpoint" else { return nil }
            return diagnostic.data["checkpoint_count"].flatMap(Int.init)
        }
        #expect(!checkpointCounts.isEmpty)
        #expect(checkpointCounts == Array(1...checkpointCounts.count))
        let requestStarts = diagnostics.filter {
            $0.event == "hierarchical.summary.request.started"
        }
        let requestFinishes = diagnostics.filter {
            $0.event == "hierarchical.summary.request.finished"
        }
        #expect(requestStarts.count == 15)
        #expect(requestFinishes.count == 15)
        #expect(requestStarts.allSatisfy {
            $0.data["phase"] != nil && $0.data["input_count"] != nil
        })
        let checkpointFiles = try FileManager.default.contentsOfDirectory(
            at: jobDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(checkpointFiles.count == 15)
        for page in 0..<8 {
            #expect(FileManager.default.fileExists(
                atPath: try checkpointURL(
                    in: jobDirectory,
                    suffix: "-unit-\(page)-segment-0.json"
                ).path
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: try checkpointURL(
                in: jobDirectory,
                suffix: "-document-level-3-group-0.json"
            ).path
        ))
        #expect(try permissions(at: jobDirectory) == 0o700)
        #expect(try permissions(at: checkpointURL(
            in: jobDirectory,
            suffix: "-unit-0-segment-0.json"
        )) == 0o600)

        let corruptURL = try checkpointURL(
            in: jobDirectory,
            suffix: "-unit-0-segment-0.json"
        )
        try Data("corrupt".utf8).write(to: corruptURL, options: .atomic)
        _ = try decodeObject(await tool.execute(arguments: arguments))
        #expect(await provider.requestCount == requestsAfterFirstRun + 1)

        var paraphrasedArguments = arguments
        paraphrasedArguments["task"] = .string("Keep all page fact codes.")
        let beforeParaphrase = await provider.requestCount
        let paraphrased = try decodeObject(await tool.execute(arguments: paraphrasedArguments))
        #expect(paraphrased["checkpoint_job_id"] == first["checkpoint_job_id"])
        #expect(paraphrased["model_request_count"] == .number(15))
        #expect(await provider.requestCount == beforeParaphrase + 15)

        let canonicalArguments = try #require(
            tool.canonicalArgumentsForStabilization(arguments)
        )
        let stabilized = tool.stabilizedArguments(
            paraphrasedArguments,
            previousArguments: [canonicalArguments]
        )
        #expect(stabilized["task"] == arguments["task"])
        var equivalentPath = paraphrasedArguments
        equivalentPath["path"] = .string("./large.pdf")
        #expect(tool.stabilizedArguments(
            equivalentPath,
            previousArguments: [canonicalArguments]
        )["task"] == arguments["task"])
        var differentDocument = paraphrasedArguments
        differentDocument["path"] = .string("other.pdf")
        #expect(tool.stabilizedArguments(
            differentDocument,
            previousArguments: [canonicalArguments]
        )["task"] == paraphrasedArguments["task"])
        var invalidTask = paraphrasedArguments
        invalidTask["task"] = .string("   ")
        #expect(tool.stabilizedArguments(
            invalidTask,
            previousArguments: [canonicalArguments]
        )["task"] == invalidTask["task"])

        let changedTool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs,
            summarizerConfiguration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 1,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 301,
                maximumReductionLevels: 8,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let changed = try decodeObject(await changedTool.execute(arguments: arguments))
        #expect(changed["checkpoint_job_id"] != first["checkpoint_job_id"])
        #expect((changed["model_request_count"]?.integerValue ?? 0) > 0)
    }

    @Test(
        "summarizes and resumes segmented text documents",
        arguments: ["md", "txt"]
    )
    func summarizesSegmentedTextDocuments(extension fileExtension: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = artifacts.appending(path: "document.\(fileExtension)")
        let text = "FACT-1\n\n" + String(repeating: "context ", count: 80) + "\n\nFACT-2"
        try Data(text.utf8).write(to: document)
        let provider = DocumentFactProvider()
        let tool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs,
            summarizerConfiguration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 120,
                maximumReductionInputBytes: 500,
                maximumLeafItemsPerRequest: 2,
                maximumConcurrentLeafRequests: 2,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let arguments: [String: JSONValue] = [
            "action": .string("summarize"),
            "path": .string(document.lastPathComponent),
            "task": .string("Preserve both fact codes.")
        ]

        let first = try decodeObject(await tool.execute(arguments: arguments))
        let second = try decodeObject(await tool.execute(arguments: arguments))

        #expect(first["coverage"] == .string("all_text_chunks"))
        #expect(first["source_unit_count"] == .number(1))
        #expect(first["summary"]?.stringValue?.contains("FACT-1") == true)
        #expect(first["summary"]?.stringValue?.contains("FACT-2") == true)
        #expect((first["model_request_count"]?.integerValue ?? 0) > 1)
        #expect(second["model_request_count"] == .number(0))
    }

    @Test(
        "model uses hierarchical analysis and includes every page fact in its final answer",
        .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
    )
    func modelDrivenWholeDocumentSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "whole-document.pdf")
        let factCodes = ["ALPHA-11", "BRAVO-22", "CHARLIE-33", "DELTA-44"]
        try createSummaryPDF(at: pdf, pages: factCodes.enumerated().map { index, code in
            "Page \(index + 1) contains one required verification code: \(code). Preserve it exactly in every summary."
        })
        let provider = try OllamaProvider()
        let model = "qwen3.8:latest"
        let documentTool = try HierarchicalDocumentTool(
            provider: provider,
            model: model,
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [
                LocalResourcesTool(
                    access: .restricted([artifacts]),
                    maximumTextCharacters: 2_000
                ),
                documentTool
            ]),
            configuration: AgentConfiguration(
                model: model,
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 256),
                think: false,
                maximumToolCallsPerRound: 2,
                maximumToolCallsTotal: 2
            )
        )

        _ = try await runtime.warmUp()
        let result = try await runtime.run(
            prompt: "Summarize the entire attached PDF at \(pdf.path). The final answer must list the exact verification code from every page."
        )
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        let toolMessages = result.messages.filter { $0.role == .tool }

        #expect(calls.contains { $0.function.name == "document_analysis" })
        #expect(result.performance.toolCallCount <= 2)
        #expect(result.performance.modelRequestCount <= 3)
        #expect(toolMessages.contains { message in
            factCodes.allSatisfy(message.content.contains)
        })
        for code in factCodes {
            #expect(result.text.contains(code))
        }
    }

    @Test("does not create checkpoints when immutable model identity is unavailable")
    func rejectsUnavailableModelIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "identity.pdf")
        try createSummaryPDF(at: pdf, pages: ["FACT-1"])
        let provider = UnavailableIdentityProvider()
        let tool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )

        await #expect(throws: IdentityFixtureError.unavailable) {
            try await tool.execute(arguments: [
                "action": .string("summarize"),
                "path": .string("identity.pdf"),
                "task": .string("Preserve FACT-1.")
            ])
        }

        #expect(await provider.requestCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: jobs.path).isEmpty)
    }

    @Test(
        "summarizes an externally supplied large document with real Ollama",
        .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_DOCUMENT_PATH"] != nil)
    )
    func liveLargeDocumentSummary() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["PRIVATEAI_LIVE_DOCUMENT_PATH"])
        let task = try #require(environment["PRIVATEAI_LIVE_DOCUMENT_TASK"])
        let statusURL = environment["PRIVATEAI_LIVE_DOCUMENT_STATUS_PATH"].map {
            URL(fileURLWithPath: $0)
        }
        let expectedUnits = try #require(
            environment["PRIVATEAI_LIVE_DOCUMENT_EXPECTED_UNITS"].flatMap(Int.init)
        )
        let expectedRequests = environment["PRIVATEAI_LIVE_DOCUMENT_EXPECTED_REQUESTS"]
            .flatMap(Int.init)
        let document = URL(fileURLWithPath: path).standardizedFileURL
        let jobs = environment["PRIVATEAI_LIVE_DOCUMENT_JOBS_ROOT"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".privateAI/tests/document-summaries")
        let provider = try OllamaProvider()
        let tool = try HierarchicalDocumentTool(
            provider: provider,
            model: environment["PRIVATEAI_LIVE_DOCUMENT_MODEL"] ?? "qwen3.8:latest",
            authorizedRoot: document.deletingLastPathComponent(),
            jobsRoot: jobs
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result: [String: JSONValue]
        do {
            result = try decodeObject(await tool.execute(arguments: [
                "action": .string("summarize"),
                "path": .string(document.lastPathComponent),
                "task": .string(task)
            ]))
        } catch {
            let status = "LIVE_DOCUMENT_ERROR category=\(liveDocumentErrorCategory(error))"
            writeLiveDocumentStatus(status, to: statusURL)
            print(status)
            throw error
        }
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let sourceUnits = try #require(result["source_unit_count"]?.integerValue)
        let summarizedUnits = try #require(result["summarized_unit_count"]?.integerValue)
        let requests = try #require(result["model_request_count"]?.integerValue)
        let reused = try #require(result["reused_summary_count"]?.integerValue)
        let levels = try #require(result["reduction_levels"]?.integerValue)

        let status = "LIVE_DOCUMENT units=\(sourceUnits) summarized=\(summarizedUnits) "
            + "requests=\(requests) reused=\(reused) levels=\(levels) seconds=\(seconds)"
        writeLiveDocumentStatus(status, to: statusURL)
        print(status)
        #expect(sourceUnits == expectedUnits)
        if let expectedRequests {
            #expect(requests == expectedRequests)
        }
        #expect(summarizedUnits > 0 && summarizedUnits <= sourceUnits)
        #expect(result["summary"]?.stringValue?.isEmpty == false)
    }

    @Test("rejects checkpoint directory and file symlink escapes")
    func rejectsCheckpointSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "symlink.pdf")
        try createSummaryPDF(at: pdf, pages: ["FACT-1"])
        let provider = DocumentFactProvider()
        let baseTool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )
        let arguments: [String: JSONValue] = [
            "action": .string("summarize"),
            "path": .string("symlink.pdf"),
            "task": .string("Preserve FACT-1.")
        ]
        let baseline = try decodeObject(await baseTool.execute(arguments: arguments))
        let jobID = try #require(baseline["checkpoint_job_id"]?.stringValue)
        let job = jobs.appending(path: jobID)

        try FileManager.default.removeItem(at: job)
        try FileManager.default.createSymbolicLink(at: job, withDestinationURL: outside)
        let directoryEscapeTool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )
        await #expect(throws: HierarchicalDocumentToolError.self) {
            try await directoryEscapeTool.execute(arguments: arguments)
        }

        try FileManager.default.removeItem(at: job)
        _ = try decodeObject(await baseTool.execute(arguments: arguments))
        let checkpoint = try checkpointURL(
            in: job,
            suffix: "-unit-0-segment-0.json"
        )
        try FileManager.default.removeItem(at: checkpoint)
        let externalFile = outside.appending(path: "external.json")
        try Data("outside".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: checkpoint,
            withDestinationURL: externalFile
        )
        await #expect(throws: HierarchicalDocumentToolError.self) {
            try await baseTool.execute(arguments: arguments)
        }
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "outside")
    }

}

private actor DocumentFactProvider: ModelProvider, ModelIdentityProviding {
    private(set) var requestCount = 0

    func immutableModelIdentity(for model: String) async throws -> String {
        "fixture-model-digest"
    }

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        requestCount += 1
        let input = request.messages.last?.content ?? ""
        let output: String
        if input.contains("JSON array below"), let start = input.firstIndex(of: "[") {
            let units = try JSONDecoder().decode(
                [DocumentLeafInput].self,
                from: Data(input[start...].utf8)
            )
            let response = DocumentLeafResponse(summaries: units.map { unit in
                DocumentLeafSummary(index: unit.index, summary: factSummary(in: unit.text))
            })
            output = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        } else {
            output = String(
                decoding: try JSONEncoder().encode(
                    DocumentReductionResponse(summary: factSummary(in: input))
                ),
                as: UTF8.self
            )
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(output))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private actor DocumentDiagnosticRecorder {
    private(set) var values: [ToolDiagnostic] = []

    func append(_ diagnostic: ToolDiagnostic) {
        values.append(diagnostic)
    }
}

private enum IdentityFixtureError: Error, Equatable {
    case unavailable
}

private actor UnavailableIdentityProvider: ModelProvider, ModelIdentityProviding {
    private(set) var requestCount = 0

    func immutableModelIdentity(for model: String) async throws -> String {
        throw IdentityFixtureError.unavailable
    }

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private struct DocumentLeafInput: Decodable {
    let index: Int
    let text: String
}

private struct DocumentLeafResponse: Encodable {
    let summaries: [DocumentLeafSummary]
}

private struct DocumentReductionResponse: Encodable {
    let summary: String
}

private struct DocumentLeafSummary: Encodable {
    let index: Int
    let summary: String
}

private func factSummary(in input: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"FACT-\d+"#)
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    let facts = regex.matches(in: input, range: range).compactMap { match -> String? in
        guard let matchRange = Range(match.range, in: input) else { return nil }
        return String(input[matchRange])
    }
    let uniqueFacts = Array(Set(facts)).sorted()
    return uniqueFacts.isEmpty ? "COVERED" : uniqueFacts.joined(separator: " ")
}

private func decodeObject(_ content: String) throws -> [String: JSONValue] {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
    return try #require(value.objectValue)
}

private func createSummaryPDF(at url: URL, pages: [String]) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for text in pages {
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func checkpointURL(in directory: URL, suffix: String) throws -> URL {
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    return try #require(files.first { $0.lastPathComponent.hasSuffix(suffix) })
}

private func liveDocumentErrorCategory(_ error: any Error) -> String {
    guard let error = error as? HierarchicalContextSummarizerError else {
        if error is CancellationError { return "cancelled" }
        if error is OllamaProviderError { return "ollama_provider" }
        if error is HierarchicalDocumentToolError { return "document_tool" }
        return "other"
    }
    return switch error {
    case .noMaterial: "no_material"
    case .emptyModelSummary: "empty_summary"
    case .responseTooLarge: "response_too_large"
    case .incompleteModelSummary: "incomplete_summary"
    case .summaryExceedsCharacterLimit: "summary_too_long"
    case .inputTooLarge: "input_too_large"
    case .tooManySegments: "too_many_segments"
    case .modelRequestBudgetExceeded: "request_budget"
    case .timedOut(let seconds): "timeout_\(seconds)_seconds"
    case .invalidStructuredSummary: "invalid_structured_summary"
    case .invalidStructuredReduction: "invalid_structured_reduction"
    case .streamEndedWithoutCompletion: "incomplete_stream"
    case .reductionDidNotConverge: "reduction_did_not_converge"
    }
}

private func writeLiveDocumentStatus(_ status: String, to url: URL?) {
    guard let url else { return }
    try? Data(status.utf8).write(to: url, options: .atomic)
}