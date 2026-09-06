import Foundation
import Testing
@testable import LLMCore

@Suite("Agent Runtime")
struct AgentRuntimeTests {
    @Test("encodes permanent Ollama keep alive as a JSON number")
    func permanentKeepAliveEncoding() throws {
        let request = ModelRequest(
            model: "fixture",
            messages: [ChatMessage(role: .user, content: "Hello")],
            keepAlive: "-1"
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["keep_alive"] as? Int == -1)
    }

    @Test("automatically warms once before the first chat request")
    func automaticallyWarmsOnce() async throws {
        let provider = ScriptedProvider(responses: [
            [.completed(ModelUsage(promptTokenCount: 42))],
            [.text("First answer"), .completed(ModelUsage())],
            [.text("Second answer"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture")
        )

        let first = try await runtime.run(prompt: "First question")
        let second = try await runtime.run(prompt: "Second question")
        let requests = await provider.recordedRequests

        #expect(first.text == "First answer")
        #expect(second.text == "Second answer")
        #expect(await provider.warmupCount == 1)
        #expect(requests.count == 3)
        #expect(requests[0].messages.last?.content.contains("stable instruction prefix") == true)
        #expect(requests[1].messages.last?.content == "First question")
        #expect(requests[2].messages.last?.content == "Second question")
    }

    @Test("executes a model-selected tool and returns its result to the model")
    func executesToolLoop() async throws {
        let call = ToolCall(
            function: ToolFunctionCall(
                name: "web",
                arguments: [
                    "action": .string("search"),
                    "query": .string("Suzhou current weather")
                ]
            )
        )
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("Suzhou is 24 C and clear."), .completed(ModelUsage())]
        ])
        let tools = try ToolRuntime(tools: [FixtureTool()])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: tools,
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "What is the weather in Suzhou?")
        let requests = await provider.recordedRequests

