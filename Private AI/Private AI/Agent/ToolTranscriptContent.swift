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