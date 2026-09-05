import Foundation
import LLMCore
import SwiftSoup

public enum WebToolError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case disallowedHost(String)
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge(Int)
    case unsupportedContentType(String)
    case noSearchResults

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "A valid public HTTPS URL is required."
        case .disallowedHost(let host):
            "The host '\(host)' is not a public web destination."
        case .invalidResponse:
            "The web server returned an invalid response."
        case .httpStatus(let status):
            "The web server returned HTTP \(status)."
        case .responseTooLarge(let limit):
            "The web response exceeded the \(limit)-byte limit."
        case .unsupportedContentType(let contentType):
            "The web content type '\(contentType)' is not supported."
        case .noSearchResults:
            "The web search returned no readable results."
        }
    }
}

public actor WebTool: LLMTool {
    public let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: PrivateAIToolPrompts.Web.name,
            description: PrivateAIToolPrompts.Web.tool,
            parameters: objectSchema(
                properties: [
                    "action": stringSchema(
                        description: PrivateAIToolPrompts.Web.action,
                        values: ["search", "fetch"]
                    ),
                    "query": stringSchema(description: PrivateAIToolPrompts.Web.query),
                    "url": stringSchema(description: PrivateAIToolPrompts.Web.url),
                    "maximum_results": integerSchema(
                        description: PrivateAIToolPrompts.Web.maximumResults,
                        range: 1...10
                    )
                ],
                required: ["action"]
            )
        )
    )

    private let session: URLSession
    private let maximumResponseBytes: Int
    private let maximumTextCharacters: Int

    public init(
        requestTimeout: TimeInterval = 20,
        maximumResponseBytes: Int = 2 * 1_024 * 1_024,
        maximumTextCharacters: Int = 40_000
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = [
            "User-Agent": "PrivateAI/1.0 (+https://github.com/)"
        ]
        self.session = URLSession(configuration: configuration)
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumTextCharacters = maximumTextCharacters
    }

    init(
        session: URLSession,
        maximumResponseBytes: Int = 2 * 1_024 * 1_024,
        maximumTextCharacters: Int = 40_000
    ) {
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumTextCharacters = maximumTextCharacters
    }

    public nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        guard let action = arguments["action"]?.stringValue else {
            return false
        }
        return action == "search" || action == "fetch"
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        let values = CapabilityArguments(values: arguments)
        let action = try values.requiredString("action", maximumBytes: 32)

        switch action {
        case "search":
            try values.requireOnly(["action", "query", "maximum_results"])
            return try await search(
                query: try values.requiredString("query", maximumBytes: 2_048),
                maximumResults: try values.optionalInteger(
                    "maximum_results",
                    range: 1...10
                ) ?? 5
            )
        case "fetch":
            try values.requireOnly(["action", "url"])
            let rawURL = try values.requiredString("url", maximumBytes: 4_096)
            return try await fetch(url: try validatedPublicURL(rawURL))
        default:
            throw CapabilityToolError.unsupportedAction(action)
        }
    }

    private func search(query: String, maximumResults: Int) async throws -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            throw WebToolError.invalidURL
        }

        let response = try await load(url)
        let document = try SwiftSoup.parse(response.text, url.absoluteString)
        let elements = try document.select(".result").array()
        var results: [JSONValue] = []

        for element in elements.prefix(maximumResults) {
            guard let link = try element.select("a.result__a").first() else {
                continue
            }
            let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let rawURL = try link.attr("href")
            let destination = decodedSearchDestination(rawURL)
            let snippet = try element.select(".result__snippet").text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !destination.isEmpty else {
                continue
            }
            results.append(.object([
                "title": .string(title),
                "url": .string(destination),
                "snippet": .string(snippet)
            ]))
        }

        guard !results.isEmpty else {
            throw WebToolError.noSearchResults
        }
        return try encodeToolResult(.object([
            "query": .string(query),
            "results": .array(results)
        ]))
    }

    private func fetch(url: URL) async throws -> String {
        let response = try await load(url)
        let mediaType = response.contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch mediaType {
        case "text/html", "application/xhtml+xml", "":
            break
        case "text/plain", "text/markdown", "application/json", "application/xml", "text/xml":
            break
        default:
            throw WebToolError.unsupportedContentType(mediaType)
        }

        let extracted: String
        switch mediaType {
        case "text/html", "application/xhtml+xml", "":
            extracted = Self.readableText(fromHTML: response.text, baseURL: response.finalURL)
        default:
            extracted = response.text
        }
        let truncated = String(extracted.prefix(maximumTextCharacters))
        return try encodeToolResult(.object([
            "url": .string(response.finalURL.absoluteString),
            "content_type": .string(mediaType),
            "encoding": .string("utf-8"),
            "text": .string(truncated),
            "truncated": .bool(extracted.count > maximumTextCharacters)
        ]))
    }

    /// Extracts human-readable text from an HTML document so the model receives
    /// content instead of markup, which keeps the tool result within the context window.
    private static func readableText(fromHTML html: String, baseURL: URL) -> String {
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString) else {
            return html
        }
        _ = try? document.select("script, style, noscript, template, svg, iframe").remove()
        let title = (try? document.title()) ?? ""
        let body = (try? document.body()?.text()) ?? (try? document.text()) ?? ""
        let combined = title.isEmpty ? body : "\(title)\n\n\(body)"
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load(_ url: URL) async throws -> WebResponse {
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebToolError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WebToolError.httpStatus(httpResponse.statusCode)
        }
        guard data.count <= maximumResponseBytes else {
            throw WebToolError.responseTooLarge(maximumResponseBytes)
        }
        guard let finalURL = httpResponse.url else {
            throw WebToolError.invalidResponse
        }
        _ = try validatedPublicURL(finalURL.absoluteString)
        return WebResponse(
            finalURL: finalURL,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "",
            text: String(decoding: data, as: UTF8.self)
        )
    }

    private func validatedPublicURL(_ rawURL: String) throws -> URL {
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              !host.isEmpty
        else {
            throw WebToolError.invalidURL
        }

        let blockedNames = ["localhost", "localhost.localdomain", "metadata.google.internal"]
        let blockedSuffixes = [".localhost", ".local", ".internal", ".home.arpa"]
        guard !blockedNames.contains(host),
              !blockedSuffixes.contains(where: host.hasSuffix),
              !isPrivateIPv4(host)
        else {
            throw WebToolError.disallowedHost(host)
        }
        return url
    }

    private func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return octets[0] >= 224
        }
    }

    private func decodedSearchDestination(_ rawURL: String) -> String {
        let absolute = rawURL.hasPrefix("//") ? "https:\(rawURL)" : rawURL
        guard let components = URLComponents(string: absolute),
              let encodedDestination = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else {
            return absolute
        }
        return encodedDestination
    }
}

private struct WebResponse {
    let finalURL: URL
    let contentType: String
    let text: String
}