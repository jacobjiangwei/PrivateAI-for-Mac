import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OllamaProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, String)
    case provider(String)
    case malformedStream(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Ollama must use an HTTP loopback URL."
        case .invalidResponse:
            "Ollama returned an invalid HTTP response."
        case .httpStatus(let status, let message):
            "Ollama returned HTTP \(status): \(message)"
        case .provider(let message):
            "Ollama error: \(message)"
        case .malformedStream(let line):
            "Ollama returned malformed stream data: \(line)"
        }
    }
}

public actor OllamaProvider: ModelProvider, ModelIdentityProviding, ModelCapabilityProviding {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        requestTimeout: TimeInterval = 600
    ) throws {
        guard baseURL.scheme == "http",
              let host = baseURL.host,
              ["127.0.0.1", "localhost", "::1"].contains(host)
        else {
            throw OllamaProviderError.invalidBaseURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2

        self.baseURL = baseURL
        self.session = URLSession(configuration: configuration)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func warmUp(
        model: String,
        keepAlive: String = "30m",
        options: ModelOptions = ModelOptions()
    ) async throws -> WarmupMetrics {
        let requestBody = OllamaWarmupRequest(
            model: model,
            prompt: "",
            stream: false,
            keepAlive: keepAlive,
            options: options
        )
        let request = try makeRequest(path: "api/generate", body: requestBody)
        let clock = ContinuousClock()
        let start = clock.now
        let trace = ModelRequestTrace(request: request, purpose: .modelWarmup)
        await ModelTrace.emit(.request(trace))
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)

            let result = try decoder.decode(OllamaWarmupResponse.self, from: data)
            if let error = result.error {
                throw OllamaProviderError.provider(error)
            }

            await ModelTrace.emit(.output(
                id: trace.id,
                event: .completed(ModelUsage(loadDurationNanoseconds: result.loadDuration)),
                at: Date()
            ))

            return WarmupMetrics(
                elapsedSeconds: seconds(from: start.duration(to: clock.now)),
                providerLoadSeconds: result.loadDuration.map(nanosecondsToSeconds)
            )
        } catch {
            await ModelTrace.emit(.failed(id: trace.id, message: error.localizedDescription))
            throw error
        }
    }

    public func unload(model: String) async throws {
        let requestBody = OllamaWarmupRequest(
            model: model,
            prompt: "",
            stream: false,
            keepAlive: "0",
            options: ModelOptions()
        )
        let request = try makeRequest(path: "api/generate", body: requestBody)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let result = try decoder.decode(OllamaWarmupResponse.self, from: data)
        if let error = result.error {
            throw OllamaProviderError.provider(error)
        }
    }

    public func immutableModelIdentity(for model: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let tags = try decoder.decode(OllamaTagsResponse.self, from: data)
        guard let digest = tags.models.first(where: {
            $0.name == model || $0.model == model
        })?.digest, !digest.isEmpty else {
            throw OllamaProviderError.provider("The immutable digest for model '\(model)' is unavailable.")
        }
        return digest
    }

    public func capabilities(for model: String) async throws -> ModelCapabilities {
        let request = try makeRequest(
            path: "api/show",
            body: OllamaShowRequest(model: model)
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let result = try decoder.decode(OllamaShowResponse.self, from: data)
        return ModelCapabilities(Set(result.capabilities))
    }

    public func stream(
        _ modelRequest: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let request = try makeRequest(path: "api/chat", body: modelRequest)
        let trace = ModelRequestTrace(request: request)
        await ModelTrace.emit(.request(trace))
        do {
            return try await responseStream(for: request, traceID: trace.id)
        } catch {
            await ModelTrace.emit(.failed(id: trace.id, message: error.localizedDescription))
            throw error
        }
    }

    private func responseStream(
        for request: URLRequest,
        traceID: UUID
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var responseData = Data()
            for try await byte in bytes {
                responseData.append(byte)
            }
            throw OllamaProviderError.httpStatus(
                httpResponse.statusCode,
                String(decoding: responseData, as: UTF8.self)
            )
        }

        let decoder = self.decoder
        return AsyncThrowingStream { continuation in
            let decodingTask = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty else {
                            continue
                        }

                        guard let data = line.data(using: .utf8) else {
                            throw OllamaProviderError.malformedStream(line)
                        }
                        let chunk: OllamaChatChunk
                        do {
                            chunk = try decoder.decode(OllamaChatChunk.self, from: data)
                        } catch {
                            throw OllamaProviderError.malformedStream(line)
                        }

                        if let error = chunk.error {
                            throw OllamaProviderError.provider(error)
                        }
                        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
                            await ModelTrace.emit(.output(id: traceID, event: .thinking(thinking), at: Date()))
                            continuation.yield(.thinking(thinking))
                        }
                        if let text = chunk.message?.content, !text.isEmpty {
                            await ModelTrace.emit(.output(id: traceID, event: .text(text), at: Date()))
                            continuation.yield(.text(text))
                        }
                        if let toolCalls = chunk.message?.toolCalls, !toolCalls.isEmpty {
                            await ModelTrace.emit(.output(id: traceID, event: .toolCalls(toolCalls), at: Date()))
                            continuation.yield(.toolCalls(toolCalls))
                        }
                        if chunk.done {
                            await ModelTrace.emit(.output(id: traceID, event: .completed(chunk.usage), at: Date()))
                            continuation.yield(.completed(chunk.usage))
                        }
                    }
                    continuation.finish()
                } catch {
                    await ModelTrace.emit(.failed(id: traceID, message: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                decodingTask.cancel()
            }
        }
    }

    private func makeRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OllamaProviderError.httpStatus(
                httpResponse.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
    }
}

private struct OllamaWarmupRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let keepAlive: String
    let options: ModelOptions

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case stream
        case keepAlive = "keep_alive"
        case options
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(stream, forKey: .stream)
        if keepAlive == "-1" {
            try container.encode(-1, forKey: .keepAlive)
        } else {
            try container.encode(keepAlive, forKey: .keepAlive)
        }
        try container.encode(options, forKey: .options)
    }
}

private struct OllamaWarmupResponse: Decodable {
    let loadDuration: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case loadDuration = "load_duration"
        case error
    }
}

private struct OllamaShowRequest: Encodable {
    let model: String
}

private struct OllamaShowResponse: Decodable {
    let capabilities: [String]
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaTag]
}

private struct OllamaTag: Decodable {
    let name: String
    let model: String
    let digest: String
}

struct OllamaChatChunk: Decodable {
    let message: ChatMessage?
    let done: Bool
    let error: String?
    let totalDuration: UInt64?
    let loadDuration: UInt64?
    let promptEvalCount: Int?
    let promptEvalDuration: UInt64?
    let evalCount: Int?
    let evalDuration: UInt64?
    let doneReason: String?

    var usage: ModelUsage {
        ModelUsage(
            totalDurationNanoseconds: totalDuration,
            loadDurationNanoseconds: loadDuration,
            promptTokenCount: promptEvalCount,
            promptDurationNanoseconds: promptEvalDuration,
            outputTokenCount: evalCount,
            outputDurationNanoseconds: evalDuration,
            finishReason: doneReason
        )
    }

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case error
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalCount = "prompt_eval_count"
        case promptEvalDuration = "prompt_eval_duration"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
        case doneReason = "done_reason"
    }
}

private func nanosecondsToSeconds(_ nanoseconds: UInt64) -> Double {
    Double(nanoseconds) / 1_000_000_000
}

private func seconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}