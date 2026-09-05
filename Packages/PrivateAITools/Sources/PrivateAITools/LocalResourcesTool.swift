import Foundation
import LLMCore
import PDFKit

public enum LocalResourcesAccess: Sendable {
    case restricted([URL])
    case unrestricted
}

public enum LocalResourcesToolError: Error, Equatable, LocalizedError, Sendable {
    case outsideAuthorizedRoots(String)
    case resourceNotFound(String)
    case unsupportedFileType(String)
    case fileTooLarge(Int)
    case unreadablePDF
    case lockedPDF
    case pdfHasNoExtractableText
    case invalidPageRange
    case invalidCharacterRange
    case unreadableTextEncoding

    public var errorDescription: String? {
        switch self {
        case .outsideAuthorizedRoots(let path):
            "The path '\(path)' is outside the locations available to PrivateAI."
        case .resourceNotFound(let path):
            "The local resource '\(path)' does not exist."
        case .unsupportedFileType(let type):
            "The local resource type '\(type)' is not supported."
        case .fileTooLarge(let limit):
            "The local resource exceeded the \(limit)-byte limit."
        case .unreadablePDF:
            "PDFKit could not open the PDF document."
        case .lockedPDF:
            "The PDF document is locked and cannot be read."
        case .pdfHasNoExtractableText:
            "The requested PDF pages do not contain an extractable text layer."
        case .invalidPageRange:
            "The requested PDF page range is invalid."
        case .invalidCharacterRange:
            "The requested document character range is invalid."
        case .unreadableTextEncoding:
            "The document text encoding could not be decoded reliably."
        }
    }
}

