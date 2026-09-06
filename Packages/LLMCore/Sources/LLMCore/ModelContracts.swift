import Foundation

public enum ChatRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ModelImage: Equatable, Sendable {
    public let data: Data
    public let width: Int?
    public let height: Int?

    public init(data: Data, width: Int? = nil, height: Int? = nil) {
        self.data = data
        self.width = width
        self.height = height
    }
}

public struct ToolFunctionCall: Codable, Equatable, Sendable {
    public let index: Int?
    public let name: String
    public let arguments: [String: JSONValue]

    public init(index: Int? = nil, name: String, arguments: [String: JSONValue]) {
        self.index = index
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public let type: String
    public let function: ToolFunctionCall

    public init(type: String = "function", function: ToolFunctionCall) {
        self.type = type
        self.function = function
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
        self.function = try container.decode(ToolFunctionCall.self, forKey: .function)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case function
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: ChatRole
    public let content: String
    public let thinking: String?
    public let toolCalls: [ToolCall]?
    public let toolName: String?
    public let images: [ModelImage]

    public init(
        role: ChatRole,
        content: String,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolName: String? = nil,
        images: [ModelImage] = []
    ) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.images = images
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(ChatRole.self, forKey: .role)
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        self.toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        images = try container.decodeIfPresent([Data].self, forKey: .images)?
            .map { ModelImage(data: $0) } ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if !content.isEmpty || toolCalls == nil {
            try container.encode(content, forKey: .content)
        }
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        if !images.isEmpty {
            try container.encode(images.map(\.data), forKey: .images)
        }
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case thinking
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
        case images
    }

    public func withoutImages() -> ChatMessage {
        ChatMessage(
            role: role,
            content: content,
            thinking: thinking,
            toolCalls: toolCalls,
            toolName: toolName
        )
    }
}

public struct ToolFunctionDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ToolDefinition: Codable, Equatable, Sendable {
    public let type: String
    public let function: ToolFunctionDefinition

    public init(function: ToolFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

public struct ModelOptions: Codable, Equatable, Sendable {
    public let numContext: Int
    public let temperature: Double
    public let numPredict: Int?

    public init(
        numContext: Int = 8_192,
        temperature: Double = 0.2,
        numPredict: Int? = nil
    ) {
        self.numContext = numContext
        self.temperature = temperature
        self.numPredict = numPredict
    }

    enum CodingKeys: String, CodingKey {
        case numContext = "num_ctx"
        case temperature
        case numPredict = "num_predict"
    }
}

public struct ModelRequest: Codable, Equatable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let tools: [ToolDefinition]
    public let format: JSONValue?
    public let stream: Bool
    public let think: Bool
    public let keepAlive: String
    public let options: ModelOptions

    public init(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        format: JSONValue? = nil,
        stream: Bool = true,
        think: Bool = false,
        keepAlive: String = "30m",
        options: ModelOptions = ModelOptions()
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.format = format
        self.stream = stream
        self.think = think
        self.keepAlive = keepAlive
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case format
        case stream
        case think
        case keepAlive = "keep_alive"
        case options
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(tools, forKey: .tools)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encode(stream, forKey: .stream)
        try container.encode(think, forKey: .think)
        if keepAlive == "-1" {
            try container.encode(-1, forKey: .keepAlive)
        } else {
            try container.encode(keepAlive, forKey: .keepAlive)
        }
        try container.encode(options, forKey: .options)
    }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public let totalDurationNanoseconds: UInt64?
    public let loadDurationNanoseconds: UInt64?
    public let promptTokenCount: Int?
    public let promptDurationNanoseconds: UInt64?
    public let outputTokenCount: Int?
    public let outputDurationNanoseconds: UInt64?
    public let finishReason: String?

    public init(
        totalDurationNanoseconds: UInt64? = nil,
        loadDurationNanoseconds: UInt64? = nil,
        promptTokenCount: Int? = nil,
        promptDurationNanoseconds: UInt64? = nil,
        outputTokenCount: Int? = nil,
        outputDurationNanoseconds: UInt64? = nil,
        finishReason: String? = nil
    ) {
        self.totalDurationNanoseconds = totalDurationNanoseconds
        self.loadDurationNanoseconds = loadDurationNanoseconds
        self.promptTokenCount = promptTokenCount
        self.promptDurationNanoseconds = promptDurationNanoseconds
        self.outputTokenCount = outputTokenCount
        self.outputDurationNanoseconds = outputDurationNanoseconds
        self.finishReason = finishReason
    }
}

public enum ModelStreamEvent: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolCalls([ToolCall])
    case completed(ModelUsage)
}

public struct WarmupMetrics: Equatable, Sendable {
    public let elapsedSeconds: Double
    public let providerLoadSeconds: Double?
    public let prefixPromptTokenCount: Int?
    public let prefixPromptSeconds: Double?

    public init(
        elapsedSeconds: Double,
        providerLoadSeconds: Double?,
        prefixPromptTokenCount: Int? = nil,
        prefixPromptSeconds: Double? = nil
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.providerLoadSeconds = providerLoadSeconds
        self.prefixPromptTokenCount = prefixPromptTokenCount
        self.prefixPromptSeconds = prefixPromptSeconds
    }
}

public protocol ModelProvider: Sendable {
    func warmUp(model: String, keepAlive: String, options: ModelOptions) async throws -> WarmupMetrics
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error>
}

public protocol ModelIdentityProviding: Sendable {
    func immutableModelIdentity(for model: String) async throws -> String
}