import Foundation
import LLMCore
import Testing
@testable import Private_AI

@Suite("Generation Metrics")
struct GenerationMetricsTests {
    @Test("shows a stable placeholder before generation")
    func idleMetrics() {
        #expect(GenerationMetrics().ttftSeconds == nil)
        #expect(GenerationMetrics().liveTokensPerSecond == nil)
    }

    @Test("shows a ticking TTFT before the first token")
    func waitingForFirstToken() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()

        metrics.start(at: start)

        #expect(
            metrics.elapsedToFirstOutput(at: start.addingTimeInterval(1.25)) == 1.25
        )
    }

    @Test("stops TTFT when a run fails before producing text")
    func failedBeforeFirstToken() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()

        metrics.start(at: start)
        metrics.stop(at: start.addingTimeInterval(5))

        #expect(metrics.elapsedToFirstOutput(at: start.addingTimeInterval(30)) == 5)
    }

    @Test("shows user-perceived TTFT and estimated live token speed")
    func liveMetrics() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()

        metrics.start(at: start)
        metrics.recordText("12345678", at: start.addingTimeInterval(2))
        metrics.recordText("12345678", at: start.addingTimeInterval(3))

        #expect(metrics.ttftSeconds == 2)
        #expect(metrics.liveTokensPerSecond == 2)
    }

    @Test("thinking contributes to speed and first output before the answer")
    func thinkingMetrics() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()
        metrics.start(at: start)
        metrics.recordThinking("Reason", at: start.addingTimeInterval(1))
        metrics.recordThinking("ing", at: start.addingTimeInterval(2))
        #expect(metrics.ttftSeconds == 1)
        #expect(metrics.liveTokensPerSecond == 2)
        #expect(metrics.firstAnswerSeconds == nil)
        #expect(metrics.receivedChunkCount == 2)
        metrics.recordText("Answer", at: start.addingTimeInterval(3))
        #expect(metrics.ttftSeconds == 1)
        #expect(metrics.firstAnswerSeconds == 3)
        #expect(metrics.thinkingCharacterCount == 9)
        #expect(metrics.estimatedTokensPerSecond(at: start.addingTimeInterval(6)) == 0)
    }

    @Test("counts empty deltas as no output and accumulates actual provider usage")
    func usageMetrics() {
        var metrics = GenerationMetrics()
        metrics.start()
        metrics.recordThinking("")
        metrics.recordText("")
        #expect(metrics.firstOutputAt == nil)
        #expect(!metrics.hasLoadDuration)
        #expect(!metrics.hasPromptDuration)
        #expect(metrics.completedRequestCount == 0)
        metrics.recordUsage(ModelUsage(
            loadDurationNanoseconds: 500_000_000,
            promptTokenCount: 1_000,
            promptDurationNanoseconds: 2_000_000_000,
            outputTokenCount: 40
        ))
        metrics.recordUsage(ModelUsage(promptTokenCount: 20, outputTokenCount: 5))
        #expect(metrics.promptTokenCount == 1_020)
        #expect(metrics.outputTokenCount == 45)
        #expect(metrics.promptSeconds == 2)
        #expect(metrics.loadSeconds == 0.5)
        #expect(metrics.hasLoadDuration)
        #expect(metrics.hasPromptDuration)
        #expect(metrics.completedRequestCount == 2)
    }

    @Test("replaces the live estimate with Ollama evaluation speed")
    func finalMetrics() {
        var metrics = GenerationMetrics()
        metrics.start(at: Date(timeIntervalSince1970: 1_000))
        metrics.recordText("response", at: Date(timeIntervalSince1970: 1_001))
        metrics.finish(performance: AgentPerformance(
            timeToFirstEventSeconds: 0.5,
            timeToFirstTextSeconds: 1,
            totalSeconds: 3,
            modelRequestCount: 1,
            toolCallCount: 0,
            modelUsage: [ModelUsage(
                outputTokenCount: 40,
                outputDurationNanoseconds: 2_000_000_000
            )]
        ))

        #expect(metrics.ttftSeconds == 1)
        #expect(metrics.finalTokensPerSecond == 20)
    }
}