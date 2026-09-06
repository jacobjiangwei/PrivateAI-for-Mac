public struct ModelCapabilities: Equatable, Sendable {
    public let values: Set<String>

    public init(_ values: Set<String>) {
        self.values = values
    }

    public var supportsVisionToolUse: Bool {
        values.contains("vision") && values.contains("tools")
    }
}

public protocol ModelCapabilityProviding: Sendable {
    func capabilities(for model: String) async throws -> ModelCapabilities
}