        #expect(result.text == "Suzhou is 24 C and clear.")
        #expect(result.performance.modelRequestCount == 2)
        #expect(result.performance.toolCallCount == 1)
        #expect(requests.count == 2)
        #expect(requests[0].tools.map(\.function.name) == ["web"])
        #expect(requests[1].messages.last?.role == .tool)
        #expect(requests[1].messages.last?.toolName == "web")
        #expect(requests[1].messages.last?.content.contains("24") == true)
    }

    @Test("returns Tool images to the next model request")
    func returnsToolImagesToModel() async throws {
        let call = ToolCall(function: ToolFunctionCall(
            name: "vision_probe",
            arguments: [:]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("Saw the frame."), .completed(ModelUsage())]
        ])
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [ImageFixtureTool(image: image)]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Inspect the frame")
        let requests = await provider.recordedRequests

        #expect(requests[1].messages.last?.role == .tool)
        #expect(requests[1].messages.last?.images.map(\.data) == [image])
    }

    @Test("keeps only the latest Tool image in later model requests")
    func keepsOnlyLatestToolImage() async throws {
        let call = ToolCall(function: ToolFunctionCall(
            name: "vision_sequence",
            arguments: [:]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = SequentialImageFixtureTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Inspect two frames")
        let requests = await provider.recordedRequests
        let toolMessages = requests[2].messages.filter { $0.role == .tool }

        #expect(toolMessages.count == 2)
        #expect(toolMessages[0].images.isEmpty)
        #expect(toolMessages[1].images.map(\.data) == [Data([2])])
    }

    @Test("rejects an exclusive Tool call with sibling calls before execution")
    func rejectsExclusiveToolSiblingCalls() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(name: "exclusive_probe", arguments: [:])),
            ToolCall(function: ToolFunctionCall(name: "web", arguments: [:]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())]
        ])
        let exclusive = ExclusiveRecordingTool()
        let regular = RecordingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [exclusive, regular]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        await #expect(throws: AgentRuntimeError.exclusiveToolCallConflict("exclusive_probe")) {
            try await runtime.run(prompt: "Act twice")
        }
        #expect(await exclusive.executionCount == 0)
        #expect(await regular.executionCount == 0)
    }

    @Test("corrects a thinking-only final round without tools or thinking")
    func correctsThinkingOnlyFinalResponse() async throws {
        let call = ToolCall(function: ToolFunctionCall(
            name: "web",
            arguments: [
                "action": .string("search"),
                "query": .string("measured result")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [
                .thinking(String(repeating: "analysis ", count: 256)),
                .completed(ModelUsage(outputTokenCount: 2_048))
            ],
            [.text("Final answer from real evidence."), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [FixtureTool()]),
            configuration: AgentConfiguration(
                model: "fixture",
                think: true,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Use the measured result")
        let requests = await provider.recordedRequests

        #expect(result.text == "Final answer from real evidence.")
        #expect(result.performance.modelRequestCount == 3)
        #expect(requests[1].think)
        #expect(requests[2].tools.isEmpty)
        #expect(!requests[2].think)
        #expect(requests[2].messages.contains {
            $0.role == .user && $0.content.contains("complete user-visible final answer")
        })
        #expect(requests[2].messages.contains {
            $0.role == .tool && $0.content.contains("temperature_celsius")
        })
    }

    @Test("corrects a nonempty final answer truncated by the model limit")
    func correctsTruncatedFinalResponse() async throws {
        let call = ToolCall(function: ToolFunctionCall(
            name: "web",
            arguments: [
                "action": .string("search"),
                "query": .string("measured result")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [
                .text("Partial table without the requested conclusion"),
                .completed(ModelUsage(
                    outputTokenCount: 2_048,
                    finishReason: "length"
                ))
            ],
            [.text("RESULT_PATH=/measured\nRESULT_BYTES=42"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [FixtureTool()]),
            configuration: AgentConfiguration(
                model: "fixture",
                think: true,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Return the measured result")
        let requests = await provider.recordedRequests

        #expect(result.text == "RESULT_PATH=/measured\nRESULT_BYTES=42")
        #expect(requests.count == 3)
        #expect(requests[2].tools.isEmpty)
        #expect(!requests[2].think)
        #expect(requests[2].messages.contains {
            $0.role == .assistant
                && $0.content == "Partial table without the requested conclusion"
        })
    }

    @Test("fails instead of accepting a second truncated final response")
    func rejectsRepeatedTruncatedFinalResponse() async throws {
        let provider = ScriptedProvider(responses: [
            [
                .text("First partial answer"),
                .completed(ModelUsage(outputTokenCount: 2_048, finishReason: "length"))
            ],
            [
                .text("Second partial answer"),
                .completed(ModelUsage(outputTokenCount: 2_048, finishReason: "length"))
            ]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(
                model: "fixture",
                think: true,
                automaticallyWarmsUp: false
            )
        )

        await #expect(throws: AgentRuntimeError.incompleteFinalResponse) {
            try await runtime.run(prompt: "Answer completely")
        }
    }

    @Test("fails instead of completing with an empty corrected response")
    func rejectsEmptyCorrectedFinalResponse() async throws {
        let provider = ScriptedProvider(responses: [
            [.thinking("analysis"), .completed(ModelUsage())],
            [.completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(
                model: "fixture",
                think: true,
                automaticallyWarmsUp: false
            )
        )

        await #expect(throws: AgentRuntimeError.emptyFinalResponse) {
            try await runtime.run(prompt: "Answer visibly")
        }
        let requests = await provider.recordedRequests
        #expect(requests.count == 2)
        #expect(!requests[1].think)
    }

    @Test("returns unknown tool failures to the model without executing them")
    func containsUnknownTool() async throws {
        let call = ToolCall(
            function: ToolFunctionCall(name: "unregistered", arguments: [:])
        )
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("That tool is unavailable."), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "Use an unavailable tool")
        let requests = await provider.recordedRequests

        #expect(result.text == "That tool is unavailable.")
        #expect(requests[1].messages.last?.content.contains("unknown_tool") == true)
    }

    @Test("rejects empty prompts before contacting the provider")
    func rejectsEmptyPrompt() async throws {
        let provider = ScriptedProvider(responses: [])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        await #expect(throws: AgentRuntimeError.emptyPrompt) {
            try await runtime.run(prompt: "  \n")
        }
        #expect(await provider.recordedRequests.isEmpty)
    }

    @Test("cleans up tools when a provider request fails")
    func cleansUpToolsOnFailure() async throws {
        let tool = CleanupProbeTool()
        let runtime = AgentRuntime(
            provider: FailingProvider(),
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                automaticallyWarmsUp: false
            )
        )

        await #expect(throws: FixtureProviderError.failed) {
            try await runtime.run(prompt: "Trigger a provider failure")
        }
        #expect(await tool.cleanupCount == 1)
    }

    @Test("honors cancellation while final tool cleanup is in progress")
    func cancellationDuringFinalCleanup() async throws {
        let tool = BlockingCleanupTool()
        let provider = ScriptedProvider(responses: [
            [.text("Do not commit this answer"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                automaticallyWarmsUp: false
            )
        )
        let run = Task {
            try await runtime.run(prompt: "Wait for cancellation")
        }
        await tool.waitUntilCleanupStarted()

        run.cancel()
        await tool.releaseCleanup()

        await #expect(throws: CancellationError.self) {
            try await run.value
        }
    }

    @Test("includes prior conversation messages before the new user prompt")
    func includesConversationHistory() async throws {
        let provider = ScriptedProvider(responses: [
            [.text("Current answer"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )
        let history = [
            ChatMessage(role: .user, content: "Earlier question"),
            ChatMessage(role: .assistant, content: "Earlier answer")
        ]

        _ = try await runtime.run(prompt: "Current question", history: history)
        let request = try #require(await provider.recordedRequests.first)

        #expect(request.messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(request.messages.map(\.content) == [
            LLMCoreSystemPrompt.current,
            "Earlier question",
            "Earlier answer",
            "Current question"
        ])
    }

    @Test("rejects a tool-call batch before partially executing it")
    func enforcesToolCallBudget() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(name: "web", arguments: ["action": .string("search"), "query": .string("one")])),
            ToolCall(function: ToolFunctionCall(name: "web", arguments: ["action": .string("search"), "query": .string("two")]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())]
        ])
        let tool = RecordingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                maximumToolCallsPerRound: 1,
                maximumToolCallsTotal: 1,
                automaticallyWarmsUp: false
            )
        )

        await #expect(throws: AgentRuntimeError.toolCallLimitExceeded(perRound: 1, total: 1)) {
            try await runtime.run(prompt: "Search twice")
        }
        #expect(await tool.executionCount == 0)
    }

    @Test("default configuration does not impose a fixed tool-call quota")
    func defaultConfigurationAllowsMoreThanLegacyToolCallQuota() async throws {
        func calls(in range: Range<Int>) -> [ToolCall] {
            range.map { index in
                ToolCall(function: ToolFunctionCall(
                    name: "web",
                    arguments: [
                        "action": .string("search"),
                        "query": .string("query \(index)")
                    ]
                ))
            }
        }
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls(in: 0..<5)), .completed(ModelUsage())],
            [.toolCalls(calls(in: 5..<10)), .completed(ModelUsage())],
            [.text("Completed after ten calls."), .completed(ModelUsage())]
        ])
        let tool = RecordingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Research ten sources")

        #expect(result.text == "Completed after ten calls.")
        #expect(result.performance.toolCallCount == 10)
        #expect(await tool.executionCount == 10)
    }

    @Test("tool round limit finalizes without reporting a call budget")
    func toolRoundLimitUsesAccurateFinalizationInstruction() async throws {
        let call = ToolCall(function: ToolFunctionCall(
            name: "web",
            arguments: [
                "action": .string("search"),
                "query": .string("bounded research")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("Final answer from one round."), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [RecordingTool()]),
            configuration: AgentConfiguration(
                model: "fixture",
                maximumToolRounds: 1,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Research this")
        let requests = await provider.recordedRequests

        #expect(result.text == "Final answer from one round.")
        #expect(requests.count == 2)
        #expect(requests[1].tools.isEmpty)
        #expect(requests[1].messages.contains {
            $0.role == .user
                && $0.content.contains("tool-execution round limit")
                && !$0.content.contains("tool-call budget")
        })
    }

    @Test("finalizes instead of failing after exhausting the total tool budget")
    func finalizesAfterToolBudgetExhaustion() async throws {
        let calls = (0..<9).map { offset in
            ToolCall(function: ToolFunctionCall(
                name: "document_reader",
                arguments: ["offset": .number(Double(offset * 2_000))]
            ))
        }
        let provider = ScriptedProvider(responses:
            calls.map { [.toolCalls([$0]), .completed(ModelUsage())] }
                + [[.text("Bounded summary from eight chunks."), .completed(ModelUsage())]]
        )
        let tool = RecordingDocumentTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                maximumToolRounds: 12,
                maximumToolCallsPerRound: 4,
                maximumToolCallsTotal: 8,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Summarize the large document")
        let requests = await provider.recordedRequests

        #expect(result.text == "Bounded summary from eight chunks.")
        #expect(result.performance.toolCallCount == 8)
        #expect(await tool.executionCount == 8)
        #expect(requests.count == 10)
        #expect(!requests[8].tools.isEmpty)
        #expect(requests[9].tools.isEmpty)
        #expect(requests[9].messages.contains {
            $0.role == .user
                && $0.content.contains("Summarize the large document")
                && $0.content.contains("tool-call budget")
        })
    }

    @Test("corrects an oversized hallucinated batch during tool-free finalization")
    func correctsOversizedFinalizationBatch() async throws {
        let firstCall = ToolCall(function: ToolFunctionCall(name: "document_reader", arguments: [:]))
        let hallucinated = (0..<5).map { index in
            ToolCall(function: ToolFunctionCall(
                name: "document_reader",
                arguments: ["offset": .number(Double(index))]
            ))
        }
        let provider = ScriptedProvider(responses: [
            [.toolCalls([firstCall]), .completed(ModelUsage())],
            [.toolCalls(hallucinated), .completed(ModelUsage())],
            [.text("Final answer from gathered evidence."), .completed(ModelUsage())]
        ])
        let tool = RecordingDocumentTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                maximumToolRounds: 4,
                maximumToolCallsPerRound: 4,
                maximumToolCallsTotal: 1,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Summarize")

        #expect(result.text == "Final answer from gathered evidence.")
        #expect(await tool.executionCount == 1)
        #expect(result.performance.toolCallCount == 1)
    }

    @Test("lifecycle observations do not exhaust the work tool budget")
    func lifecycleCallsUseNoWorkBudget() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(
                name: "budgeted_job",
                arguments: ["action": .string("run")]
            )),
            ToolCall(function: ToolFunctionCall(
                name: "budgeted_job",
                arguments: ["action": .string("wait")]
            )),
            ToolCall(function: ToolFunctionCall(
                name: "budgeted_job",
                arguments: ["action": .string("wait")]
            ))
        ]
        let provider = ScriptedProvider(responses: calls.map {
            [.toolCalls([$0]), .completed(ModelUsage())]
        } + [[.text("Job completed."), .completed(ModelUsage())]])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [BudgetedJobTool()]),
            configuration: AgentConfiguration(
                model: "fixture",
                maximumToolRounds: 4,
                maximumToolCallsTotal: 1,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Run the long job")

        #expect(result.text == "Job completed.")
        #expect(result.performance.toolCallCount == 3)
    }

    @Test("executes tool calls from one model response concurrently")
    func executesParallelToolBatch() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(index: 0, name: "probe", arguments: ["value": .string("first")])),
            ToolCall(function: ToolFunctionCall(index: 1, name: "probe", arguments: ["value": .string("second")]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = ParallelProbeTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "Run both probes")
        let maximumConcurrency = await tool.maximumConcurrency
        let requests = await provider.recordedRequests

        #expect(result.text == "done")
        #expect(maximumConcurrency == 2)
        #expect(requests[1].messages.suffix(2).map(\.content) == ["first", "second"])
    }

    @Test("continues after two large concurrent Tool results")
    func boundsConcurrentToolEvidence() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(
                index: 0,
                name: "large_probe",
                arguments: ["value": .string("first")]
            )),
            ToolCall(function: ToolFunctionCall(
                index: 1,
                name: "large_probe",
                arguments: ["value": .string("second")]
            ))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("done from bounded evidence"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [LargeParallelProbeTool()]),
            configuration: AgentConfiguration(
                model: "fixture",
                options: ModelOptions(numContext: 8_192),
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Compare both large results")
        let requests = await provider.recordedRequests
        let toolMessages = requests[1].messages.filter { $0.role == .tool }

        #expect(result.text == "done from bounded evidence")
        #expect(toolMessages.count == 2)
        for message in toolMessages {
            let value = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(message.content.utf8)
            )
            #expect(value.objectValue?["output_truncated"] == .bool(true))
        }
        #expect(
            trimMessagesToBudget(requests[1].messages, budgetBytes: 14_745)
                .requiredBytesExceededBudget == false
        )
    }

    @Test("continues after two large serial Tool result batches")
    func boundsSerialToolEvidence() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(
                index: 0,
                name: "large_probe",
                arguments: ["value": .string("first")]
            )),
            ToolCall(function: ToolFunctionCall(
                index: 1,
                name: "large_probe",
                arguments: ["value": .string("second")]
            ))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("serial evidence bounded"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [
                LargeParallelProbeTool(concurrencySafe: false)
            ]),
            configuration: AgentConfiguration(
                model: "fixture",
                options: ModelOptions(numContext: 8_192),
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: "Compare serial large results")
        let requests = await provider.recordedRequests
        let toolMessages = requests[1].messages.filter { $0.role == .tool }

        #expect(result.text == "serial evidence bounded")
        #expect(toolMessages.count == 2)
        #expect(toolMessages.allSatisfy { $0.content.contains("output_truncated") })
        #expect(
            trimMessagesToBudget(requests[1].messages, budgetBytes: 14_745)
                .requiredBytesExceededBudget == false
        )
    }

    @Test("completes after search results followed by two large page fetches")
    func completesObservedWebSequence() async throws {
        func call(index: Int, action: String, value: String) -> ToolCall {
            ToolCall(function: ToolFunctionCall(
                index: index,
                name: "web_fixture",
                arguments: [
                    "action": .string(action),
                    action == "search" ? "query" : "url": .string(value)
                ]
            ))
        }
        let provider = ScriptedProvider(responses: [
            [.toolCalls([
                call(index: 0, action: "search", value: "popular small models"),
                call(index: 1, action: "search", value: "best local models")
            ]), .completed(ModelUsage())],
            [.toolCalls([
                call(index: 0, action: "fetch", value: "https://one.example"),
                call(index: 1, action: "fetch", value: "https://two.example")
            ]), .completed(ModelUsage())],
            [.text("Completed from bounded web evidence."), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [ObservedWebSequenceTool()]),
            configuration: AgentConfiguration(
                model: "fixture",
                options: ModelOptions(numContext: 8_192),
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(
            prompt: "我听说有很多小 uncensored 的版本，我想找一个最火的版本，本地下载下来试试看"
        )
        let requests = await provider.recordedRequests
        let finalRequestToolMessages = requests[2].messages.filter { $0.role == .tool }

        #expect(result.text == "Completed from bounded web evidence.")
        #expect(requests.count == 3)
        #expect(finalRequestToolMessages.count == 2)
        #expect(finalRequestToolMessages.allSatisfy {
            $0.content.contains("output_truncated")
        })
    }

    @Test("executes tools serially unless the implementation opts into concurrency")
    func defaultsToolBatchToSerial() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(index: 0, name: "serial_probe", arguments: ["value": .string("first")])),
            ToolCall(function: ToolFunctionCall(index: 1, name: "serial_probe", arguments: ["value": .string("second")]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = SerialProbeTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Run both probes")

        #expect(await tool.maximumConcurrency == 1)
    }

    @Test("does not start another serial tool after cancellation")
    func cancellationStopsSerialBatch() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(
                index: 0,
                name: "cancellation_probe",
                arguments: ["value": .string("first")]
            )),
            ToolCall(function: ToolFunctionCall(
                index: 1,
                name: "cancellation_probe",
                arguments: ["value": .string("second")]
            ))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())]
        ])
        let tool = CancellationProbeTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let run = Task { try await runtime.run(prompt: "Run both") }
        await tool.waitUntilStarted()
        run.cancel()

        await #expect(throws: CancellationError.self) {
            try await run.value
        }
        #expect(await tool.executionCount == 1)
    }

    @Test("stops an identical failed tool-call loop")
    func stopsRepeatedFailureLoop() async throws {
        let calls = (0..<4).map { index in ToolCall(
            function: ToolFunctionCall(
                index: index,
                name: "always_fails",
                arguments: ["value": .string("same")]
            )
        ) }
        let provider = ScriptedProvider(responses: calls.map {
            [.toolCalls([$0]), .completed(ModelUsage())]
        })
        let tool = AlwaysFailingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                repeatedToolFailureLimit: 3,
                automaticallyWarmsUp: false
            )
        )

        await #expect(
            throws: AgentRuntimeError.repeatedToolFailure(
                name: "always_fails",
                attempts: 3
            )
        ) {
            try await runtime.run(prompt: "Keep failing")
        }
        #expect(await tool.executionCount == 3)
        #expect(await provider.recordedRequests.count == 3)
    }

    @Test("stops identical failures within one model batch at the attempt limit")
    func stopsRepeatedFailureBatch() async throws {
        let calls = (0..<4).map { index in ToolCall(
            function: ToolFunctionCall(
                index: index,
                name: "always_fails",
                arguments: ["value": .string("same")]
            )
        ) }
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())]
        ])
        let tool = AlwaysFailingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                repeatedToolFailureLimit: 3,
                automaticallyWarmsUp: false
            )
        )

        await #expect(
            throws: AgentRuntimeError.repeatedToolFailure(
                name: "always_fails",
                attempts: 3
            )
        ) {
            try await runtime.run(prompt: "Fail four times")
        }
        #expect(await tool.executionCount == 3)
        #expect(await provider.recordedRequests.count == 1)
    }

    @Test("stabilizes a paraphrased retry against prior executed arguments")
    func stabilizesParaphrasedRetry() async throws {
        let first = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Original analysis goal")
            ]
        ))
        let paraphrased = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Rephrased analysis goal")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([first]), .completed(ModelUsage())],
            [.toolCalls([paraphrased]), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = StableTaskTool(failingExecution: 1)
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Analyze the document")
        let requests = await provider.recordedRequests
        let executedTasks = await tool.executedTasks
        let protocolTasks = try #require(requests.last).messages.flatMap { message in
            (message.toolCalls ?? []).compactMap { $0.function.arguments["task"]?.stringValue }
        }

        #expect(executedTasks == ["Original analysis goal", "Original analysis goal"])
        #expect(protocolTasks == ["Original analysis goal", "Original analysis goal"])
    }

    @Test("preserves independent tasks within one accepted batch")
    func preservesIndependentTasksWithinBatch() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(
                index: 0,
                name: "stable_task",
                arguments: [
                    "path": .string("document.pdf"),
                    "task": .string("Original analysis goal")
                ]
            )),
            ToolCall(function: ToolFunctionCall(
                index: 1,
                name: "stable_task",
                arguments: [
                    "path": .string("document.pdf"),
                    "task": .string("Rephrased analysis goal")
                ]
            ))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = StableTaskTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "Analyze the document")
        let recordedTasks = result.messages.flatMap { message in
            (message.toolCalls ?? []).compactMap {
                $0.function.arguments["task"]?.stringValue
            }
        }

        #expect(await tool.executedTasks == [
            "Original analysis goal",
            "Rephrased analysis goal"
        ])
        #expect(recordedTasks == ["Original analysis goal", "Rephrased analysis goal"])
    }

    @Test("reuses a successful scoped result in a later model round")
    func reusesSuccessfulScopedResult() async throws {
        let first = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Original analysis goal")
            ]
        ))
        let laterRound = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Rephrased analysis goal")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls([first]), .completed(ModelUsage())],
            [.toolCalls([laterRound]), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = StableTaskTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "Analyze the document")
        let recordedTasks = result.messages.flatMap { message in
            (message.toolCalls ?? []).compactMap {
                $0.function.arguments["task"]?.stringValue
            }
        }

        #expect(await tool.executedTasks == ["Original analysis goal"])
        #expect(recordedTasks == ["Original analysis goal", "Rephrased analysis goal"])
        #expect(result.performance.toolCallCount == 2)
    }

    @Test("does not cache an ambiguous scope called twice in one round")
    func doesNotReuseAmbiguousScope() async throws {
        let calls = ["Task A", "Task B"].map { task in
            ToolCall(function: ToolFunctionCall(
                name: "stable_task",
                arguments: [
                    "path": .string("document.pdf"),
                    "task": .string(task)
                ]
            ))
        }
        let later = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Task A")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.toolCalls([later]), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = StableTaskTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Analyze the document")

        #expect(await tool.executedTasks == ["Task A", "Task B", "Task A"])
    }

    @Test("does not reuse a prior cached scope for duplicates in a later round")
    func priorCacheDoesNotSatisfyLaterDuplicates() async throws {
        let first = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Initial task")
            ]
        ))
        let duplicates = ["Later A", "Later B"].map { task in
            ToolCall(function: ToolFunctionCall(
                name: "stable_task",
                arguments: [
                    "path": .string("document.pdf"),
                    "task": .string(task)
                ]
            ))
        }
        let provider = ScriptedProvider(responses: [
            [.toolCalls([first]), .completed(ModelUsage())],
            [.toolCalls(duplicates), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = StableTaskTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Analyze the document")

        #expect(await tool.executedTasks == ["Initial task", "Later A", "Later B"])
    }

    @Test("does not let an ambiguous success intercept a failed task retry")
    func ambiguousSuccessDoesNotInterceptRetry() async throws {
        let calls = ["Task A", "Task B"].map { task in
            ToolCall(function: ToolFunctionCall(
                name: "stable_task",
                arguments: [
                    "path": .string("document.pdf"),
                    "task": .string(task)
                ]
            ))
        }
        let retry = ToolCall(function: ToolFunctionCall(
            name: "stable_task",
            arguments: [
                "path": .string("document.pdf"),
                "task": .string("Task B paraphrased")
            ]
        ))
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.toolCalls([retry]), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = StableTaskTool(failingExecution: 2)
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Analyze the document")

        #expect(await tool.executedTasks == ["Task A", "Task B", "Task B"])
    }
}

private struct FixtureTool: LLMTool {
    let definition = fixtureToolDefinition

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{\"city\":\"Suzhou\",\"temperature_celsius\":24,\"condition\":\"clear\"}"
    }
}

private actor RecordingTool: LLMTool {
    nonisolated let definition = fixtureToolDefinition
    private(set) var executionCount = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        return "{}"
    }
}

