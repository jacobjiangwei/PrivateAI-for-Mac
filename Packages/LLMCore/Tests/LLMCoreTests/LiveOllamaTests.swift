import AppKit
import Foundation
import Testing
@testable import LLMCore

@Suite(
    "Live Ollama",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
)
struct LiveOllamaTests {
    @Test("warm model returns first text within five seconds")
    func warmTTFT() async throws {
        let provider = try OllamaProvider()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(
                model: benchmarkModel,
                keepAlive: "30m",
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 64)
            )
        )

        let warmup = try await runtime.warmUp()
        let result = try await runtime.run(prompt: "Why is the sky blue?")

        #expect(!result.text.isEmpty)
        let ttft = try #require(result.performance.timeToFirstTextSeconds)
        print(
            "PERF warmup=\(warmup.elapsedSeconds)s "
                + "provider_load=\(warmup.providerLoadSeconds ?? -1)s "
                + "ttft=\(ttft)s total=\(result.performance.totalSeconds)s"
        )
        #expect(ttft < 5, "Warm TTFT was \(ttft) seconds")
    }

    @Test("keep-alive preserves fast TTFT after ten seconds of user input")
    func keepAliveAfterTypingDelay() async throws {
        let provider = try OllamaProvider()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [TestWebTool()]),
            configuration: AgentConfiguration(
                model: benchmarkModel,
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 64)
            )
        )
        let clock = ContinuousClock()

        try await provider.unload(model: benchmarkModel)
        let warmup = try await runtime.warmUp()
        let idleStart = clock.now
        try await clock.sleep(until: idleStart.advanced(by: .seconds(10)))
        let idleSeconds = durationSeconds(idleStart.duration(to: clock.now))
        let result = try await runtime.run(
            prompt: "What is the capital of France? Reply with the city name and one sentence explaining its role."
        )

        let ttft = try #require(result.performance.timeToFirstTextSeconds)
        let loadSeconds = try #require(
            result.performance.modelUsage.first?.loadDurationNanoseconds
        ).seconds
        let usage = try #require(result.performance.modelUsage.first)
        let promptSeconds = try #require(usage.promptDurationNanoseconds).seconds
        let outputSeconds = try #require(usage.outputDurationNanoseconds).seconds
        let outputTokens = try #require(usage.outputTokenCount)
        let tokensPerSecond = outputSeconds > 0 ? Double(outputTokens) / outputSeconds : 0
        print(
            "KEEPALIVE unloaded=true warmup=\(warmup.elapsedSeconds)s "
                + "prefix_tokens=\(warmup.prefixPromptTokenCount ?? -1) "
                + "prefix=\(warmup.prefixPromptSeconds ?? -1)s "
                + "idle=\(idleSeconds)s load=\(loadSeconds)s "
                + "prompt_tokens=\(usage.promptTokenCount ?? -1) prompt=\(promptSeconds)s "
                + "ttft=\(ttft)s output_tokens=\(outputTokens) "
                + "output=\(outputSeconds)s tok_per_s=\(tokensPerSecond) "
                + "total=\(result.performance.totalSeconds)s "
                + "answer=\(result.text.debugDescription)"
        )

        #expect(warmup.elapsedSeconds >= 0.1, "Warmup did not perform observable model loading")
        #expect(idleSeconds >= 10)
        #expect(warmup.prefixPromptTokenCount ?? 0 >= 500)
        #expect(result.text.localizedCaseInsensitiveContains("Paris"))
        #expect(loadSeconds < 1, "Ollama reloaded the model for \(loadSeconds) seconds")
        #expect(ttft < 5, "TTFT after the typing delay was \(ttft) seconds")
    }

    @Test("measures repeated stable-prefix prompt evaluation")
    func stablePrefixExperiment() async throws {
        let provider = try OllamaProvider()
        let options = ModelOptions(numContext: 8_192, temperature: 0, numPredict: 64)
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [TestWebTool()]),
            configuration: AgentConfiguration(
                model: benchmarkModel,
                keepAlive: "30m",
                options: options
            )
        )
        let prompt = "What is the capital of France? Reply with the city name and one sentence explaining its role."
        var baselinePromptSamples: [Double] = []
        var baselineTTFTSamples: [Double] = []
        var prewarmedPromptSamples: [Double] = []
        var prewarmedTTFTSamples: [Double] = []

        for _ in 0..<3 {
            try await provider.unload(model: benchmarkModel)
            _ = try await provider.warmUp(
                model: benchmarkModel,
                keepAlive: "30m",
                options: options
            )
            let baseline = try await runtime.run(prompt: prompt)
            let baselineUsage = try #require(baseline.performance.modelUsage.first)
            baselinePromptSamples.append(
                try #require(baselineUsage.promptDurationNanoseconds).seconds
            )
            baselineTTFTSamples.append(
                try #require(baseline.performance.timeToFirstTextSeconds)
            )
            #expect(baseline.text.localizedCaseInsensitiveContains("Paris"))

            try await provider.unload(model: benchmarkModel)
            _ = try await runtime.warmUp()
            let prewarmed = try await runtime.run(prompt: prompt)
            let prewarmedUsage = try #require(prewarmed.performance.modelUsage.first)
            prewarmedPromptSamples.append(
                try #require(prewarmedUsage.promptDurationNanoseconds).seconds
            )
            prewarmedTTFTSamples.append(
                try #require(prewarmed.performance.timeToFirstTextSeconds)
            )
            #expect(prewarmed.text.localizedCaseInsensitiveContains("Paris"))
        }

        let baselinePromptMedian = median(baselinePromptSamples)
        let baselineTTFTMedian = median(baselineTTFTSamples)
        let prewarmedPromptMedian = median(prewarmedPromptSamples)
        let prewarmedTTFTMedian = median(prewarmedTTFTSamples)
        print(
            "PREFIX_AB baseline_prompt_samples=\(baselinePromptSamples) "
                + "prewarmed_prompt_samples=\(prewarmedPromptSamples) "
                + "baseline_ttft_samples=\(baselineTTFTSamples) "
                + "prewarmed_ttft_samples=\(prewarmedTTFTSamples) "
                + "baseline_prompt_median=\(baselinePromptMedian)s "
                + "prewarmed_prompt_median=\(prewarmedPromptMedian)s "
                + "baseline_ttft_median=\(baselineTTFTMedian)s "
                + "prewarmed_ttft_median=\(prewarmedTTFTMedian)s "
                + "prompt_ratio=\(prewarmedPromptMedian / baselinePromptMedian) "
                + "ttft_ratio=\(prewarmedTTFTMedian / baselineTTFTMedian)"
        )

        #expect(baselinePromptSamples.count == 3)
        #expect(prewarmedPromptSamples.count == 3)
    }

    @Test("model autonomously uses the generic web capability for current weather")
    func webToolCall() async throws {
        let provider = try OllamaProvider()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [TestWebTool()]),
            configuration: AgentConfiguration(
                model: benchmarkModel,
                keepAlive: "30m",
                options: ModelOptions(numContext: 4_096, temperature: 0, numPredict: 256),
                maximumToolCallsPerRound: 1,
                maximumToolCallsTotal: 1
            )
        )

        _ = try await runtime.warmUp()
        let events = EventRecorder()
        let result = try await runtime.run(prompt: "苏州现在天气怎么样？") { event in
            await events.append(event)
        }
        let timedEvents = await events.entries
        let recordedEvents = timedEvents.map(\.event)

        for event in recordedEvents {
            switch event {
            case .toolStarted(let name, let arguments):
                print("TOOL_START name=\(name) arguments=\(arguments)")
            case .toolFinished(let execution):
                print(
                    "TOOL_FINISH name=\(execution.name) "
                        + "succeeded=\(execution.succeeded) content=\(execution.content)"
                )
            default:
                break
            }
        }
        print(
            "TOOL requests=\(result.performance.modelRequestCount) "
                + "calls=\(result.performance.toolCallCount) "
                + "total=\(result.performance.totalSeconds)s"
        )
        let startedCalls = recordedEvents.compactMap { event -> (String, [String: JSONValue])? in
            guard case .toolStarted(let name, let arguments) = event else {
                return nil
            }
            return (name, arguments)
        }
        let finishedCalls = recordedEvents.compactMap { event -> ToolExecution? in
            guard case .toolFinished(let execution) = event else {
                return nil
            }
            return execution
        }
        let toolStartedAt = try #require(
            timedEvents.first { timedEvent in
                if case .toolStarted = timedEvent.event {
                    return true
                }
                return false
            }?.elapsedSeconds
        )
        let toolFinishedAt = try #require(
            timedEvents.first { timedEvent in
                if case .toolFinished = timedEvent.event {
                    return true
                }
                return false
            }?.elapsedSeconds
        )
        let firstTextAt = try #require(
            timedEvents.first { timedEvent in
                if case .text = timedEvent.event {
                    return true
                }
                return false
            }?.elapsedSeconds
        )
        let firstUsage = try #require(result.performance.modelUsage.first)
        let finalUsage = try #require(result.performance.modelUsage.last)
        print(
            "TOOL_PERF route_to_call=\(toolStartedAt)s "
                + "tool_execution=\(toolFinishedAt - toolStartedAt)s "
                + "result_to_first_text=\(firstTextAt - toolFinishedAt)s "
                + "final_first_text=\(firstTextAt)s "
                + "round1_prompt=\((firstUsage.promptDurationNanoseconds ?? 0).seconds)s "
                + "round2_prompt=\((finalUsage.promptDurationNanoseconds ?? 0).seconds)s"
        )

        #expect(!result.text.isEmpty)
        #expect(result.performance.modelRequestCount == 2)
        #expect(result.performance.toolCallCount == 1)
        #expect(startedCalls.count == 1)
        #expect(startedCalls.first?.0 == "web")
        #expect(startedCalls.first?.1["action"] == .string("search"))
        #expect(startedCalls.first?.1["query"]?.stringValue?.isEmpty == false)
        #expect(finishedCalls.count == 1)
        #expect(finishedCalls.first?.name == "web")
        #expect(finishedCalls.first?.succeeded == true)
    }

    @Test("model reads a real image returned by a Tool")
    func imageToolResultLoop() async throws {
        let provider = try OllamaProvider()
        let capabilities = try await provider.capabilities(for: benchmarkModel)
        #expect(capabilities.supportsVisionToolUse)
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [VisualFixtureTool()]),
            configuration: AgentConfiguration(
                model: benchmarkModel,
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 256),
                maximumToolCallsPerRound: 1,
                maximumToolCallsTotal: 1,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(
            prompt: "Use the visual_fixture tool. Inspect the returned image pixels and report the exact verification code printed inside the red rectangle."
        )
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }

        #expect(calls.map(\.function.name) == ["visual_fixture"])
        #expect(result.messages.allSatisfy { $0.images.isEmpty })
        #expect(result.text.contains("SCARLET-7391"))
    }
}

