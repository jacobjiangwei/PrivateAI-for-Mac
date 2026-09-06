# PrivateAI Help

## Current status

PrivateAI is an actively developed native macOS assistant. Signed and notarized development releases are available from GitHub Releases.

The App requires a local Ollama installation and compatible chat model. It provides persistent conversations, model selection, Markdown rendering, built-in Tools, and managed document attachments. Searchable PDFs and text formats support bounded detail reads; whole-document work uses resumable hierarchical summaries stored locally.

## Document analysis

Attach a supported document with the paperclip button or Finder drag and drop, or explicitly include its local path in the request, then ask for a summary or analysis. Paths copied from a shell, quoted paths, tilde-prefixed paths, and local file URLs are normalized to canonical absolute paths before a document Tool call. Long jobs save private checkpoints under `~/.privateAI/jobs/document-summaries`; stopping and repeating the same document, goal, and model resumes completed work. Scanned PDFs without an extractable text layer are not currently supported.

If document analysis fails, include the error message and App version in a private report. Do not attach the document to a public issue.

## Development build

Open `Private AI/Private AI.xcodeproj` in a compatible Xcode version and build the `Private AI` target. The deployment target and SDK requirements are currently defined by the Xcode project and may change during the rebuild.

## Downloaded release

Download `PrivateAI.dmg` and, optionally, `PrivateAI.dmg.sha256` from the same GitHub Release. The checksum provides an optional integrity check before opening the DMG. Releases are signed with Developer ID, notarized by Apple, and assessed by Gatekeeper in CI before publication.

## Contact

Open a GitHub issue with the commit, macOS version, Xcode version, and exact build or runtime error. Do not post sensitive documents, private data, API keys, or credentials. Report security vulnerabilities privately using the process in `SECURITY.md`.
