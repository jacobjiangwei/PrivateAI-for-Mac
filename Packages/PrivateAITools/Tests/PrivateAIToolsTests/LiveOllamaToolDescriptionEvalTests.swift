import Foundation
import ExecutionKit
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Live Ollama Tool Description Eval", .serialized)
struct LiveOllamaToolDescriptionEvalTests {
    private struct RoutingCase {
        let label: String
        let prompt: String
        let required: Set<String>
        let allowed: Set<String>
    }

    private struct RoutingResult {
        let selected: Set<String>
        let requiredCoverage: Int
        let unnecessaryCalls: Int
    }

    @Test(
        "compares defensive and evidence-oriented terminal descriptions",
        .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_TOOL_DESCRIPTION_EVAL"] == "1")
    )
    func compareTerminalDescriptions() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = environment["PRIVATEAI_TOOL_ROUTING_MODEL"] ?? "qwen3.8:27b-mlx"
        let provider = try OllamaProvider(requestTimeout: 600)
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "privateai-routing-eval-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let terminal = try TerminalTool(workspace: workspace, worker: RoutingWorker())
        let web = WebTool()
        let baseDefinitions = [
            AppleServicesTool().definition,
            await web.definition
        ]
        let cases = [
            RoutingCase(
                label: "host-network",
                prompt: "帮我检查这台 Mac 到 Google 的延迟和丢包，并看看路由经过哪些跳点。",
                required: ["terminal"],
                allowed: ["terminal", "apple_services"]
            ),
            RoutingCase(
                label: "public-web",
                prompt: "查一下 Swift 官方网站现在首页发布的最新文章标题。",
                required: ["web"],
                allowed: ["web"]
            ),
            RoutingCase(
                label: "native-network",
                prompt: "检查这台 Mac 当前是不是通过 Wi-Fi 联网。",
                required: ["apple_services"],
                allowed: ["apple_services", "terminal"]
            ),
            RoutingCase(
                label: "code-execution",
                prompt: "在当前工作区创建一个打印 42 的 Python 脚本，运行并确认输出。",
                required: ["terminal"],
                allowed: ["terminal"]
            ),
            RoutingCase(
                label: "stable-knowledge",
                prompt: "用两句话解释什么是二分查找。",
                required: [],
                allowed: []
            ),
            RoutingCase(
                label: "mixed-network",
                prompt: "判断这台 Mac 能不能访问 Google：既检查本机网络路径，也确认 Google 网页是否可访问。",
                required: ["terminal", "web"],
                allowed: ["terminal", "web", "apple_services"]
            )
        ]
        let descriptions = [
            "defensive": "Run general-purpose non-interactive zsh commands for filesystem work, code, builds, tests, scripts, process inspection, and network diagnostics in the App-managed or user-authorized workspace at \(workspace.path). This is not a file-only capability or executable allowlist.",
            "evidence-oriented": PrivateAIToolPrompts.Terminal.tool(
                workspacePath: workspace.path
            )
        ]
        var scores: [String: (coverage: Int, unnecessary: Int)] = [:]

        for (descriptionLabel, description) in descriptions.sorted(by: { $0.key < $1.key }) {
            var coverage = 0
            var unnecessary = 0
            for routingCase in cases {
                let terminalDefinition = ToolDefinition(
                    function: ToolFunctionDefinition(
                        name: terminal.definition.function.name,
                        description: description,
                        parameters: terminal.definition.function.parameters
                    )
                )
                let result = try await route(
                    prompt: routingCase.prompt,
                    model: model,
                    provider: provider,
                    tools: baseDefinitions + [terminalDefinition],
                    routingCase: routingCase
                )
                coverage += result.requiredCoverage
                unnecessary += result.unnecessaryCalls
                print(
                    "ROUTING_AB description=\(descriptionLabel) case=\(routingCase.label) "
                        + "selected=\(result.selected.sorted()) required=\(routingCase.required.sorted()) "
                        + "allowed=\(routingCase.allowed.sorted())"
                )
            }
            scores[descriptionLabel] = (coverage, unnecessary)
            print(
                "ROUTING_SCORE description=\(descriptionLabel) coverage=\(coverage) "
                    + "unnecessary=\(unnecessary)"
            )
        }

        let defensive = try #require(scores["defensive"])
        let evidenceOriented = try #require(scores["evidence-oriented"])
        #expect(evidenceOriented.coverage >= defensive.coverage)
        #expect(evidenceOriented.unnecessary <= defensive.unnecessary)
    }

    private func route(
        prompt: String,
        model: String,
        provider: OllamaProvider,
        tools: [ToolDefinition],
        routingCase: RoutingCase
    ) async throws -> RoutingResult {
        let request = ModelRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: LLMCoreSystemPrompt.current),
                ChatMessage(role: .user, content: prompt)
            ],
            tools: tools,
            think: false,
            keepAlive: "30m",
            options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 384)
        )
        let stream = try await provider.stream(request)
        var selected = Set<String>()
        for try await event in stream {
            if case .toolCalls(let calls) = event {
                selected.formUnion(calls.map(\.function.name))
            }
        }
        return RoutingResult(
            selected: selected,
            requiredCoverage: routingCase.required.intersection(selected).count,
            unnecessaryCalls: selected.subtracting(routingCase.allowed).count
        )
    }
}

private actor RoutingWorker: ExecutionWorkerServing {
    func handle(_ request: ExecutionWorkerRequest) async -> ExecutionWorkerResponse {
        .failure(
            requestID: request.requestID,
            code: "routing_eval_only",
            message: "Routing eval does not execute tools."
        )
    }

    func shutdown() async -> Bool { true }
}