public actor LocalResourcesTool: LLMTool {
    public nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: PrivateAIToolPrompts.LocalResources.name,
            description: PrivateAIToolPrompts.LocalResources.tool,
            parameters: objectSchema(
                properties: [
                    "action": stringSchema(
                        description: PrivateAIToolPrompts.LocalResources.action,
                        values: ["list", "read", "search"]
                    ),
                    "path": stringSchema(description: PrivateAIToolPrompts.LocalResources.path),
                    "query": stringSchema(description: PrivateAIToolPrompts.LocalResources.query),
                    "page_start": integerSchema(description: PrivateAIToolPrompts.LocalResources.pageStart, range: 1...100_000),
                    "page_end": integerSchema(description: PrivateAIToolPrompts.LocalResources.pageEnd, range: 1...100_000),
                    "page_offset": integerSchema(description: PrivateAIToolPrompts.LocalResources.pageOffset, range: 0...10_000_000),
                    "character_offset": integerSchema(description: PrivateAIToolPrompts.LocalResources.characterOffset, range: 0...10_000_000),
                    "character_limit": integerSchema(description: PrivateAIToolPrompts.LocalResources.characterLimit, range: 1...200_000),
                    "limit": integerSchema(description: PrivateAIToolPrompts.LocalResources.limit, range: 1...500)
                ],
                required: ["action", "path"]
            )
        )
    )

    private let access: LocalResourcesAccess
    private let maximumFileBytes: Int
    private let maximumTextCharacters: Int
    private let fileManager: FileManager

    public init(
        access: LocalResourcesAccess,
        maximumFileBytes: Int = 20 * 1_024 * 1_024,
        maximumTextCharacters: Int = 200_000,
        fileManager: FileManager = .default
    ) {
        switch access {
        case .restricted(let roots):
            self.access = .restricted(roots.map {
                $0.standardizedFileURL.resolvingSymlinksInPath()
            })
        case .unrestricted:
            self.access = .unrestricted
        }
        self.maximumFileBytes = maximumFileBytes
        self.maximumTextCharacters = maximumTextCharacters
        self.fileManager = fileManager
    }

    public init(
        authorizedRoots: [URL],
        maximumFileBytes: Int = 20 * 1_024 * 1_024,
        maximumTextCharacters: Int = 200_000,
        fileManager: FileManager = .default
    ) {
        self.init(
            access: authorizedRoots.isEmpty ? .unrestricted : .restricted(authorizedRoots),
            maximumFileBytes: maximumFileBytes,
            maximumTextCharacters: maximumTextCharacters,
            fileManager: fileManager
        )
    }

    public nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        switch arguments["action"]?.stringValue {
        case "list", "read", "search": true
        default: false
        }
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        let values = CapabilityArguments(values: arguments)
        let action = try values.requiredString("action", maximumBytes: 32)
        let rawPath = try values.requiredString("path", maximumBytes: 4_096)
        let resource = try resolve(rawPath)
        let accessedSecurityScope = resource.root.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                resource.root.stopAccessingSecurityScopedResource()
            }
        }
        let result: JSONValue

        switch action {
        case "list":
            try values.requireOnly(["action", "path", "limit"])
            result = try listDirectory(
                resource.url,
                limit: try values.optionalInteger("limit", range: 1...500) ?? 100
            )
        case "read":
            try values.requireOnly([
                "action", "path", "page_start", "page_end", "page_offset",
                "character_offset", "character_limit"
            ])
            result = try readDocument(
                resource.url,
                pageStart: try values.optionalInteger("page_start", range: 1...100_000),
                pageEnd: try values.optionalInteger("page_end", range: 1...100_000),
                pageOffset: try values.optionalInteger("page_offset", range: 0...10_000_000),
                characterOffset: try values.optionalInteger("character_offset", range: 0...10_000_000),
                characterLimit: try values.optionalInteger("character_limit", range: 1...200_000)
            )
        case "search":
            try values.requireOnly(["action", "path", "query", "limit", "page_start", "page_end"])
            result = try searchDocument(
                resource.url,
                query: try values.requiredString("query", maximumBytes: 2_048),
                limit: try values.optionalInteger("limit", range: 1...500) ?? 50,
                pageStart: try values.optionalInteger("page_start", range: 1...100_000),
                pageEnd: try values.optionalInteger("page_end", range: 1...100_000)
            )
        default:
            throw CapabilityToolError.unsupportedAction(action)
        }

        return try encodeToolResult(result)
    }

    private func resolve(_ path: String) throws -> AuthorizedResource {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates: [URL]
        if expanded.hasPrefix("/") {
            candidates = [URL(fileURLWithPath: expanded)]
        } else {
            switch access {
            case .restricted(let roots):
                candidates = roots.map { $0.appending(path: expanded) }
            case .unrestricted:
                candidates = [fileManager.homeDirectoryForCurrentUser.appending(path: expanded)]
            }
        }
        var wasAuthorized = false
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let root: URL
            switch access {
            case .unrestricted:
                root = resolved
            case .restricted(let roots):
                guard let matched = roots.first(where: { contains(resolved, root: $0) }) else {
                    continue
                }
                wasAuthorized = true
                root = matched
            }
            if fileManager.fileExists(atPath: resolved.path) {
                return AuthorizedResource(url: resolved, root: root)
            }
        }
        guard wasAuthorized || access.isUnrestricted else {
            throw LocalResourcesToolError.outsideAuthorizedRoots(path)
        }
        if candidates.isEmpty {
            throw LocalResourcesToolError.outsideAuthorizedRoots(path)
        } else {
            throw LocalResourcesToolError.resourceNotFound(path)
        }
    }

    private func contains(_ resource: URL, root: URL) -> Bool {
        let resourceComponents = resource.pathComponents
        let rootComponents = root.pathComponents
        return resourceComponents.count >= rootComponents.count
            && Array(resourceComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func listDirectory(_ url: URL, limit: Int) throws -> JSONValue {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CapabilityToolError.invalidArgument("path")
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey
        ]
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let entries = try children
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { child -> JSONValue in
                let values = try child.resourceValues(forKeys: keys)
                return .object([
                    "name": .string(child.lastPathComponent),
                    "path": .string(child.path),
                    "is_directory": .bool(values.isDirectory ?? false),
                    "size_bytes": values.fileSize.map { .number(Double($0)) } ?? .null,
                    "content_type": values.contentType.map { .string($0.identifier) } ?? .null,
                    "modified_at": values.contentModificationDate.map { .string($0.ISO8601Format()) } ?? .null
                ])
            }
        return .object([
            "path": .string(url.path),
            "entries": .array(Array(entries)),
            "truncated": .bool(children.count > limit)
        ])
    }

    private func readDocument(
        _ url: URL,
        pageStart: Int?,
        pageEnd: Int?,
        pageOffset: Int?,
        characterOffset: Int?,
        characterLimit: Int?
    ) throws -> JSONValue {
        let format = LocalDocumentFormat.detect(url: url)
        if format == .pdf {
            guard characterOffset == nil else {
                throw LocalResourcesToolError.invalidCharacterRange
            }
            return try readPDF(
                url,
                pageStart: pageStart,
                pageEnd: pageEnd,
                pageOffset: pageOffset,
                characterLimit: characterLimit
            )
        }
        guard pageStart == nil, pageEnd == nil, pageOffset == nil else {
            throw LocalResourcesToolError.invalidPageRange
        }
        return try readText(
            url,
            format: format,
            characterOffset: characterOffset,
            characterLimit: characterLimit
        )
    }

    private func readText(
        _ url: URL,
        format: LocalDocumentFormat? = nil,
        characterOffset: Int? = nil,
        characterLimit: Int? = nil
    ) throws -> JSONValue {
        let loaded = try loadText(url, format: format)
        let offset = characterOffset ?? 0
        guard offset <= loaded.text.count else {
            throw LocalResourcesToolError.invalidCharacterRange
        }
        let limit = min(characterLimit ?? maximumTextCharacters, maximumTextCharacters)
        let start = loaded.text.index(loaded.text.startIndex, offsetBy: offset)
        let end = loaded.text.index(start, offsetBy: limit, limitedBy: loaded.text.endIndex)
            ?? loaded.text.endIndex
        let text = String(loaded.text[start..<end])
        let characterEnd = offset + text.count
        let truncated = characterEnd < loaded.text.count
        return .object([
            "path": .string(url.path),
            "kind": .string("text"),
            "format": .string(loaded.format.rawValue),
            "encoding": .string(loaded.encoding),
            "text": .string(text),
            "character_offset": .number(Double(offset)),
            "character_end": .number(Double(characterEnd)),
            "total_characters": .number(Double(loaded.text.count)),
            "next_character_offset": truncated ? .number(Double(characterEnd)) : .null,
            "recommended_action": truncated && offset == 0
                ? .string("Use document_analysis for whole-document summary; continue read only for adjacent detail.")
                : .null,
            "truncated": .bool(truncated),
            "size_bytes": .number(Double(loaded.sizeBytes))
        ])
    }

    private func loadText(
        _ url: URL,
        format: LocalDocumentFormat? = nil
    ) throws -> LoadedText {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let fileSize = values.fileSize ?? 0
        guard fileSize <= maximumFileBytes else {
            throw LocalResourcesToolError.fileTooLarge(maximumFileBytes)
        }
        let resolvedFormat = format ?? LocalDocumentFormat.detect(url: url)
        guard resolvedFormat.isText else {
            throw LocalResourcesToolError.unsupportedFileType(
                values.contentType?.identifier ?? url.pathExtension.lowercased()
            )
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumFileBytes else {
            throw LocalResourcesToolError.fileTooLarge(maximumFileBytes)
        }
        guard let decoded = decodeText(data), isPlausibleText(decoded.text) else {
            throw LocalResourcesToolError.unreadableTextEncoding
        }
        return LoadedText(
            text: decoded.text,
            encoding: decoded.encoding,
            format: resolvedFormat,
            sizeBytes: data.count
        )
    }

    private func readPDF(
        _ url: URL,
        pageStart: Int?,
        pageEnd: Int?,
        pageOffset: Int?,
        characterLimit: Int?
    ) throws -> JSONValue {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumFileBytes else {
            throw LocalResourcesToolError.fileTooLarge(maximumFileBytes)
        }
        guard let document = PDFDocument(url: url) else {
            throw LocalResourcesToolError.unreadablePDF
        }
        guard !document.isLocked else {
            throw LocalResourcesToolError.lockedPDF
        }
        let pageCount = document.pageCount
        let start = pageStart ?? 1
        let end = pageEnd ?? pageCount
        let firstPageOffset = pageOffset ?? 0
        guard pageCount > 0, start >= 1, end >= start, end <= pageCount,
              pageOffset == nil || pageStart != nil
        else {
            throw LocalResourcesToolError.invalidPageRange
        }

        var pages: [JSONValue] = []
        var remainingCharacters = min(characterLimit ?? maximumTextCharacters, maximumTextCharacters)
        var truncated = false
        var nextPage: Int?
        var nextPageOffset: Int?
        var hasExtractableText = false
        for pageNumber in start...end {
            try Task.checkCancellation()
            guard remainingCharacters > 0 else {
                truncated = true
                nextPage = pageNumber
                nextPageOffset = 0
                break
            }
            let fullText = document.page(at: pageNumber - 1)?.string ?? ""
            let offset = pageNumber == start ? firstPageOffset : 0
            guard offset <= fullText.count else {
                throw LocalResourcesToolError.invalidCharacterRange
            }
            let pageStartIndex = fullText.index(fullText.startIndex, offsetBy: offset)
            let pageEndIndex = fullText.index(
                pageStartIndex,
                offsetBy: remainingCharacters,
                limitedBy: fullText.endIndex
            ) ?? fullText.endIndex
            let pageText = String(fullText[pageStartIndex..<pageEndIndex])
            hasExtractableText = hasExtractableText
                || !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            pages.append(.object([
                "page": .number(Double(pageNumber)),
                "character_offset": .number(Double(offset)),
                "text": .string(pageText)
            ]))
            remainingCharacters -= pageText.count
            let consumedEnd = offset + pageText.count
            if consumedEnd < fullText.count {
                truncated = true
                nextPage = pageNumber
                nextPageOffset = consumedEnd
                break
            }
        }
        guard hasExtractableText else {
            throw LocalResourcesToolError.pdfHasNoExtractableText
        }
        return .object([
            "path": .string(url.path),
            "kind": .string("pdf"),
            "format": .string(LocalDocumentFormat.pdf.rawValue),
            "page_count": .number(Double(pageCount)),
            "page_start": .number(Double(start)),
            "page_end": .number(Double(end)),
            "pages": .array(pages),
            "next_page": nextPage.map { .number(Double($0)) } ?? .null,
            "next_page_offset": nextPageOffset.map { .number(Double($0)) } ?? .null,
            "recommended_action": truncated && start == 1 && firstPageOffset == 0
                ? .string("Use document_analysis for whole-document summary; continue read only for adjacent detail.")
                : .null,
            "truncated": .bool(truncated)
        ])
    }

    private func searchDocument(
        _ url: URL,
        query: String,
        limit: Int,
        pageStart: Int?,
        pageEnd: Int?
    ) throws -> JSONValue {
        var matches: [JSONValue] = []
        var truncated = false
        var nextPage: Int?
        if LocalDocumentFormat.detect(url: url) == .pdf {
            guard let document = PDFDocument(url: url) else {
                throw LocalResourcesToolError.unreadablePDF
            }
            guard !document.isLocked else {
                throw LocalResourcesToolError.lockedPDF
            }
            let start = pageStart ?? 1
            let requestedEnd = pageEnd ?? document.pageCount
            guard document.pageCount > 0, start >= 1,
                  requestedEnd >= start, requestedEnd <= document.pageCount
            else {
                throw LocalResourcesToolError.invalidPageRange
            }
            let scanEnd = min(requestedEnd, start + 499)
            for pageNumber in start...scanEnd {
                try Task.checkCancellation()
                guard let text = document.page(at: pageNumber - 1)?.string,
                        let context = matchContext(in: text, query: query)
                else {
                    continue
                }
                if matches.count == limit {
                    truncated = true
                    nextPage = pageNumber
                    break
                }
                matches.append(.object([
                    "page": .number(Double(pageNumber)),
                    "context": .string(context)
                ]))
            }
            if nextPage == nil, scanEnd < requestedEnd {
                truncated = true
                nextPage = scanEnd + 1
            }
        } else {
            guard pageStart == nil, pageEnd == nil else {
                throw LocalResourcesToolError.invalidPageRange
            }
            try Task.checkCancellation()
            let text = try loadText(url).text
            matches = matchContext(in: text, query: query).map {
                [.object(["context": .string($0)])]
            } ?? []
        }
        return .object([
            "path": .string(url.path),
            "query": .string(query),
            "matches": .array(matches),
            "next_page": nextPage.map { .number(Double($0)) } ?? .null,
            "truncated": .bool(truncated)
        ])
    }

    private func matchContext(in text: String, query: String) -> String? {
        guard let range = text.range(
            of: query,
            options: [.caseInsensitive],
            locale: .current
        ) else {
            return nil
        }
        let lower = text.index(range.lowerBound, offsetBy: -120, limitedBy: text.startIndex)
            ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 240, limitedBy: text.endIndex)
            ?? text.endIndex
        return String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeText(_ data: Data) -> (text: String, encoding: String)? {
        let encodings: [(String.Encoding, String)] = [
            (.utf8, "utf-8"),
            (.utf16, "utf-16"),
            (.utf16LittleEndian, "utf-16le"),
            (.utf16BigEndian, "utf-16be"),
            (.windowsCP1252, "windows-1252"),
            (.isoLatin1, "iso-8859-1")
        ]
        for (encoding, name) in encodings {
            if let text = String(data: data, encoding: encoding) {
                return (text, name)
            }
        }
        return nil
    }

    private func isPlausibleText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let suspicious = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value == 0 || (scalar.value < 0x20 && !"\n\r\t".unicodeScalars.contains(scalar)) {
                count += 1
            }
        }
        return suspicious * 100 <= text.unicodeScalars.count
    }

}

private extension LocalResourcesAccess {
    var isUnrestricted: Bool {
        if case .unrestricted = self { return true }
        return false
    }
}

private struct AuthorizedResource {
    let url: URL
    let root: URL
}

private struct LoadedText {
    let text: String
    let encoding: String
    let format: LocalDocumentFormat
    let sizeBytes: Int
}