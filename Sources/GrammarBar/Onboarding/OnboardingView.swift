import SwiftUI
import AppKit

// MARK: - Window controller

/// Owns the first-run / setup-guide window.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let serverManager: LlamaServerManager

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
    }

    func show() {
        if window == nil {
            let view = OnboardingView(serverManager: serverManager) { [weak self] in
                self?.window?.close()
            }
            let hosting = NSHostingController(rootView: view)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Welcome to GrammarBar"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }

        // Shown once automatically; it's always available again from the menu.
        SettingsStore.shared.hasCompletedOnboarding = true

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var serverManager: LlamaServerManager
    let onFinish: () -> Void

    @StateObject private var permissions = PermissionMonitor()
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var store = SettingsStore.shared

    @State private var step = 0
    @State private var sampleText = "i think this sentence have a few mistake in it"

    private let stepCount = 3

    private var recommendedModel: ModelEntry? {
        ModelCatalog.all.first(where: { $0.isRecommended }) ?? ModelCatalog.all.first
    }

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 20)

            Group {
                switch step {
                case 0:  permissionsStep
                case 1:  modelStep
                default: tryItStep
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 500, height: 440)
        .onAppear { permissions.start() }
        .onDisappear { permissions.stop() }
        .onChange(of: modelManager.downloadStates[recommendedModel?.id ?? ""]) { newState in
            // First download finishing with nothing chosen yet: just start using it.
            if newState == .installed, store.selectedModelId == nil, let entry = recommendedModel {
                useModel(entry)
            }
        }
    }

    // MARK: Progress

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == step ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    // MARK: Step 1 — permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                title: "Allow GrammarBar to see what you type",
                subtitle: "Two macOS permissions let it notice when you pause and fix the text in the field you're using. Nothing leaves your Mac."
            )

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Read and replace text in the focused field.",
                granted: permissions.accessibilityGranted
            ) {
                permissions.openAccessibilitySettings()
            }

            PermissionRow(
                icon: "keyboard",
                title: "Input Monitoring",
                detail: "Notice when you stop typing.",
                granted: permissions.inputMonitoringGranted
            ) {
                permissions.openInputMonitoringSettings()
            }

            if permissions.allGranted {
                Label("All set — GrammarBar can see your typing.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
            } else {
                Text("This updates by itself as soon as you flip the switches in System Settings.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Step 2 — model

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                title: "Pick a model",
                subtitle: "GrammarBar proofreads with a small language model that runs entirely on your Mac. You only download it once."
            )

            if let entry = recommendedModel {
                modelCard(entry)
            } else {
                Text("No models are listed in this build.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("You can add or switch models any time in Settings → Models.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func modelCard(_ entry: ModelEntry) -> some View {
        let state = modelManager.downloadStates[entry.id] ?? .notInstalled
        let isSelected = store.selectedModelId == entry.id

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                    if entry.isRecommended {
                        Text("Recommended")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("\(entry.sizeDisplayString) download")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            switch state {
            case .notInstalled:
                Button("Download") { modelManager.download(entry: entry) }
                    .buttonStyle(.borderedProminent)

            case .downloading(let progress):
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

            case .installed:
                if isSelected {
                    Label(serverManager.isRunning ? "Ready" : "Starting…", systemImage: serverManager.isRunning ? "checkmark.circle.fill" : "clock.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(serverManager.isRunning ? .green : .orange)
                } else {
                    Button("Use this model") { useModel(entry) }
                        .buttonStyle(.borderedProminent)
                }

            case .error(let message):
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                    Button("Retry") { modelManager.download(entry: entry) }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: Step 3 — try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(
                title: "Try it",
                subtitle: "Click at the end of the text below, type a few more words, then pause. A bubble with a suggested fix appears under the menu-bar icon."
            )

            TextEditor(text: $sampleText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            if !serverManager.isRunning {
                Label(
                    "The model isn't running yet (\(serverManager.statusMessage)). Suggestions will start once it is.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                tipRow("⌃Return", "accept the suggestion")
                tipRow("Esc", "dismiss it")
                tipRow("Click a change", "keep your original word instead")
                tipRow("Right-click a change", "“Never change this word”")
            }
        }
    }

    private func tipRow(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Shared pieces

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }

            Spacer()

            if step < stepCount - 1 {
                Button(step == 0 && !permissions.allGranted ? "Skip for now" : "Continue") {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func useModel(_ entry: ModelEntry) {
        store.selectedModelId = entry.id
        guard let path = modelManager.installedPath(for: entry) else { return }
        Task { @MainActor in
            await serverManager.start(modelPath: path.path)
        }
    }
}
