import CoreGraphics
import CoreText
import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Local Resources Tool", .serialized)
struct LocalResourcesToolTests {
    @Test("advertises actions and supported document categories")
    func schemaContract() {
        let tool = LocalResourcesTool(authorizedRoots: [FileManager.default.temporaryDirectory])
        let description = tool.definition.function.description
        let schema = tool.definition.function.parameters

        #expect(description.contains("List directory contents"))
        #expect(description.contains("Markdown"))
        #expect(description.contains("plain text"))
        #expect(description.contains("HTML"))
        #expect(description.contains("source code"))
        #expect(description.contains("PDF"))
        #expect(description.contains("Use read to identify or preview a document"))
        #expect(!description.contains("PDFKit"))
        let pathDescription = schema.objectValue?["properties"]?
            .objectValue?["path"]?.objectValue?["description"]?.stringValue
        #expect(pathDescription?.lowercased().contains("canonical absolute posix path") == true)
        #expect(pathDescription?.contains("shell-escaped") == true)
        #expect(pathDescription?.contains("file://") == true)
        #expect(pathDescription?.contains("unescaped absolute form") == true)
        #expect(schema.objectValue?["properties"]?.objectValue?["action"]?.objectValue?["enum"] == .array([
            .string("list"),
            .string("read"),
            .string("search")
        ]))
        #expect(schema.objectValue?["properties"]?.objectValue?["character_offset"] != nil)
        #expect(schema.objectValue?["properties"]?.objectValue?["page_offset"] != nil)
    }

    @Test("lists and reads real files inside an authorized root")
    func listAndReadText() async throws {
        try await withFixtureDirectory { root in
            let textURL = root.appending(path: "notes.md")
            try "PrivateAI local resource content".write(to: textURL, atomically: true, encoding: .utf8)
            let tool = LocalResourcesTool(authorizedRoots: [root])

            let listing = try await executeObject(tool, arguments: [
                "action": .string("list"),
                "path": .string(root.path)
            ])
            guard case .array(let entries) = listing["entries"] else {
                Issue.record("Directory listing did not contain entries")
                return
            }
            #expect(entries.contains { $0.objectValue?["name"]?.stringValue == "notes.md" })

            let document = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string("notes.md")
            ])
            #expect(document["kind"] == .string("text"))
            #expect(document["text"]?.stringValue == "PrivateAI local resource content")
        }
    }

    @Test("resolves a relative path across authorized roots")
    func relativePathAcrossRoots() async throws {
        try await withFixtureDirectory { root in
            let exactFile = root.appending(path: "external.txt")
            let managedRoot = root.appending(path: "managed", directoryHint: .isDirectory)
            let managedFile = managedRoot.appending(path: "blobs/document.txt")
            try FileManager.default.createDirectory(
                at: managedFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("external".utf8).write(to: exactFile)
            try Data("managed".utf8).write(to: managedFile)
            let tool = LocalResourcesTool(authorizedRoots: [exactFile, managedRoot])

            let document = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string("blobs/document.txt")
            ])

            #expect(document["text"] == .string("managed"))
        }
    }

    @Test("continues bounded text reads without losing content")
    func boundedTextContinuation() async throws {
        try await withFixtureDirectory { root in
            let textURL = root.appending(path: "bounded.txt")
            try "ABCDEFGHIJK".write(to: textURL, atomically: true, encoding: .utf8)
            let tool = LocalResourcesTool(
                access: .restricted([root]),
                maximumTextCharacters: 5
            )

            let first = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(textURL.path)
            ])
            #expect(first["text"] == .string("ABCDE"))
            #expect(first["next_character_offset"] == .number(5))
            #expect(first["truncated"] == .bool(true))

            let second = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(textURL.path),
                "character_offset": .number(5)
            ])
            #expect(second["text"] == .string("FGHIJ"))
            #expect(second["next_character_offset"] == .number(10))
        }
    }

    @Test("keeps multibyte text as valid resumable JSON through ToolRuntime")
    func multibyteTextThroughRuntime() async throws {
        try await withFixtureDirectory { root in
            let textURL = root.appending(path: "multibyte.txt")
            try String(repeating: "文😀\n", count: 2_000)
                .write(to: textURL, atomically: true, encoding: .utf8)
            let runtime = try ToolRuntime(tools: [
                LocalResourcesTool(
                    access: .restricted([root]),
                    maximumTextCharacters: 2_000
                )
            ])
            let call = ToolCall(function: ToolFunctionCall(
                index: 0,
                name: "local_resources",
                arguments: [
                    "action": .string("read"),
                    "path": .string(textURL.path)
                ]
            ))

            let execution = await runtime.execute(call)
            let value = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(execution.content.utf8)
            )
            let document = try #require(value.objectValue)

            #expect(execution.succeeded)
            #expect(execution.content.utf8.count < 16 * 1_024)
            #expect(document["text"]?.stringValue?.count == 2_000)
            #expect(document["next_character_offset"] == .number(2_000))
            #expect(document["truncated"] == .bool(true))
        }
    }

    @Test("decodes UTF-16 text without replacement characters")
    func utf16Text() async throws {
        try await withFixtureDirectory { root in
            let textURL = root.appending(path: "utf16.txt")
            try #require("PrivateAI 文档".data(using: .utf16)).write(to: textURL)
            let tool = LocalResourcesTool(access: .restricted([root]))

            let document = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(textURL.path)
            ])

            #expect(document["text"] == .string("PrivateAI 文档"))
            #expect(document["encoding"] == .string("utf-16"))
        }
    }

    @Test("reads a real PDF text layer with PDFKit")
    func readPDF() async throws {
        try await withFixtureDirectory { root in
            let pdfURL = root.appending(path: "sample.pdf")
            try createTextPDF(
                at: pdfURL,
                pages: [
                    "PrivateAI PDFKit page one",
                    "Second page contains architecture details"
                ]
            )
            let tool = LocalResourcesTool(authorizedRoots: [root])
            let document = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(pdfURL.path),
                "page_start": .number(1),
                "page_end": .number(2)
            ])
            guard case .array(let pages) = document["pages"] else {
                Issue.record("PDF result did not contain pages")
                return
            }

            #expect(document["kind"] == .string("pdf"))
            #expect(document["page_count"] == .number(2))
            #expect(pages.count == 2)
            #expect(pages[0].objectValue?["text"]?.stringValue?.contains("PDFKit page one") == true)
            #expect(pages[1].objectValue?["text"]?.stringValue?.contains("architecture details") == true)
        }
    }

    @Test("continues a bounded PDF read within a page")
    func boundedPDFContinuation() async throws {
        try await withFixtureDirectory { root in
            let pdfURL = root.appending(path: "bounded.pdf")
            try createTextPDF(at: pdfURL, pages: ["ABCDEFGHIJK"])
            let tool = LocalResourcesTool(
                access: .restricted([root]),
                maximumTextCharacters: 5
            )

            let first = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(pdfURL.path),
                "page_start": .number(1),
                "page_end": .number(1)
            ])
            #expect(first["next_page"] == .number(1))
            #expect(first["next_page_offset"] == .number(5))
            #expect(first["truncated"] == .bool(true))

            let second = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(pdfURL.path),
                "page_start": .number(1),
                "page_end": .number(1),
                "page_offset": .number(5)
            ])
            guard case .array(let pages) = second["pages"] else {
                Issue.record("Continued PDF result did not contain pages")
                return
            }
            #expect(pages.first?.objectValue?["character_offset"] == .number(5))
            #expect(pages.first?.objectValue?["text"]?.stringValue?.hasPrefix("FGHIJ") == true)
        }
    }

    @Test("reports a PDF without an extractable text layer")
    func imageOnlyPDF() async throws {
        try await withFixtureDirectory { root in
            let pdfURL = root.appending(path: "image-only.pdf")
            try createTextPDF(at: pdfURL, pages: [""])
            let tool = LocalResourcesTool(access: .restricted([root]))

            await #expect(throws: LocalResourcesToolError.pdfHasNoExtractableText) {
                try await tool.execute(arguments: [
                    "action": .string("read"),
                    "path": .string(pdfURL.path)
                ])
            }
        }
    }

    @Test("reads substantive content from a committed research paper")
    func readExternalPDF() async throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "pdfjs-tracemonkey",
                withExtension: "pdf",
                subdirectory: "Fixtures"
            )
        )
        let tool = LocalResourcesTool(
            authorizedRoots: [fixture.deletingLastPathComponent()]
        )
        let document = try await executeObject(tool, arguments: [
            "action": .string("read"),
            "path": .string(fixture.path)
        ])
        guard case .array(let pages) = document["pages"] else {
            Issue.record("External PDF result did not contain pages")
            return
        }

        let extractedCharacterCount = pages.reduce(0) {
            $0 + ($1.objectValue?["text"]?.stringValue?.count ?? 0)
        }

        #expect(document["kind"] == .string("pdf"))
        #expect(document["page_count"] == .number(14))
        #expect(pages.count == 14)
        #expect(extractedCharacterCount > 80_000)
        #expect(pages[0].objectValue?["text"]?.stringValue?.contains(
            "Trace-based Just-in-Time Type Specialization for Dynamic"
        ) == true)
        #expect(pages[0].objectValue?["text"]?.stringValue?.contains(
            "Dynamic languages such as JavaScript are more difficult"
        ) == true)
        #expect(pages[2].objectValue?["text"]?.stringValue?.contains(
            "Figure 3. LIR snippet for sample program"
        ) == true)
        #expect(pages[13].objectValue?["text"]?.stringValue?.contains("References") == true)
        #expect(pages[13].objectValue?["text"]?.stringValue?.contains(
            "Compilers: Principles"
        ) == true)

        let searchResult = try await executeObject(tool, arguments: [
            "action": .string("search"),
            "path": .string(fixture.path),
            "query": .string("js_Array_set")
        ])
        guard case .array(let matches) = searchResult["matches"] else {
            Issue.record("Research paper search did not contain matches")
            return
        }

        #expect(matches.count == 1)
        #expect(matches[0].objectValue?["page"] == .number(3))
        #expect(matches[0].objectValue?["context"]?.stringValue?.contains("js_Array_set") == true)
    }

    @Test(
        "reads declared text document formats",
        arguments: [
            DocumentFixture(name: "README.md", format: "markdown", content: "# PrivateAI\nMarkdown body", expected: "# PrivateAI"),
            DocumentFixture(name: "notes.txt", format: "plain_text", content: "Plain text body", expected: "Plain text body"),
            DocumentFixture(name: "data.json", format: "json", content: "{\"value\":42}", expected: "\"value\":42"),
            DocumentFixture(name: "table.csv", format: "csv", content: "name,value\nPrivateAI,42", expected: "PrivateAI,42"),
            DocumentFixture(name: "config.yaml", format: "yaml", content: "name: PrivateAI", expected: "name: PrivateAI"),
            DocumentFixture(name: "Example.swift", format: "source_code", content: "struct PrivateAI {}", expected: "struct PrivateAI"),
            DocumentFixture(name: "LICENSE", format: "plain_text", content: "Extensionless text", expected: "Extensionless text"),
            DocumentFixture(name: "page.html", format: "html", content: "<html><head><style>hidden</style></head><body><h1>PrivateAI</h1><script>bad()</script><p>Readable HTML</p></body></html>", expected: "<h1>PrivateAI</h1>")
        ]
    )
    func textFormats(fixture: DocumentFixture) async throws {
        try await withFixtureDirectory { root in
            try fixture.content.write(
                to: root.appending(path: fixture.name),
                atomically: true,
                encoding: .utf8
            )
            let tool = LocalResourcesTool(authorizedRoots: [root])
            let document = try await executeObject(tool, arguments: [
                "action": .string("read"),
                "path": .string(fixture.name)
            ])

            #expect(document["format"] == .string(fixture.format))
            #expect(document["text"]?.stringValue?.contains(fixture.expected) == true)
            if fixture.format == "html" {
                #expect(document["text"]?.stringValue == fixture.content)
                #expect(document["text"]?.stringValue?.contains("<script>bad()</script>") == true)
                #expect(document["text"]?.stringValue?.contains("<style>hidden</style>") == true)
            }
        }
    }

    @Test("searches a real PDF by page")
    func searchPDF() async throws {
        try await withFixtureDirectory { root in
            let pdfURL = root.appending(path: "searchable.pdf")
            try createTextPDF(at: pdfURL, pages: ["Alpha", "PrivateAI architecture boundary"])
            let tool = LocalResourcesTool(authorizedRoots: [root])
            let result = try await executeObject(tool, arguments: [
                "action": .string("search"),
                "path": .string("searchable.pdf"),
                "query": .string("architecture")
            ])
            guard case .array(let matches) = result["matches"] else {
                Issue.record("PDF search did not contain matches")
                return
            }

            #expect(matches.count == 1)
            #expect(matches[0].objectValue?["page"] == .number(2))
            #expect(matches[0].objectValue?["context"]?.stringValue?.contains("architecture") == true)
        }
    }

    @Test("continues PDF search after the match limit")
    func boundedPDFSearch() async throws {
        try await withFixtureDirectory { root in
            let pdfURL = root.appending(path: "bounded-search.pdf")
            try createTextPDF(
                at: pdfURL,
                pages: ["needle one", "needle two", "needle three"]
            )
            let tool = LocalResourcesTool(access: .restricted([root]))

            let first = try await executeObject(tool, arguments: [
                "action": .string("search"),
                "path": .string(pdfURL.path),
                "query": .string("needle"),
                "limit": .number(1)
            ])
            #expect(first["truncated"] == .bool(true))
            #expect(first["next_page"] == .number(2))

            let second = try await executeObject(tool, arguments: [
                "action": .string("search"),
                "path": .string(pdfURL.path),
                "query": .string("needle"),
                "limit": .number(1),
                "page_start": .number(2)
            ])
            guard case .array(let matches) = second["matches"] else {
                Issue.record("Continued PDF search did not contain matches")
                return
            }
            #expect(matches.first?.objectValue?["page"] == .number(2))
            #expect(second["next_page"] == .number(3))
        }
    }

    @Test("search handles Unicode case expansion without invalid indices")
    func unicodeCaseExpansionSearch() async throws {
        try await withFixtureDirectory { root in
            let textURL = root.appending(path: "unicode.txt")
            try "Before İSTANBUL after".write(
                to: textURL,
                atomically: true,
                encoding: .utf8
            )
            let tool = LocalResourcesTool(access: .restricted([root]))

            let result = try await executeObject(tool, arguments: [
                "action": .string("search"),
                "path": .string(textURL.path),
                "query": .string("İ")
            ])
            guard case .array(let matches) = result["matches"] else {
                Issue.record("Unicode search did not contain matches")
                return
            }

            #expect(matches.first?.objectValue?["context"]?.stringValue == "Before İSTANBUL after")
        }
    }

    @Test("rejects paths and symlinks outside authorized roots")
    func rejectsEscapes() async throws {
        try await withFixtureDirectory { root in
            let outside = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension("txt")
            try "outside".write(to: outside, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: outside) }
            let symlink = root.appending(path: "escape.txt")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            let tool = LocalResourcesTool(authorizedRoots: [root])

            await #expect(throws: LocalResourcesToolError.outsideAuthorizedRoots(symlink.path)) {
                try await tool.execute(arguments: [
                    "action": .string("read"),
                    "path": .string(symlink.path)
                ])
            }
        }
    }

    @Test("an explicit empty restricted scope denies all paths")
    func emptyRestrictedScope() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "restricted-\(UUID().uuidString).txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let tool = LocalResourcesTool(access: .restricted([]))

        await #expect(throws: LocalResourcesToolError.outsideAuthorizedRoots(outside.path)) {
            try await tool.execute(arguments: [
                "action": .string("read"),
                "path": .string(outside.path)
            ])
        }
    }

    @Test("empty authorization scope reads any absolute path the process can access")
    func unrestrictedWhenNoRoots() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "unrestricted-\(UUID().uuidString).txt")
        try "紫色犀牛在月光下跳舞".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let tool = LocalResourcesTool(authorizedRoots: [])

        let output = try await tool.execute(arguments: [
            "action": .string("read"),
            "path": .string(outside.path)
        ])
        #expect(output.contains("犀牛"))
    }

    @Test(
        "model selects local resources and reads a real PDF with PDFKit",
        .enabled(if: ProcessInfo.processInfo.environment["PRIVATEAI_RUN_HEADLESS_MODEL_EVALS"] == "1")
    )
    func pdfThroughAgentLoop() async throws {
        try await withFixtureDirectory { root in
            let pdfURL = root.appending(path: "agent-document.pdf")
            try createTextPDF(
                at: pdfURL,
                pages: ["PrivateAI document verdict: ORCHID-42 is approved."]
            )
            let runtime = AgentRuntime(
                provider: try OllamaProvider(),
                toolRuntime: try ToolRuntime(tools: [
                    LocalResourcesTool(authorizedRoots: [root]),
                    AppleServicesTool(),
                    WebTool()
                ]),
                configuration: AgentConfiguration(
                    model: "qwen3.8:latest",
                    keepAlive: "30m",
                    options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 128),
                    maximumToolCallsPerRound: 2,
                    maximumToolCallsTotal: 2
                )
            )

            let warmup = try await runtime.warmUp()
            let result = try await runtime.run(
                prompt: "Read the PDF at \(pdfURL.path) and report its exact verdict code."
            )
            let calls = result.messages.flatMap { $0.toolCalls ?? [] }
            let toolMessages = result.messages.filter { $0.role == .tool }
            print(
                "REAL_PDF_AGENT calls=\(calls.map { $0.function.name }) "
                    + "actions=\(calls.compactMap { $0.function.arguments["action"]?.stringValue }) "
                    + "prefix_tokens=\(warmup.prefixPromptTokenCount ?? -1) "
                    + "requests=\(result.performance.modelRequestCount) "
                    + "total=\(result.performance.totalSeconds)s"
            )

            #expect(!calls.isEmpty)
            #expect(calls.allSatisfy { $0.function.name == "local_resources" })
            #expect(toolMessages.contains { $0.content.contains("ORCHID-42") })
            #expect(result.text.contains("ORCHID-42"))
            #expect(result.performance.modelRequestCount >= 2)
        }
    }
}

struct DocumentFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let format: String
    let content: String
    let expected: String

    var testDescription: String {
        name
    }
}

private func withFixtureDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "PrivateAIToolsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func createTextPDF(at url: URL, pages: [String]) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)

    for text in pages {
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func executeObject(
    _ tool: LocalResourcesTool,
    arguments: [String: JSONValue]
) async throws -> [String: JSONValue] {
    let content = try await tool.execute(arguments: arguments)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
    return try #require(value.objectValue)
}