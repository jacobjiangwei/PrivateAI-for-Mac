import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite(
    "Live Ollama Web Tool",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
)
struct LiveOllamaWebToolTests {
    @Test("model invokes the real web search and uses its result")
    func searchThroughAgentLoop() async throws {
        let runtime = AgentRuntime(
            provider: try OllamaProvider(),
            toolRuntime: try ToolRuntime(tools: [WebTool()]),
            configuration: AgentConfiguration(
                model: "qwen3.8:latest",
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 256),
                maximumToolCallsPerRound: 2,
                maximumToolCallsTotal: 2
            )
        )

        let warmup = try await runtime.warmUp()
        let result = try await runtime.run(
            prompt: "Search the current public web for the official Swift programming language website. Report its URL and page title."
        )
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        let toolMessages = result.messages.filter { $0.role == .tool }
        print(
            "REAL_WEB_AGENT calls=\(calls.map { $0.function.name }) "
                + "prefix_tokens=\(warmup.prefixPromptTokenCount ?? -1) "
                + "requests=\(result.performance.modelRequestCount) "
                + "total=\(result.performance.totalSeconds)s"
        )

        #expect((1...2).contains(calls.count))
        #expect(calls.allSatisfy { $0.function.name == "web" })
        #expect(calls.contains { $0.function.arguments["action"] == .string("search") })
        #expect(result.performance.toolCallCount == calls.count)
        #expect(result.performance.modelRequestCount == 2)
        #expect(toolMessages.count == calls.count)
        #expect(toolMessages.contains { $0.content.contains("swift.org") })
        #expect(result.text.localizedCaseInsensitiveContains("swift.org"))
    }
}