private struct ImageFixtureTool: LLMTool {
    let image: Data
    let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "vision_probe",
            description: "Returns a fixture image.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{}"
    }

    func executeOutput(arguments: [String: JSONValue]) async throws -> ToolOutput {
        ToolOutput(
            content: #"{"frame_id":"frame-1"}"#,
            images: [ModelImage(data: image, width: 1280, height: 800)]
        )
    }
}

private actor ExclusiveRecordingTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "exclusive_probe",
            description: "Requires one Tool call per model round.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executionCount = 0

    nonisolated func requiresExclusiveRound(arguments: [String: JSONValue]) -> Bool {
        true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        return "{}"
    }
}

private actor SequentialImageFixtureTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "vision_sequence",
            description: "Returns sequential fixture images.",
            parameters: .object(["type": .string("object")])
        )
    )
    private var count = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{}"
    }

    func executeOutput(arguments: [String: JSONValue]) async throws -> ToolOutput {
        count += 1
        return ToolOutput(
            content: "{\"frame\":\(count)}",
            images: [ModelImage(data: Data([UInt8(count)]), width: 1, height: 1)]
        )
    }
}

private actor BudgetedJobTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "budgeted_job",
            description: "Fixture long-running job.",
            parameters: .object(["type": .string("object")])
        )
    )

    nonisolated func toolCallBudgetCost(arguments: [String: JSONValue]) -> Int {
        arguments["action"] == .string("run") ? 1 : 0
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{}"
    }
}

