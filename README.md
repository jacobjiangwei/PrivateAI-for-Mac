# PrivateAI

PrivateAI is being rebuilt as a native, on-device macOS assistant. The intended product direction is documented in [the target architecture draft](docs/product/target-architecture-draft.md).

## Status

The repository contains a development build of a native macOS chat application with Ollama model integration, persistent conversations, Markdown transcript rendering, built-in tools, and managed local document attachments. Expect breaking changes; current builds are for development only.

## Supported scenarios

### Private local conversations

- Discover and switch between compatible models installed in the local Ollama service.
- Stream model thinking and answers, stop an active generation, and inspect time-to-first-token and generation speed.
- Keep conversations in a local SwiftData store and render Markdown responses in the native macOS interface.

### Work with local documents

- Attach documents with the file picker or Finder drag and drop, or reference an existing local file directly in a request.
- Understand canonical, shell-escaped, quoted, tilde-prefixed, and local `file://` path representations while granting access only to the referenced file.
- Preview and search bounded document content, including searchable PDFs, Markdown, text, structured text, HTML, and common source-code formats.
- Summarize or review whole documents with resumable hierarchical analysis and private local checkpoints.
- Keep document requests isolated from public web and Apple service tools. Scanned PDFs without an extractable text layer are not currently supported because OCR is not implemented.

See [Document Attachments](docs/product/document-attachments.md) for the verified format matrix, limits, storage model, and failure states.

### Find current public information

- Search the public web for current facts, news, weather, videos, products, places, and sources.
- Fetch and extract bounded content from known public HTTPS pages.

### Use native Mac context

- Inspect device, locale, time-zone, storage, power, network, and current permission status through direct native integrations.
- Available native actions also cover location and MapKit place search, calendar and reminder-list access, contact search, notification status, and opening a user-visible HTTPS URL.
- Protected macOS actions remain subject to the App's real authorization state and system permission prompts. Their current App-hosted end-to-end coverage is incomplete, so availability on a particular Mac must be confirmed by a successful Tool result rather than inferred from the catalog.

### Run non-interactive terminal work

- Ordinary conversations receive the `terminal` capability automatically when the
	signed worker is available. Commands start in the App-managed
	`~/.privateAI/workspaces/default` directory.
- Choose a folder from the conversation header only when a task needs a different
	filesystem root. Returning to the PrivateAI workspace keeps terminal available.
- Run general `/bin/zsh -dfc` commands, network and process diagnostics, builds, tests,
	scripts, pipelines, and package managers. Commands remain visible with working
	directory, elapsed time, checkpoint status, and Stop.
- Commands that remain active return a bounded checkpoint after 60 seconds by default;
	stdout and stderr continue draining to bounded local logs without waking the model
	for every line.
- Cancellation, timeout, App shutdown, worker failure, and transport timeout terminate
	the recorded process group. Document privacy mode does not expose terminal.
- Phase 1 does not run self-daemonizing or detached persistent processes. Commands must
	remain attached to the supervised job; persistent servers require a later explicit
	lifecycle and isolation design.
- Interactive PTY applications, secret input, and structured coding-file edit Tools are
	not implemented yet. The current terminal phase is not full Copilot-style coding
	agent parity.

See [Terminal Execution Design](docs/product/terminal-execution-design.md) for verified
limits, acceptance evidence, and the remaining implementation phases.

## Requirements

- macOS and an Xcode version that support the SDK and deployment target configured in the project
- Ollama with a compatible local chat model installed

The App discovers locally installed Ollama models at runtime; availability and model performance depend on the local Ollama installation and hardware.

## Build

1. Open `Private AI/Private AI.xcodeproj` in Xcode.
2. Select the `Private AI` target.
3. Build and run the macOS app.

The checked-in Team ID and bundle identifiers are public project metadata, not signing credentials. Maintainers with the matching local development certificate can build immediately. Other contributors should select their own Team and use a unique bundle identifier under Signing & Capabilities. The repository intentionally contains no signing certificate, private key, provisioning profile, API token, password, or notarization credential.

## Tests

The repository includes Swift package tests, macOS App unit tests, direct framework integrations, real PDF fixtures, and opt-in live Ollama scenarios. Live model and network tests require their corresponding local or external services and must be reported separately from deterministic contract tests.

## Releases

Signed and notarized macOS DMGs are published through [GitHub Releases](https://github.com/jacobjiangwei/Private-AI-on-your-device/releases). Each push to `main` runs the release workflow, verifies Developer ID signatures and Gatekeeper assessment, notarizes and staples the DMG, and publishes a SHA-256 checksum. See [Direct Release](docs/direct-release.md) for the verified release flow and maintainer configuration.

## Privacy

Model inference runs through the user's local Ollama service. Selected documents are copied into private managed storage under `~/.privateAI/artifacts`; document bytes and extracted text are not stored in message rows or runtime logs. Built-in network tools can access public network resources when the model invokes them. See [the privacy policy](docs/privacy-policy.md) and [Document Attachments](docs/product/document-attachments.md) for the current development-state data flow.

## Security

Do not post secrets, private documents, or chat content in public issues. See [SECURITY.md](SECURITY.md) for private vulnerability reporting and supported-version expectations.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

PrivateAI source code is available under the [Apache License 2.0](LICENSE). Third-party notices must be updated whenever dependencies or redistributable components are introduced.