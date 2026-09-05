import SwiftUI
import LLMCore

struct ChatDetailView: View {
    @Bindable var coordinator: ChatCoordinator
    @State private var showsModelDetails = false

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.ollama.state.requiresUserAction {
                OllamaPreflightBanner(ollama: coordinator.ollama)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }
            header
            if coordinator.isGenerating, let terminal = coordinator.terminalActivity {
                Divider()
                TerminalActivityView(
                    activity: terminal,
                    onStop: coordinator.stop
                )
            }
            Divider()
            if coordinator.selectedConversation == nil {
                ContentUnavailableView(
                    "Start a conversation",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptWebView(
                    messages: coordinator.messages,
                    revision: coordinator.transcriptRevision,
                    onCopy: coordinator.copyMessage
                )
            }
            Divider()
            ComposerView(coordinator: coordinator)
        }
        .navigationTitle(coordinator.selectedConversation?.title ?? "PrivateAI")
        .animation(.easeInOut(duration: 0.2), value: coordinator.ollama.state)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: InterfaceMetrics.spacingM) {
            Circle()
                .fill(coordinator.ollama.state.isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(coordinator.ollama.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if coordinator.ollama.state.isReady {
                Picker("Model", selection: modelSelection) {
                    ForEach(coordinator.ollama.models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240, minHeight: InterfaceMetrics.controlHeight)
                ModelPerformanceLabel(metrics: coordinator.generationMetrics)
                Button {
                    showsModelDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .frame(width: InterfaceMetrics.controlHeight, height: InterfaceMetrics.controlHeight)
                .contentShape(Rectangle())
                .accessibilityIdentifier("model.transparency.button")
                .help("Model details and system prompt")
                .popover(isPresented: $showsModelDetails, arrowEdge: .bottom) {
                    ModelTransparencyView(coordinator: coordinator)
                }
                workspaceMenu
            }
            Spacer()
            if !coordinator.activity.isEmpty {
                Text(coordinator.activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, InterfaceMetrics.pageHorizontalPadding)
        .frame(height: InterfaceMetrics.headerHeight)
    }

    private var workspaceMenu: some View {
        Menu {
            Button("Choose Folder…", systemImage: "folder.badge.plus") {
                coordinator.chooseExecutionWorkspace()
            }
            if coordinator.usesCustomExecutionWorkspace {
                Button("Use PrivateAI Workspace", systemImage: "arrow.uturn.backward") {
                    coordinator.clearExecutionWorkspace()
                }
            }
        } label: {
            Label(
                coordinator.executionWorkspaceLabel,
                systemImage: coordinator.usesCustomExecutionWorkspace
                    ? "folder.fill"
                    : "terminal.fill"
            )
            .lineLimit(1)
        }
        .frame(maxWidth: 180)
        .disabled(coordinator.isGenerating || !coordinator.terminalAvailable)
        .accessibilityIdentifier("execution.workspace.menu")
        .help(coordinator.terminalAvailable
            ? coordinator.executionWorkspace?.path ?? "Managed terminal unavailable"
            : "Terminal worker unavailable")
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { coordinator.ollama.selectedModel },
            set: { coordinator.selectModel($0) }
        )
    }
}

private struct TerminalActivityView: View {
    let activity: TerminalActivityState
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: InterfaceMetrics.spacingM) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(activity.isActive ? Color.accentColor : .secondary)
                    .frame(width: InterfaceMetrics.controlHeight)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: InterfaceMetrics.spacingS) {
                        Text(activity.status)
                            .font(.caption.weight(.semibold))
                        Text(activity.elapsedSeconds(at: context.date), format: .number.precision(
                            .fractionLength(0)
                        ))
                        .font(.caption.monospacedDigit())
                        Text("s")
                            .font(.caption)
                    }
                    Text(activity.command)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Text(activity.latestOutput ?? activity.workingDirectory)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if activity.isActive {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .frame(
                                width: InterfaceMetrics.controlHeight,
                                height: InterfaceMetrics.controlHeight
                            )
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .help("Stop terminal job")
                    .accessibilityIdentifier("terminal.activity.stop")
                }
            }
            .padding(.horizontal, InterfaceMetrics.pageHorizontalPadding)
            .padding(.vertical, InterfaceMetrics.spacingS)
            .frame(minHeight: 68)
            .background(.background.secondary)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.activity")
        }
    }
}

