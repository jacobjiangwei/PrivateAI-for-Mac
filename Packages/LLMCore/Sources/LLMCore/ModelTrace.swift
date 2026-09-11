import Foundation

public struct ModelRequestTrace: Codable, Equatable, Sendable {
    public enum Purpose: Codable, Equatable, Sendable {
        case conversation(round: Int)
        case modelWarmup
        case prefixWarmup
        case auxiliary

        public var label: String {
            switch self {
            case .conversation(let round): "Conversation round \(round)"
            case .modelWarmup: "Model warmup"
            case .prefixWarmup: "Stable prefix warmup"
            case .auxiliary: "Auxiliary model request"
            }
        }

        public var isWarmup: Bool {
            self == .modelWarmup || self == .prefixWarmup
        }
    }

    public let id: UUID
    public let purpose: Purpose
    public let endpoint: String
    public let body: String
    public let createdAt: Date

    public init(request: URLRequest, purpose: Purpose = ModelTrace.purpose) {
        id = UUID()
        self.purpose = purpose
        endpoint = request.url?.path ?? ""
        body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        createdAt = Date()
    }

    public var byteCount: Int { body.utf8.count }

    public var toolSchemaByteCount: Int {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]], !tools.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tools)
        else { return 0 }
        return data.count
    }
}

public enum ModelTraceEvent: Equatable, Sendable {
    case request(ModelRequestTrace)
    case output(id: UUID, event: ModelStreamEvent, at: Date)
    case failed(id: UUID, message: String)
}

public enum ModelTrace {
    public typealias Handler = @Sendable (ModelTraceEvent) async -> Void
    @TaskLocal public static var handler: Handler?
    @TaskLocal public static var purpose = ModelRequestTrace.Purpose.auxiliary

    public static func emit(_ event: ModelTraceEvent) async {
        await handler?(event)
    }
}