private actor EventRecorder {
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private(set) var entries: [TimedAgentEvent] = []

    init() {
        self.start = clock.now
    }

    func append(_ event: AgentEvent) {
        entries.append(
            TimedAgentEvent(
                event: event,
                elapsedSeconds: durationSeconds(start.duration(to: clock.now))
            )
        )
    }
}

private struct TimedAgentEvent: Sendable {
    let event: AgentEvent
    let elapsedSeconds: Double
}

private struct TestWebTool: LLMTool {
    let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "web",
            description: "Search current public information. This is a test fixture.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("search")])
                    ]),
                    "query": .object(["type": .string("string")])
                ]),
                "required": .array([.string("action"), .string("query")])
            ])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{\"results\":[{\"title\":\"Suzhou current weather\",\"snippet\":\"Suzhou, Jiangsu: 28 C, partly cloudy, observed now\"}]}"
    }
}

private struct VisualFixtureTool: LLMTool {
    let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "visual_fixture",
            description: "Return the screenshot that must be inspected to answer the request.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{}"
    }

    func executeOutput(arguments: [String: JSONValue]) async throws -> ToolOutput {
        let width = 640
        let height = 360
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw VisualFixtureError.imageUnavailable
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemRed.setFill()
        NSRect(x: 100, y: 100, width: 440, height: 160).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 44),
            .foregroundColor: NSColor.white
        ]
        NSString(string: "SCARLET-7391").draw(
            at: NSPoint(x: 165, y: 155),
            withAttributes: attributes
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VisualFixtureError.imageUnavailable
        }
        return ToolOutput(
            content: #"{"frame_id":"visual-fixture","instruction":"Read the verification code from the image pixels."}"#,
            images: [ModelImage(data: png, width: width, height: height)]
        )
    }
}

private enum VisualFixtureError: Error {
    case imageUnavailable
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private extension UInt64 {
    var seconds: Double {
        Double(self) / 1_000_000_000
    }
}

private let benchmarkModel = "qwen3.8:latest"
