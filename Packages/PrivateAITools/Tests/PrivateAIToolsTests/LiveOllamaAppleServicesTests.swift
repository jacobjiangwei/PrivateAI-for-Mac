import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite(
    "Live Ollama Apple Services",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
)
struct LiveOllamaAppleServicesTests {
    @Test("model reports the real Mac platform and processor count")
    func deviceInformationThroughAgentLoop() async throws {
        let runtime = AgentRuntime(
            provider: try OllamaProvider(),
            toolRuntime: try ToolRuntime(tools: [AppleServicesTool(), WebTool()]),
            configuration: AgentConfiguration(
                model: "qwen3.8:latest",
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 256),
                maximumToolCallsPerRound: 1,
                maximumToolCallsTotal: 1
            )
        )

        let warmup = try await runtime.warmUp()
        let result = try await runtime.run(
            prompt: "Is this computer running macOS, and how many processors does it report? Inspect the computer and answer both questions."
        )
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        let toolMessages = result.messages.filter { $0.role == .tool }
        print(
            "REAL_APPLE_AGENT calls=\(calls.map { $0.function.name }) "
                + "actions=\(calls.compactMap { $0.function.arguments["action"]?.stringValue }) "
                + "prefix_tokens=\(warmup.prefixPromptTokenCount ?? -1) "
                + "requests=\(result.performance.modelRequestCount) "
                + "total=\(result.performance.totalSeconds)s"
        )

        #expect(calls.count == 1)
        #expect(calls.first?.function.name == "apple_services")
        #expect(calls.first?.function.arguments["action"] == .string("device_info"))
        #expect(toolMessages.count == 1)
        let toolContent = try #require(toolMessages.first?.content)
        let toolResult = try JSONDecoder().decode(JSONValue.self, from: Data(toolContent.utf8))
        let toolObject = try #require(toolResult.objectValue)
        let platform = try #require(toolObject["platform"]?.stringValue)
        let processorCount = try #require(toolObject["processor_count"]?.integerValue)
        print(
            "REAL_APPLE_RESULT platform=\(platform) "
                + "processor_count=\(processorCount) "
                + "answer=\(result.text.debugDescription)"
        )

        #expect(platform == "macOS")
        #expect(result.text.localizedLowercase.contains(platform.localizedLowercase))
        #expect(result.text.contains(String(processorCount)))
        #expect(result.performance.modelRequestCount == 2)
    }
}