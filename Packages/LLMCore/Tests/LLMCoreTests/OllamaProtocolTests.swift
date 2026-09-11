import Foundation
import Testing
@testable import LLMCore

@Suite("Ollama Protocol")
struct OllamaProtocolTests {
  @Test("trace retains the exact encoded request including tools and images")
  func rawRequestTrace() throws {
    let body = #"{"model":"fixture","messages":[{"role":"system","content":"rules"},{"role":"tool","content":"result","images":["AQID"]}],"tools":[{"type":"function","function":{"name":"read","parameters":{"type":"object"}}}]}"#
    var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
    request.httpBody = Data(body.utf8)
    let trace = ModelRequestTrace(request: request, purpose: .conversation(round: 1))
    #expect(trace.body == body)
    #expect(trace.byteCount == request.httpBody?.count)
    #expect(trace.toolSchemaByteCount > 0)
    #expect(trace.endpoint == "/api/chat")
    let restored = try JSONDecoder().decode(ModelRequestTrace.self, from: JSONEncoder().encode(trace))
    #expect(restored == trace)
  }

    @Test("round-trips the official assistant tool-call message shape")
    func officialToolCallRoundTrip() throws {
        let json = Data(
            #"""
            {
              "role": "assistant",
              "tool_calls": [
                {
                  "type": "function",
                  "function": {
                    "index": 0,
                    "name": "web",
                    "arguments": {
                      "action": "search",
                      "query": "Suzhou current weather"
                    }
                  }
                }
              ]
            }
            """#.utf8
        )

        let message = try JSONDecoder().decode(ChatMessage.self, from: json)
        let call = try #require(message.toolCalls?.first)

        #expect(message.role == .assistant)
        #expect(message.content.isEmpty)
        #expect(call.type == "function")
        #expect(call.function.index == 0)
        #expect(call.function.name == "web")
        #expect(call.function.arguments["action"] == .string("search"))

        let encoded = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let calls = try #require(object["tool_calls"] as? [[String: Any]])
        let encodedCall = try #require(calls.first)
        let function = try #require(encodedCall["function"] as? [String: Any])

        #expect(object["content"] == nil)
        #expect(encodedCall["type"] as? String == "function")
        #expect(function["index"] as? Int == 0)
        #expect(function["name"] as? String == "web")
    }

    @Test("encodes the official assistant and tool result sequence")
    func toolResultSequence() throws {
        let call = ToolCall(
            function: ToolFunctionCall(
                index: 0,
                name: "web",
                arguments: ["action": .string("search"), "query": .string("Suzhou")]
            )
        )
        let request = ModelRequest(
            model: "qwen3",
            messages: [
                ChatMessage(role: .user, content: "What is the weather in Suzhou?"),
                ChatMessage(role: .assistant, content: "", toolCalls: [call]),
                ChatMessage(role: .tool, content: "28 C", toolName: "web")
            ],
            stream: false
        )

        let encoded = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])

        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["tool_calls"] != nil)
        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[2]["tool_name"] as? String == "web")
        #expect(messages[2]["content"] as? String == "28 C")
    }

    @Test("encodes images on an Ollama Tool result message")
    func imageToolResult() throws {
      let image = Data([0x89, 0x50, 0x4E, 0x47])
      let message = ChatMessage(
        role: .tool,
        content: #"{"frame_id":"frame-1"}"#,
        toolName: "browser",
        images: [ModelImage(data: image, width: 1280, height: 800)]
      )

      let encoded = try JSONEncoder().encode(message)
      let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      let images = try #require(object["images"] as? [String])

      #expect(images == [image.base64EncodedString()])
      #expect(object["tool_name"] as? String == "browser")

      let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
      #expect(decoded.images.map(\.data) == [image])
    }

      @Test("decodes the provider finish reason into model usage")
      func finishReason() throws {
        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: Data(#"""
        {
          "message": {"role":"assistant","content":"partial"},
          "done": true,
          "done_reason": "length",
          "prompt_eval_count": 100,
          "eval_count": 32
        }
        """#.utf8))

        #expect(chunk.usage.finishReason == "length")
        #expect(chunk.usage.promptTokenCount == 100)
        #expect(chunk.usage.outputTokenCount == 32)
      }
}