private actor CleanupProbeTool: LLMTool {
    nonisolated let definition = fixtureToolDefinition
    private(set) var cleanupCount = 0

    func cancelAll() {
        cleanupCount += 1
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{}"
    }
}

private actor BlockingCleanupTool: LLMTool {
    nonisolated let definition = fixtureToolDefinition
    private var cleanupStarted = false
    private var cleanupReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func cancelAll() async {
        cleanupStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        guard !cleanupReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilCleanupStarted() async {
        guard !cleanupStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseCleanup() {
        cleanupReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String { "{}" }
}

private actor RecordingDocumentTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "document_reader",
            description: "Reads one bounded document chunk for regression testing.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executionCount = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        return "chunk \(executionCount)"
    }
}

private actor StableTaskTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "stable_task",
            description: "Records a stable task for regression testing.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executedTasks: [String] = []
    private let failingExecution: Int?

    init(failingExecution: Int? = nil) {
        self.failingExecution = failingExecution
    }

    nonisolated func stabilizedArguments(
        _ arguments: [String: JSONValue],
        previousArguments: [[String: JSONValue]]
    ) -> [String: JSONValue] {
        guard let path = arguments["path"]?.stringValue,
              let previous = previousArguments.first(where: {
                  $0["path"]?.stringValue == path && $0["task"] != nil
              }),
              let task = previous["task"]
        else {
            return arguments
        }
        var result = arguments
        result["task"] = task
        return result
    }

    nonisolated func canonicalArgumentsForStabilization(
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue]? {
        guard let path = arguments["path"]?.stringValue,
              let task = arguments["task"]?.stringValue,
              !path.isEmpty,
              !task.isEmpty
        else {
            return nil
        }
        return ["path": .string(path), "task": .string(task)]
    }

    nonisolated func successfulResultReuseKey(
        arguments: [String: JSONValue]
    ) -> String? {
        arguments["path"]?.stringValue
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executedTasks.append(arguments["task"]?.stringValue ?? "")
        if executedTasks.count == failingExecution {
            throw FixtureToolError.failed
        }
        return "{}"
    }
}

