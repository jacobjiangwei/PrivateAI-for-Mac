import Foundation
import LLMCore
import PrivateAITools

actor ChatAgent {
    private let provider: OllamaProvider
    private let localResources: LocalResourcesTool
    private let generalToolRuntime: ToolRuntime
    private let localResourcesRoot: URL
    private let documentSummariesRoot: URL
    private let terminalBackend: TerminalExecutionBackend?
    private let defaultExecutionWorkspace: URL?
    private let log: RuntimeLog
    private var runtimes: [RuntimeKey: AgentRuntime] = [:]

    init(
        log: RuntimeLog,
        localResourcesRoot: URL,
        jobsRoot: URL,
        terminalBackend: TerminalExecutionBackend? = nil,
        defaultExecutionWorkspace: URL? = nil
    ) throws {
        provider = try OllamaProvider()
        self.localResourcesRoot = localResourcesRoot
        documentSummariesRoot = jobsRoot.appending(
            path: "document-summaries",
            directoryHint: .isDirectory
        )
        self.terminalBackend = terminalBackend
        self.defaultExecutionWorkspace = defaultExecutionWorkspace?
            .standardizedFileURL.resolvingSymlinksInPath()
        localResources = LocalResourcesTool(
            access: .restricted([localResourcesRoot]),
            maximumTextCharacters: 2_000
        )
        generalToolRuntime = try ToolRuntime(tools: [
            AppleServicesTool(),
            WebTool()
        ])
        self.log = log
    }

    func respond(
        prompt: String,
        history: [ChatMessage],
        model: String,
        runID: UUID,
        conversationID: UUID,
        documentPrivacyMode: Bool,
        executionWorkspace: URL? = nil,
        managedAttachmentAccess: Bool = true,
        authorizedLocalFiles: [URL] = [],
        onEvent: @escaping AgentRuntime.EventHandler
    ) async throws -> AgentResult {
        await log.record("agent.request.started", fields: [
            "authorized_local_files": String(authorizedLocalFiles.count),
            "history_messages": String(history.count),
            "model": model
        ])
        let runtime = try runtime(
            for: model,
            documentPrivacyMode: documentPrivacyMode,
            executionWorkspace: executionWorkspace,
            managedAttachmentAccess: managedAttachmentAccess,
            authorizedLocalFiles: authorizedLocalFiles
        )
        do {
            let result = try await ToolDiagnostics.$handler.withValue({ diagnostic in
                await self.log.record(
                    diagnostic.event,
                    level: diagnostic.level,
                    category: "tool",
                    runID: runID,
                    conversationID: conversationID,
                    data: diagnostic.data
                )
                if let progress = self.progressEvent(for: diagnostic) {
                    await onEvent(progress)
                }
            }) {
                try await runtime.run(prompt: prompt, history: history, onEvent: onEvent)
            }
            await log.record("agent.request.finished", fields: [
                "model": model,
                "model_requests": String(result.performance.modelRequestCount),
                "tool_calls": String(result.performance.toolCallCount),
                "total_seconds": String(result.performance.totalSeconds)
            ])
            return result
        } catch is CancellationError {
            await runtime.cancelActiveTools()
            await log.record("agent.request.cancelled", fields: ["model": model])
            throw CancellationError()
        } catch {
            await runtime.cancelActiveTools()
            await log.record("agent.request.failed", fields: [
                "error": String(describing: error),
                "model": model
            ])
            throw error
        }
    }

    func warmUp(model: String) async throws -> WarmupMetrics {
        let runtime = try runtime(for: model, documentPrivacyMode: false)
        await log.record("agent.warmup.started", fields: ["model": model])
        do {
            let metrics = try await runtime.warmUp()
            await log.record("agent.warmup.finished", fields: [
                "elapsed_seconds": String(metrics.elapsedSeconds),
                "model": model,
                "prefix_tokens": String(metrics.prefixPromptTokenCount ?? 0)
            ])
            return metrics
        } catch {
            await log.record("agent.warmup.failed", fields: [
                "error": String(describing: error),
                "model": model
            ])
            throw error
        }
    }

    func availableToolNames(
        documentPrivacyMode: Bool,
        model: String = "fixture",
        executionWorkspace: URL? = nil,
        managedAttachmentAccess: Bool = true,
        authorizedLocalFiles: [URL] = []
    ) async throws -> [String] {
        let runtime = try toolRuntime(
            for: model,
            documentPrivacyMode: documentPrivacyMode,
            executionWorkspace: executionWorkspace,
            managedAttachmentAccess: managedAttachmentAccess,
            authorizedLocalFiles: authorizedLocalFiles
        )
        return await runtime.definitions.map { $0.function.name }
    }

    private func runtime(
        for model: String,
        documentPrivacyMode: Bool,
        executionWorkspace: URL? = nil,
        managedAttachmentAccess: Bool = false,
        authorizedLocalFiles: [URL] = []
    ) throws -> AgentRuntime {
        let effectiveExecutionWorkspace = executionWorkspace
            ?? defaultExecutionWorkspace
        let key = RuntimeKey(
            model: model,
            documentPrivacyMode: documentPrivacyMode,
            executionWorkspacePath: effectiveExecutionWorkspace?.path,
            managedAttachmentAccess: managedAttachmentAccess,
            authorizedLocalPaths: authorizedLocalFiles.map(\.path).sorted()
        )
        if let runtime = runtimes[key] {
            return runtime
        }
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try toolRuntime(
                for: model,
                documentPrivacyMode: documentPrivacyMode,
                executionWorkspace: effectiveExecutionWorkspace,
                managedAttachmentAccess: managedAttachmentAccess,
                authorizedLocalFiles: authorizedLocalFiles
            ),
            configuration: configuration(for: model)
        )
        runtimes[key] = runtime
        return runtime
    }

    private func toolRuntime(
        for model: String,
        documentPrivacyMode: Bool,
        executionWorkspace: URL? = nil,
        managedAttachmentAccess: Bool = false,
        authorizedLocalFiles: [URL] = []
    ) throws -> ToolRuntime {
        guard documentPrivacyMode else {
                        guard let terminalBackend,
                                    let executionWorkspace = executionWorkspace
                                        ?? defaultExecutionWorkspace else {
                return generalToolRuntime
            }
            return try ToolRuntime(tools: [
                AppleServicesTool(),
                TerminalTool(
                    workspace: executionWorkspace,
                    backend: terminalBackend
                ),
                WebTool()
            ])
        }
        let roots = (managedAttachmentAccess ? [localResourcesRoot] : [])
            + authorizedLocalFiles
        let localResources = LocalResourcesTool(
            access: .restricted(roots),
            maximumTextCharacters: 2_000
        )
        let documentAnalysis = try HierarchicalDocumentTool(
            provider: provider,
            model: model,
            authorizedRoots: roots,
            jobsRoot: documentSummariesRoot
        )
        let runtime = try ToolRuntime(tools: [localResources, documentAnalysis])
        return runtime
    }

    private nonisolated func configuration(for model: String) -> AgentConfiguration {
        AgentConfiguration(
            model: model,
            keepAlive: "-1",
            options: ModelOptions(numContext: 8_192, temperature: 0.2, numPredict: 2_048),
            think: true,
            maximumToolRounds: 64
        )
    }

    private nonisolated func progressEvent(for diagnostic: ToolDiagnostic) -> AgentEvent? {
        switch diagnostic.event {
        case "document.summary.started":
            let units = diagnostic.data["source_units"] ?? "?"
            return .toolProgress(
                name: "document_analysis",
                detail: "Summarizing \(units) document sections"
            )
        case "document.summary.checkpoint":
            let level = diagnostic.data["level"] ?? "?"
            let count = diagnostic.data["checkpoint_count"] ?? "?"
            return .toolProgress(
                name: "document_analysis",
                detail: "Saved checkpoint \(count) at level \(level)"
            )
        case "hierarchical.summary.request.started":
            let count = diagnostic.data["input_count"] ?? "?"
            let detail = diagnostic.data["phase"] == "leaf"
                ? "Analyzing \(count) document sections"
                : "Combining \(count) summaries"
            return .toolProgress(name: "document_analysis", detail: detail)
        case "hierarchical.summary.request.finished":
            let outputTokens = Double(diagnostic.data["output_tokens"] ?? "") ?? 0
            let outputNanoseconds = Double(
                diagnostic.data["output_duration_nanoseconds"] ?? ""
            ) ?? 0
            let rate = outputNanoseconds > 0
                ? outputTokens / (outputNanoseconds / 1_000_000_000)
                : 0
            return .toolProgress(
                name: "document_analysis",
                detail: rate > 0
                    ? "Completed model batch · \(String(format: "%.1f", rate)) tok/s"
                    : "Completed model batch"
            )
        case "document.summary.finished":
            return .toolProgress(
                name: "document_analysis",
                detail: "Combining document summary"
            )
        default:
            return nil
        }
    }
}

