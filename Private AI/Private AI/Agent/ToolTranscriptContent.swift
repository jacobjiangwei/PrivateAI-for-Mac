import Foundation
import LLMCore

enum ToolTranscriptContent {
    static func safeArguments(
        name: String,
        arguments: [String: JSONValue],
        documentPrivacyMode: Bool = false
    ) -> [String: JSONValue] {
        if documentPrivacyMode, name != "local_resources" {
            return [:]
        }
        if name == "terminal" {
            guard let action = arguments["action"]?.stringValue,
                  ["run", "wait", "stop"].contains(action) else {
                return [:]
            }
            var safe: [String: JSONValue] = ["action": .string(action)]
            for key in [
                "command", "working_directory", "job_id", "checkpoint_seconds",
                "timeout_seconds"
            ] {
                safe[key] = arguments[key]
            }
            return safe.compactMapValues { $0 }
        }
        if name == "browser" {
            guard let action = arguments["action"]?.stringValue else { return [:] }
            var safe: [String: JSONValue] = ["action": .string(action)]
            for key in [
                "session_id", "frame_id", "representation", "x", "y", "delta_x",
                "delta_y", "mode", "key"
            ] {
                safe[key] = arguments[key]
            }
            return safe.compactMapValues { $0 }
        }
        guard name == "local_resources" else {
            return ["web", "apple_services"].contains(name) ? arguments : [:]
        }
        guard let action = arguments["action"]?.stringValue,
              ["list", "read", "search"].contains(action)
        else {
            return [:]
        }
        return ["action": .string(action)]
    }

    static func started(
        name: String,
        arguments: [String: JSONValue],
        documentPrivacyMode: Bool = false
    ) -> String {
        let input = encodedJSON(.object(safeArguments(
            name: name,
            arguments: arguments,
            documentPrivacyMode: documentPrivacyMode
        )))
        return """
        **Tool:** `\(name)`

        **Status:** Running

        **Input**

        ```json
        \(input)
        ```
        """
    }

    static func finished(
        _ execution: ToolExecution,
        documentPrivacyMode: Bool = false
    ) -> String {
        if documentPrivacyMode || execution.name == "local_resources" {
            return """
            **Tool:** `\(execution.name)`

            **Status:** \(execution.succeeded ? "Succeeded" : "Failed")

            Document content was available to the model for this run and is not stored in conversation history.
            """
        }
        if execution.name == "browser" {
            return """
            **Tool:** `browser`

            **Status:** \(execution.succeeded ? "Succeeded" : "Failed")

            **Input**

            ```json
            \(encodedJSON(.object(safeArguments(
                name: execution.name,
                arguments: execution.arguments
            ))))
            ```

            **Output**

            ```json
            \(encodedJSON(.object(safeBrowserOutput(execution.content))))
            ```

            The browser screenshot was available to the model for this run and is not stored in conversation history.
            """
        }
        return """
        **Tool:** `\(execution.name)`

        **Status:** \(execution.succeeded ? "Succeeded" : "Failed")

        **Input**

        ```json
        \(encodedJSON(.object(execution.arguments)))
        ```

        **Output**

        ```json
        \(execution.content)
        ```
        """
    }

    private static func safeBrowserOutput(_ content: String) -> [String: JSONValue] {
        guard let data = content.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return [:]
        }
        let allowed = [
            "status", "error", "message", "session_id", "document_id", "frame_id", "revision",
            "validated_origin", "image_width", "image_height", "coordinate_space",
            "scroll_x", "scroll_y", "visual_stability", "representation",
            "input_backend"
        ]
        return allowed.reduce(into: [:]) { safe, key in
            safe[key] = object[key]
        }.compactMapValues { $0 }
    }

    private static func encodedJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else {
            return "{}"
        }
        return String(decoding: prettyData, as: UTF8.self)
    }
}