private actor ParallelProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "probe",
            description: "Test concurrent execution.",
            parameters: .object(["type": .string("object")])
        )
    )
    private var activeCount = 0
    private(set) var maximumConcurrency = 0

    nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        try await ContinuousClock().sleep(for: .milliseconds(100))
        activeCount -= 1
        return arguments["value"]?.stringValue ?? ""
    }
}

private actor LargeParallelProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "large_probe",
            description: "Returns large structured evidence.",
            parameters: .object(["type": .string("object")])
        )
    )
    nonisolated let concurrencySafe: Bool

    init(concurrencySafe: Bool = true) {
        self.concurrencySafe = concurrencySafe
    }

    nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        concurrencySafe
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let marker = arguments["value"]?.stringValue ?? "value"
        let value = JSONValue.object([
            "marker": .string(marker),
            "text": .string(String(repeating: marker, count: 8_000))
        ])
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private actor ObservedWebSequenceTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "web_fixture",
            description: "Returns deterministic web evidence sizes.",
            parameters: .object(["type": .string("object")])
        )
    )

    nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let action = arguments["action"]?.stringValue
        let marker = arguments["query"]?.stringValue
            ?? arguments["url"]?.stringValue
            ?? "value"
        let count: Int
        if action == "search" {
            count = marker.contains("popular") ? 3_664 : 3_967
        } else {
            count = marker.contains("one.example") ? 13_431 : 15_724
        }
        let value = JSONValue.object([
            "marker": .string(marker),
            "text": .string(String(repeating: "x", count: count))
        ])
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private actor SerialProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "serial_probe",
            description: "Test default serial execution.",
            parameters: .object(["type": .string("object")])
        )
    )
    private var activeCount = 0
    private(set) var maximumConcurrency = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        activeCount -= 1
        return arguments["value"]?.stringValue ?? ""
    }
}