nonisolated private struct RuntimeKey: Hashable {
    let model: String
    let documentPrivacyMode: Bool
    let executionWorkspacePath: String?
    let managedAttachmentAccess: Bool
    let authorizedLocalPaths: [String]
}

nonisolated enum PromptLocalFileResolver {
    static let maximumFiles = 8
    static let maximumPathCharacters = 4_096
    static let maximumPromptCharacters = 16_384
    static let maximumPrompts = 16
    static let maximumRepresentations = 32
    static let maximumFileProbes = 32

    static func files(
        in prompt: String,
        fileManager: FileManager = .default
    ) -> [URL] {
        files(in: [prompt], fileManager: fileManager)
    }

    static func files(
        in prompts: [String],
        fileManager: FileManager = .default,
        isRegularFile: (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        },
        isExecutableFile: (URL) -> Bool = { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        }
    ) -> [URL] {
        var files: [URL] = []
        var seenPaths = Set<String>()
        var representationCount = 0
        var probeCount = 0
        for prompt in prompts.prefix(maximumPrompts) {
            let boundedPrompt = String(prompt.prefix(maximumPromptCharacters))
            for group in representationGroups(in: boundedPrompt) {
                guard files.count < maximumFiles else { return files }
                guard representationCount + group.count <= maximumRepresentations
                else {
                    return files
                }
                representationCount += group.count
                let longestRepresentation = group.map(\.value.count).max() ?? 0
                var matches: [(url: URL, representationLength: Int)] = []
                for representation in group {
                    guard probeCount < maximumFileProbes else { return files }
                    guard let candidate = candidate(
                        for: representation.value,
                        allowsShellEscaping: representation.allowsShellEscaping,
                        fileManager: fileManager
                    ), LocalDocumentFormat.supports(url: candidate) else {
                        continue
                    }
                    probeCount += 1
                    guard isRegularFile(candidate),
                          !candidate.pathExtension.isEmpty || !isExecutableFile(candidate)
                    else {
                        continue
                    }
                    matches.append((
                        candidate.standardizedFileURL.resolvingSymlinksInPath(),
                        representation.value.count
                    ))
                }
                let uniqueMatches = Dictionary(grouping: matches, by: { $0.url.path })
                guard uniqueMatches.count == 1,
                      let match = uniqueMatches.values.first?.first?.url,
                      matches.contains(where: {
                          $0.url.path == match.path
                              && $0.representationLength == longestRepresentation
                      })
                else {
                    continue
                }
                if seenPaths.insert(match.path).inserted {
                    files.append(match)
                }
            }
        }
        return files
    }

    private static func representationGroups(in prompt: String) -> [[PathRepresentation]] {
        var groups: [[PathRepresentation]] = []
        var totalRepresentations = 0
        for start in prompt.indices where totalRepresentations < maximumRepresentations {
            let suffix = prompt[start...]
            guard suffix.hasPrefix("/") || suffix.hasPrefix("~/") || suffix.hasPrefix("file://"),
                  isBoundary(start, in: prompt)
            else {
                continue
            }
            let previous = start == prompt.startIndex ? nil : prompt[prompt.index(before: start)]
            if let quote = previous, "\"'`".contains(quote),
               let end = prompt[start...].firstIndex(of: quote)
            {
                groups.append([PathRepresentation(
                    value: String(prompt[start..<end]),
                    allowsShellEscaping: quote != "'"
                )])
                totalRepresentations += 1
                continue
            }
            let limit = prompt.index(
                start,
                offsetBy: maximumPathCharacters,
                limitedBy: prompt.endIndex
            ) ?? prompt.endIndex
            var group: [PathRepresentation] = []
            if let tokenEnd = shellTokenEnd(in: prompt, from: start, limit: limit) {
                group.append(PathRepresentation(
                    value: String(prompt[start..<tokenEnd]),
                    allowsShellEscaping: true
                ))
            }
            for end in formatTerminatedEnds(in: prompt, from: start, limit: limit) {
                group.append(PathRepresentation(
                    value: String(prompt[start..<end]),
                    allowsShellEscaping: true
                ))
            }
            group = Array(Set(group)).sorted { $0.value.count < $1.value.count }
            guard !group.isEmpty else { continue }
            groups.append(group)
            totalRepresentations += group.count
        }
        return groups
    }

    private static func isBoundary(_ index: String.Index, in prompt: String) -> Bool {
        guard index != prompt.startIndex else { return true }
        let previous = prompt[prompt.index(before: index)]
        return previous.isWhitespace || "\"'`([{<=>%".contains(previous)
    }

    private static func candidate(
        for representation: String,
        allowsShellEscaping: Bool,
        fileManager: FileManager
    ) -> URL? {
        let value: String
        if allowsShellEscaping {
            guard let unescaped = shellUnescaped(representation) else { return nil }
            value = unescaped
        } else {
            value = representation
        }
        if value.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host?.isEmpty == true || url.host == "localhost"
            else {
                return nil
            }
            return url
        }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private static func shellTokenEnd(
        in prompt: String,
        from start: String.Index,
        limit: String.Index
    ) -> String.Index? {
        var index = start
        var isEscaped = false
        while index < limit {
            let character = prompt[index]
            if !isEscaped, character.isWhitespace { break }
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            }
            index = prompt.index(after: index)
        }
        return index > start ? index : nil
    }

    private static func formatTerminatedEnds(
        in prompt: String,
        from start: String.Index,
        limit: String.Index
    ) -> [String.Index] {
        var results: [String.Index] = []
        var index = start
        while index < limit {
            let character = prompt[index]
            guard character == "." else {
                index = prompt.index(after: index)
                continue
            }
            let extensionStart = prompt.index(after: index)
            for fileExtension in LocalDocumentFormat.supportedFilenameExtensions {
                guard prompt[extensionStart...].lowercased().hasPrefix(fileExtension) else {
                    continue
                }
                guard let end = prompt.index(
                    extensionStart,
                    offsetBy: fileExtension.count,
                    limitedBy: limit
                ), isPathEnd(end, in: prompt) else {
                    continue
                }
                results.append(end)
            }
            index = prompt.index(after: index)
        }
        return results
    }

    private static func isPathEnd(_ index: String.Index, in prompt: String) -> Bool {
        guard index < prompt.endIndex else { return true }
        return prompt[index].isWhitespace
    }

    private static func shellUnescaped(_ value: String) -> String? {
        var result = ""
        var isEscaped = false
        for character in value {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        return isEscaped ? nil : result
    }

    private struct PathRepresentation: Hashable {
        let value: String
        let allowsShellEscaping: Bool
    }
}