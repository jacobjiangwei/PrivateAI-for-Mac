# PrivateAI Privacy Policy

Effective date: 2026-09-11

PrivateAI is currently a development build, not a supported product release. This policy describes the code currently checked into this repository; planned behavior belongs in product and architecture documents, not in this current-data-flow statement.

## Core AI processing

PrivateAI sends the system prompt, conversation context, current request, selected Tool schemas, and Tool results to the user's local Ollama service. The checked-in App does not configure a cloud model provider. Ollama is a separate local process with its own configuration and data handling.

At the start of each user turn, the App samples a compact local device context: date and time with UTC offset, time-zone identifier, locale, up to three preferred languages, macOS version, and processor architecture. This snapshot accompanies the task across its model/Tool rounds; it is not resampled or repeatedly appended during that task. It excludes the device name, user name, serial number, and location. Locale is not treated as evidence of location.

## Data stored on the Mac

PrivateAI stores conversations and messages in a local SwiftData database, including raw model request bodies, model thinking, intermediate and final answers, Tool arguments, and full Tool result text. Raw request bodies include the actual system prompt, selected Tool schemas, model options, device context, and the history sent for that request. They may contain extracted document text, paths, queries, intermediate summaries, and encoded images. These diagnostic rows are not fed back into later conversation history. Deleting a conversation deletes its diagnostic message rows as well.

Selected document bytes are also copied into content-addressed managed storage under `~/.privateAI/artifacts`. For whole-document analysis, intermediate page, chunk, and reduction summaries are stored as private checkpoint files under `~/.privateAI/jobs/document-summaries` so interrupted work can resume and identical work can be reused. Raw transcript records are local persistent copies, not ephemeral previews. Secret interactive input delivered through the secure terminal input channel must never enter model messages or these records.

PrivateAI writes bounded operational metadata to private files under `~/.privateAI/logs`. Current logs omit prompt text, model answer text, local document paths, local document search queries, and local document Tool output. A one-time privacy migration deletes logs created by earlier development builds that may have contained those values.

## Network features

PrivateAI includes public web and Apple service Tools. When the model invokes a network Tool, the requested query, URL, coordinates, or other necessary Tool input may be sent to the relevant public endpoint or Apple service. The checked-in App does not implement advertising or product analytics.

Conversations containing document attachments run in document privacy mode. In that mode the model is given only the local document analysis and bounded local resource Tools; public web and Apple service Tools are unavailable, so document content cannot be silently forwarded through those capabilities.

## File access

Users can select documents in a system file panel or drop supported Finder file URLs onto the composer. PrivateAI accesses the selected source while importing it, then uses the managed copy for later reads. The model-facing document Tool is restricted to the managed artifacts root. Searchable PDFs are read with PDFKit; scanned PDFs without a text layer are not processed with OCR.

When a user explicitly includes the absolute path of an existing supported document in the current request, PrivateAI grants the local document Tools access to that exact file for the request. This does not grant access to sibling files or the containing directory. Requests with local documents expose only local document Tools, not public web or Apple service Tools.

## Security and retention

The current development target has App Sandbox disabled. Managed artifact and log directories are set to owner-only permissions (`0700`), and managed files are set to `0600`. Deleting a conversation removes its attachment references; unreferenced managed blobs are reclaimed by reconciliation. Deleting the App alone does not necessarily remove data under `~/.privateAI`; developers can remove that directory to delete managed artifacts and logs.

## Changes and contact

Material changes will be reflected by a new effective date. Use the repository's public support channel for privacy questions, and GitHub's private vulnerability-reporting channel for security issues.
