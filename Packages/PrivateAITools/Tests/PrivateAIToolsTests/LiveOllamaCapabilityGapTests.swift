import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

/// Real model-driven E2E probes across the common ChatGPT question categories.
///
/// Each test runs the actual qwen3.8 model through the agent loop, exercises any
/// tools the category needs, and prints the ground-truth executor result next to
/// the model's final answer. These are diagnostic capability probes: they surface
/// what PrivateAI can and cannot do today so gaps are evidence-based, not inferred.
@Suite(
    "Live Ollama Capability Gap Probe",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
)
struct LiveOllamaCapabilityGapTests {
    private static let model = "qwen3.8:latest"

    private func makeRuntime(
        tools: [any LLMTool],
        think: Bool = false,
        maxRounds: Int = 4,
        numPredict: Int = 512
    ) throws -> AgentRuntime {
        AgentRuntime(
            provider: try OllamaProvider(),
            toolRuntime: try ToolRuntime(tools: tools),
            configuration: AgentConfiguration(
                model: Self.model,
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: numPredict),
                think: think,
                maximumToolRounds: maxRounds,
                maximumToolCallsPerRound: 2,
                maximumToolCallsTotal: 6
            )
        )
    }

    private func report(_ label: String, _ result: AgentResult) {
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        print(
            "GAP_PROBE[\(label)] "
                + "tools=\(calls.map { $0.function.name }) "
                + "actions=\(calls.compactMap { $0.function.arguments["action"]?.stringValue }) "
                + "requests=\(result.performance.modelRequestCount) "
                + "toolCalls=\(result.performance.toolCallCount) "
                + "total=\(String(format: "%.1f", result.performance.totalSeconds))s"
        )
        print("GAP_ANSWER[\(label)] \(result.text)")
    }

    // MARK: - Category 1: General knowledge Q&A (pure model)

    @Test("1 general knowledge: explains a concept without tools")
    func generalKnowledge() async throws {
        let runtime = try makeRuntime(tools: [])
        let result = try await runtime.run(
            prompt: "用一段话解释什么是光合作用，并说明它为什么对地球生态系统重要。"
        )
        report("general", result)
        #expect(result.performance.toolCallCount == 0)
        #expect(result.text.count > 40)
        #expect(result.text.contains("光合") || result.text.localizedCaseInsensitiveContains("photosynth"))
    }

    // MARK: - Category 2: Coding help (pure model)

    @Test("2 coding: writes a correct function")
    func codingHelp() async throws {
        let runtime = try makeRuntime(tools: [])
        let result = try await runtime.run(
            prompt: "Write a Python function `is_palindrome(s: str) -> bool` that ignores case and non-alphanumeric characters. Return only the code."
        )
        report("coding", result)
        #expect(result.performance.toolCallCount == 0)
        #expect(result.text.contains("def is_palindrome"))
    }

    // MARK: - Category 3: Math / reasoning (pure model, thinking on)

    @Test("3 math: solves a multi-step arithmetic word problem")
    func mathReasoning() async throws {
        let runtime = try makeRuntime(tools: [], think: true, numPredict: 1_024)
        let result = try await runtime.run(
            prompt: "一件商品原价 240 元，先打 8 折，再在此基础上减 15 元，最后加收 10% 的税。最终价格是多少元？只需给出最终数字。"
        )
        report("math", result)
        // 240*0.8=192; 192-15=177; 177*1.1=194.7
        #expect(result.text.contains("194.7") || result.text.contains("194.70"))
    }

    // MARK: - Category 4: Creative writing (pure model)

    @Test("4 writing: produces a short structured piece on request")
    func creativeWriting() async throws {
        let runtime = try makeRuntime(tools: [])
        let result = try await runtime.run(
            prompt: "写一首关于秋天的四行小诗，每行都要押韵。"
        )
        report("writing", result)
        #expect(result.performance.toolCallCount == 0)
        #expect(result.text.count > 10)
    }

    // MARK: - Category 5: Translation (pure model)

    @Test("5 translation: translates EN->ZH accurately")
    func translation() async throws {
        let runtime = try makeRuntime(tools: [])
        let result = try await runtime.run(
            prompt: "Translate this sentence into Simplified Chinese, output only the translation: \"The quick brown fox jumps over the lazy dog.\""
        )
        report("translation", result)
        #expect(result.performance.toolCallCount == 0)
        #expect(result.text.contains("狐") && result.text.contains("狗"))
    }

    // MARK: - Category 6: Summarization (pure model)

    @Test("6 summarization: condenses a supplied passage")
    func summarization() async throws {
        let passage = """
        大型语言模型通过在海量文本上训练来学习语言规律。它们可以生成文本、回答问题、\
        翻译语言和编写代码。但它们也存在局限：可能产生看似合理却错误的内容（幻觉），\
        知识有截止日期，并且无法直接访问实时信息或本地设备，除非配备相应的工具。
        """
        let runtime = try makeRuntime(tools: [])
        let result = try await runtime.run(
            prompt: "用一句话总结下面这段话的核心观点：\n\n\(passage)"
        )
        report("summary", result)
        #expect(result.performance.toolCallCount == 0)
        #expect(result.text.count > 10)
    }

    // MARK: - Category 7: Real-time web information (web tool)

    @Test("7 realtime web: fetches current public info via web search")
    func realtimeWeb() async throws {
        let runtime = try makeRuntime(tools: [WebTool()], maxRounds: 4)
        let result = try await runtime.run(
            prompt: "搜索当前公开网络，查出 Swift 编程语言的官方网站网址，并报告它的网址。"
        )
        report("web", result)
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        #expect(calls.contains { $0.function.name == "web" })
        #expect(result.text.localizedCaseInsensitiveContains("swift.org"))
    }

    // MARK: - Category 8: Local file tasks (local_resources tool)

    @Test("8 local files: reads and summarizes a real local file")
    func localFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gap-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let secret = "紫色犀牛在月光下跳舞"
        let fileURL = tempDir.appendingPathComponent("note.txt")
        try "会议纪要：\(secret)。请勿外传。".write(to: fileURL, atomically: true, encoding: .utf8)

        // Unrestricted config (matches production ChatAgent): no authorizedRoots, any absolute path.
        let runtime = try makeRuntime(
            tools: [LocalResourcesTool(authorizedRoots: [])],
            maxRounds: 4
        )
        let result = try await runtime.run(
            prompt: "读取文件 \(fileURL.path)，并告诉我文件里提到了什么动物在做什么。"
        )
        report("localfile", result)
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        #expect(calls.contains { $0.function.name == "local_resources" })
        #expect(result.text.contains("犀牛"))
    }

    // MARK: - Category 9: Device / system query (apple_services tool)

    @Test("9 device query: reports the real platform via apple_services")
    func deviceQuery() async throws {
        let runtime = try makeRuntime(tools: [AppleServicesTool()], maxRounds: 3)
        let result = try await runtime.run(
            prompt: "这台电脑运行的是什么操作系统？请检查这台电脑后回答。"
        )
        report("device", result)
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        #expect(calls.contains { $0.function.name == "apple_services" })
        #expect(result.text.localizedCaseInsensitiveContains("macos") || result.text.contains("mac"))
    }
}