private extension OllamaConnectionState {
    var requiresUserAction: Bool {
        switch self {
        case .notInstalled, .notRunning, .failed:
            true
        case .checking, .ready, .starting:
            false
        }
    }
}

private struct OllamaPreflightBanner: View {
    let ollama: OllamaServiceController

    var body: some View {
        HStack(spacing: InterfaceMetrics.spacingM) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: InterfaceMetrics.controlHeight)

            VStack(alignment: .leading, spacing: InterfaceMetrics.spacingXS) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: InterfaceMetrics.spacingL)

            if case .notInstalled = ollama.state {
                Button {
                    ollama.openInstallationGuide()
                } label: {
                    Label("Installation Guide", systemImage: "arrow.up.right.square")
                }
            } else if case .notRunning = ollama.state {
                Button {
                    Task { await ollama.openOllama() }
                } label: {
                    Label("Open Ollama", systemImage: "play.fill")
                }
            }

            Button {
                Task { await ollama.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, InterfaceMetrics.pageHorizontalPadding)
        .padding(.vertical, InterfaceMetrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("ollama.preflight.banner")
    }

    private var iconName: String {
        if case .notInstalled = ollama.state { "square.and.arrow.down" } else { "bolt.slash" }
    }

    private var title: String {
        if case .notInstalled = ollama.state { "Install Ollama to get started" } else { "Ollama is offline" }
    }

    private var message: String {
        switch ollama.state {
        case .notInstalled:
            "Follow Ollama's official macOS installation guide, then come back and refresh."
        case .notRunning:
            "Open Ollama to connect to your local models. PrivateAI will refresh automatically."
        case .failed(let message):
            message
        case .checking, .ready, .starting:
            ""
        }
    }
}

private struct ModelTransparencyView: View {
    let coordinator: ChatCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceMetrics.spacingM) {
            Text("Model transparency")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: InterfaceMetrics.spacingL) {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(coordinator.ollama.selectedModel).textSelection(.enabled)
                }
                GridRow {
                    Text("Keep alive").foregroundStyle(.secondary)
                    Text("Until App exit (`-1`)")
                }
                GridRow {
                    Text("Warmup").foregroundStyle(.secondary)
                    Text(coordinator.warmupState).textSelection(.enabled)
                }
                GridRow {
                    Text("Warmup work").foregroundStyle(.secondary)
                    Text("Load model, evaluate system prompt, cache Tool schemas")
                }
                if let elapsed = coordinator.warmupElapsedSeconds {
                    GridRow {
                        Text("Warmup time").foregroundStyle(.secondary)
                        Text("\(elapsed, format: .number.precision(.fractionLength(2))) s")
                    }
                }
                if let tokens = coordinator.warmupPrefixTokens {
                    GridRow {
                        Text("Prefix tokens").foregroundStyle(.secondary)
                        Text(tokens, format: .number)
                    }
                }
                GridRow {
                    Text("System prompt").foregroundStyle(.secondary)
                    Text("Version \(LLMCoreSystemPrompt.version)")
                }
            }
            .font(.caption)

            Divider()

            ScrollView {
                Text(LLMCoreSystemPrompt.current)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InterfaceMetrics.spacingM)
            }
            .frame(width: 560, height: 320)
            .background(.background.secondary, in: RoundedRectangle(
                cornerRadius: InterfaceMetrics.fieldCornerRadius
            ))
        }
        .padding(InterfaceMetrics.spacingL)
        .frame(width: 600)
        .accessibilityIdentifier("model.transparency.panel")
    }
}

private struct ModelPerformanceLabel: View {
    let metrics: GenerationMetrics

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Label {
                Text(metrics.statusText(at: context.date))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 190, height: InterfaceMetrics.controlHeight, alignment: .center)
            .padding(.horizontal, InterfaceMetrics.controlHorizontalPadding)
            .background(.quaternary, in: RoundedRectangle(
                cornerRadius: InterfaceMetrics.compactCornerRadius
            ))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("model.performance.label")
            .accessibilityLabel(
                "Model performance, \(metrics.statusText(at: context.date))"
            )
        }
    }
}