private actor CancellationProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "cancellation_probe",
            description: "Waits for cancellation during regression testing.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executionCount = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if executionCount > 0 { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        startedContinuation?.resume()
        startedContinuation = nil
        try await ContinuousClock().sleep(for: .seconds(30))
        return "done"
    }
}

private enum FixtureToolError: Error {
    case failed
}

private actor AlwaysFailingTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "always_fails",
            description: "Always fails for loop-guard testing.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executionCount = 0

    nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        throw FixtureToolError.failed
    }
}

private let fixtureToolDefinition = ToolDefinition(
    function: ToolFunctionDefinition(
        name: "web",
        description: "Fixture capability used only by tests.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string")]),
                "query": .object(["type": .string("string")])
            ]),
            "required": .array([.string("action"), .string("query")])
        ])
    )
)

private actor ScriptedProvider: ModelProvider {
    private var responses: [[ModelStreamEvent]]
    private(set) var recordedRequests: [ModelRequest] = []
    private(set) var warmupCount = 0

    init(responses: [[ModelStreamEvent]]) {
        self.responses = responses
    }

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        warmupCount += 1
        return WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        recordedRequests.append(request)
        let events = responses.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private enum FixtureProviderError: Error {
    case failed
}

private struct FailingProvider: ModelProvider {
    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        throw FixtureProviderError.failed
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        throw FixtureProviderError.failed
    }
}