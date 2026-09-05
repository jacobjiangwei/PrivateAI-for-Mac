#!/bin/bash

set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIRECTORY"

DERIVED_DATA_PATH="${PRIVATEAI_ACCEPTANCE_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Private_AI-acceptance}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Private AI.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Private AI"
RESULT_DIRECTORY="$(mktemp -d /tmp/privateai-acceptance-results.XXXXXX)"
VALIDATOR="$RESULT_DIRECTORY/validate.swift"

cleanup() {
  rm -rf "$RESULT_DIRECTORY"
}
trap cleanup EXIT

xcodebuild build \
  -project "Private AI/Private AI.xcodeproj" \
  -scheme "Private AI" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile

codesign --verify --deep --strict "$APP_PATH"

cat > "$VALIDATOR" <<'SWIFT'
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("usage: validate <scenario> <result>") }
let scenario = CommandLine.arguments[1]
let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])
let data = try Data(contentsOf: resultURL)
guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    fail("invalid acceptance result")
}
guard result["status"] as? String == "completed" else {
    fail("\(scenario) failed: \(result["error"] as? String ?? "unknown error")")
}
guard result["assistant_status"] as? String == "complete" else {
    fail("\(scenario) assistant did not complete: \(result["assistant_error"] ?? "")")
}
let answer = result["assistant_content"] as? String ?? ""
let toolMessages = result["tool_messages"] as? [[String: Any]] ?? []
let toolNames = toolMessages.compactMap { $0["name"] as? String }

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail("\(scenario): \(message)\nanswer=\(answer)") }
}

switch scenario {
case "code":
    require(toolNames.isEmpty, "expected no Tool calls, got \(toolNames)")
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        answer + "\nassert sum_even_squares([1, 2, 3, 4, -6]) == 56\n"
            + "assert sum_even_squares([]) == 0\nprint('CODE_RESULT=PASS')"
    ]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
    let stderr = String(decoding: try error.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
    require(process.terminationStatus == 0, "returned code failed hidden tests: \(stderr)")
    require(stdout.contains("CODE_RESULT=PASS"), "hidden code test did not complete")
case "pdf":
    require((result["attachment_count"] as? Int) == 1, "expected one attachment")
    require(!toolNames.isEmpty, "expected a document Tool")
    require(Set(toolNames).isSubset(of: ["local_resources", "document_analysis"]), "unexpected Tools \(toolNames)")
    require(answer.contains("ORCHID-42"), "missing ORCHID-42")
    require(answer.contains("IRIS-73"), "missing IRIS-73")
case "ping":
    require(toolNames == ["terminal"], "expected exactly one terminal call, got \(toolNames)")
    require(answer.contains("PING_EXIT=0"), "missing successful ping exit")
    require(answer.contains("PACKET_LOSS=0.0%") || answer.contains("PACKET_LOSS=0%"), "wrong packet loss")
    require(toolMessages.contains { ($0["content"] as? String)?.contains("packet loss") == true }, "missing real ping output")
case "apple":
    require(toolNames.count >= 3 && toolNames.allSatisfy { $0 == "apple_services" }, "unexpected Tools \(toolNames)")
    guard let groundTruth = result["native_ground_truth"] as? [String: Any],
          let zone = groundTruth["time_zone"] as? [String: Any],
          let identifier = zone["identifier"] as? String,
          let location = groundTruth["current_location"] as? [String: Any],
          let place = location["place"] as? [String: Any],
          let city = place["city"] as? String else {
        fail("apple: native ground truth missing time zone or city")
    }
    let url = ProcessInfo.processInfo.environment["PRIVATEAI_EXPECTED_URL"] ?? ""
    require(answer.contains("TZ_IDENTIFIER=\(identifier)"), "wrong time zone")
    require(answer.localizedCaseInsensitiveContains("CITY=\(city)"), "wrong city")
    require(answer.contains("URL_OPENED=\(url)"), "wrong opened URL")
    require(toolMessages.contains {
      guard let content = $0["content"] as? String else { return false }
      return (content.contains("\"opened\":true") || content.contains("\"opened\" : true"))
        && content.contains(url)
    }, "open_url did not succeed")
default:
    fail("unknown scenario \(scenario)")
}

print("ACCEPTANCE_\(scenario.uppercased())=PASS")
SWIFT

run_scenario() {
  local name=$1
  local prompt=$2
  shift 2
  local result="$RESULT_DIRECTORY/$name.json"
  rm -f "$result"
  env \
    PRIVATEAI_RUN_APP_ACCEPTANCE=1 \
    PRIVATEAI_ACCEPTANCE_RESULT="$result" \
    PRIVATEAI_ACCEPTANCE_PROMPT="$prompt" \
    PRIVATEAI_ACCEPTANCE_TIMEOUT_SECONDS=600 \
    "$@" \
    "$APP_EXECUTABLE"
  /usr/bin/swift "$VALIDATOR" "$name" "$result"
}

if (( $# > 0 )); then
  SCENARIOS=("$@")
else
  SCENARIOS=(code pdf ping apple)
fi
for scenario in "${SCENARIOS[@]}"; do
  case "$scenario" in
    code)
      run_scenario code \
        'Return only valid Python source code, with no Markdown fence or explanation. Define sum_even_squares(values), which returns the sum of the squares of every even integer in values. It must return 0 for an empty list. Answer from your programming knowledge; do not inspect this Mac or use any tool.'
      ;;
    pdf)
      run_scenario pdf \
        'Read the attached small PDF and report the exact verification code from every page.' \
        PRIVATEAI_ACCEPTANCE_FIXTURE=small_pdf
      ;;
    ping)
      PING_WORKSPACE="$RESULT_DIRECTORY/ping-workspace"
      mkdir -p "$PING_WORKSPACE"
      run_scenario ping \
        'Check this Mac loopback network by running /sbin/ping -c 1 127.0.0.1 with the command-line capability. Base the answer only on the command result. End with exactly PING_EXIT=<integer> and PACKET_LOSS=<percentage> on separate lines.' \
        PRIVATEAI_RUN_TERMINAL_APP_ACCEPTANCE=1 \
        PRIVATEAI_EXECUTION_WORKSPACE="$PING_WORKSPACE"
      ;;
    apple)
      APPLE_URL="https://example.com/privateai-native-$(uuidgen | tr '[:upper:]' '[:lower:]')"
      PRIVATEAI_EXPECTED_URL="$APPLE_URL" run_scenario apple \
        "Use native macOS services to determine the current time-zone identifier and current city, then open this exact HTTPS URL: $APPLE_URL. Base the answer only on native Tool results. End with TZ_IDENTIFIER=<identifier>, CITY=<city>, and URL_OPENED=$APPLE_URL on separate lines." \
        PRIVATEAI_ACCEPTANCE_NATIVE_GROUND_TRUTH=1
      ;;
    *)
      echo "Unknown acceptance scenario: $scenario" >&2
      exit 64
      ;;
  esac
done