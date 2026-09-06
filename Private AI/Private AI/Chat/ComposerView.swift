import PrivateAITools
import SwiftUI

struct ComposerView: View {
    @Bindable var coordinator: ChatCoordinator
    @FocusState private var isComposerFocused: Bool
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: InterfaceMetrics.spacingXS) {
            inputContainer
            if let attachmentError = coordinator.attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            hint
        }
        .frame(maxWidth: InterfaceMetrics.chatContentMaximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, InterfaceMetrics.pageHorizontalPadding)
        .padding(.vertical, InterfaceMetrics.spacingM)
        .onAppear {
            isComposerFocused = true
        }
        .onChange(of: coordinator.composerFocusRequest) {
            isComposerFocused = true
        }
    }

    private var inputContainer: some View {
        VStack(alignment: .leading, spacing: InterfaceMetrics.spacingS) {
            if !coordinator.pendingAttachments.isEmpty || coordinator.isImportingAttachments {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: InterfaceMetrics.spacingS) {
                Button(action: coordinator.chooseAttachments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(coordinator.isGenerating || coordinator.isImportingAttachments)
                .accessibilityIdentifier("chat.attachment.button")
                .help("Attach documents")

                TextField("Message PrivateAI", text: $coordinator.draft, axis: .vertical)
                    .focused($isComposerFocused)
                    .accessibilityIdentifier("chat.composer")
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...12)
                    .padding(.vertical, InterfaceMetrics.spacingXS)
                    .onSubmit {
                        if coordinator.canSend { coordinator.send() }
                    }

                actionButton
            }
        }
        .padding(.horizontal, InterfaceMetrics.spacingM)
        .padding(.vertical, InterfaceMetrics.spacingS)
        .background(
            RoundedRectangle(cornerRadius: InterfaceMetrics.composerCornerRadius, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InterfaceMetrics.composerCornerRadius, style: .continuous)
                .stroke(
                    isDropTargeted || isComposerFocused
                        ? Color.accentColor.opacity(0.65)
                        : Color.primary.opacity(0.08),
                    lineWidth: isDropTargeted || isComposerFocused ? 1.5 : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isComposerFocused)
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = !urls.isEmpty
                && urls.count <= ManagedArtifactStore.maximumFilesPerImport
                && urls.allSatisfy { $0.isFileURL && LocalDocumentFormat.supports(url: $0) }
            guard accepted else { return false }
            return coordinator.importAttachments(from: urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: InterfaceMetrics.spacingXS) {
                ForEach(coordinator.pendingAttachments) { attachment in
                    HStack(spacing: InterfaceMetrics.spacingXS) {
                        Image(systemName: attachment.format == .pdf ? "doc.richtext" : "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .font(.caption)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(
                                fromByteCount: attachment.byteCount,
                                countStyle: .file
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Button {
                            coordinator.removePendingAttachment(id: attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .padding(.horizontal, InterfaceMetrics.spacingS)
                    .frame(height: 38)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                }
                if coordinator.isImportingAttachments {
                    HStack(spacing: InterfaceMetrics.spacingXS) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Importing documents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 38)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("chat.attachment.strip")
    }

    @ViewBuilder
    private var actionButton: some View {
        if coordinator.isGenerating {
            Button(action: coordinator.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("chat.stop.button")
            .help("Stop generation")
        } else {
            Button(action: coordinator.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("chat.send.button")
            .disabled(!coordinator.canSend)
            .help("Send message")
        }
    }

    private var hint: some View {
        Text("Press Return to send · Shift-Return for a new line")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}