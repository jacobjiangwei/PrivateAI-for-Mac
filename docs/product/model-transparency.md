# Model Input and Generation Diagnostics

The transcript separates user input, raw AI input, thinking, Tool calls, Tool results, and final answers. Intermediate model answers and warmup requests are labeled separately. Existing conversations retain their legacy Tool rows; raw inputs from runs made before tracing was added cannot be reconstructed.

Raw AI input is captured from the encoded Ollama HTTP body before submission, including system instructions, messages, Tool schemas, options, and any encoded images. Trace collection follows the current task into document-analysis subrequests. It is local persistent conversation data, never a general runtime log and never input to the next conversation turn. Raw text is displayed without Markdown or HTML interpretation. WebView updates transmit changed messages only and retain at most one render in flight.

## Device Context

At the start of each user turn the App samples local time, UTC offset, time zone, locale, up to three preferred languages, macOS version, and architecture. One compact line is appended to that task's model-facing prompt. Tool rounds retain that same original task context; they do not resample time or append another copy. Subsequent user turns sample again. Prewarming does not include the changing timestamp. No host name, account name, serial number, location lookup, or permission request is involved. This context reflects the Mac's clock, not an independently synchronized time source.

## Metrics

- Live token rate is an estimate based on nonempty thinking and text chunks in a rolling two-second window. A chunk is not guaranteed to be one token. Exact counts are supplied by Ollama only when each model request completes.
- TTFT is the elapsed user-turn time to the first thinking or text chunk, not the first final-answer text. First answer is a separate metric. Before any output, the displayed time is elapsed waiting time, not a measured TTFT.
- Final token rate uses Ollama evaluation counts and durations. Input and output totals include completed auxiliary requests but exclude warmup. Input totals count repeated prompt evaluation across requests.
- Request bytes are exact UTF-8 HTTP-body bytes. Tool-schema bytes are an estimate from re-encoding that JSON field, not a token count. Per-request metadata includes the request timestamp, first-output latency, prompt tokens, output tokens, and provider load/prefill/decode durations when available.
- Raw history reveals request size and repeated Tool evidence; it cannot alone prove why a provider spent time on prompt evaluation.

## Verification

Deterministic tests cover local date rollover, DST, locale normalization, raw persistence, diagnostic-history exclusion, partial-request finalization, thinking metrics, six-role WebView rendering, and bounded rendering. The signed App acceptance entry exercises the production composer send path, real Ollama, catalog, executors, database, and WebView. Optional trace acceptance observes visible streaming updates and compares raw DOM against persisted messages. XCTest UI tests additionally inspect native metric controls and capture window screenshots; a terminated runner is a blocked check, not a passing capability test.