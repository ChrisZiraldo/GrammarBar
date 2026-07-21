import SwiftUI
import AppKit
import ApplicationServices

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var serverManager: LlamaServerManager
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var allowListText = ""
    @State private var selectedTab = 0

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ModelsTab(serverManager: serverManager)
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(0)

            GeneralTab(store: store, allowListText: $allowListText)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(1)

            PermissionsTab(
                accessibilityGranted: $accessibilityGranted,
                inputMonitoringGranted: $inputMonitoringGranted
            )
            .tabItem { Label("Permissions", systemImage: "lock.shield") }
            .tag(2)
        }
        .frame(width: 520, height: 420)
        .onAppear {
            checkPermissions()
            allowListText = store.allowedBundleIds.sorted().joined(separator: "\n")
            modelManager.refreshInstalledStates()
        }
    }

    private func checkPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }
}

// MARK: - Models tab

private struct ModelsTab: View {
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject var serverManager: LlamaServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Server status header
            HStack(spacing: 6) {
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(serverManager.statusMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(ModelCatalog.all) { entry in
                ModelRow(
                    entry: entry,
                    state: modelManager.downloadStates[entry.id] ?? .notInstalled,
                    isSelected: store.selectedModelId == entry.id,
                    serverManager: serverManager
                )
            }
        }
    }
}

private struct ModelRow: View {
    let entry: ModelEntry
    let state: ModelDownloadState
    let isSelected: Bool
    let serverManager: LlamaServerManager

    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
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
                Text("\(entry.sizeDisplayString) · \(entry.minRAMGB) GB RAM min")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            switch state {
            case .notInstalled:
                Button("Download") {
                    modelManager.download(entry: entry)
                }
                .controlSize(.small)

            case .downloading(let progress):
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                        .progressViewStyle(.linear)
                    Button("Cancel") {
                        modelManager.cancelDownload(entry: entry)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

            case .installed:
                HStack(spacing: 8) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 16))
                    } else {
                        Button("Use") {
                            selectModel(entry)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    Button {
                        modelManager.delete(entry: entry)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }

            case .error(let msg):
                VStack(alignment: .trailing) {
                    Text("Failed")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Button("Retry") {
                        modelManager.download(entry: entry)
                    }
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func selectModel(_ entry: ModelEntry) {
        store.selectedModelId = entry.id
        guard let path = modelManager.installedPath(for: entry) else { return }
        Task { @MainActor in
            await serverManager.start(modelPath: path.path)
        }
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @Binding var allowListText: String

    var body: some View {
        Form {
            Section {
                Toggle("Enable GrammarBar", isOn: $store.isEnabled)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Correction delay")
                        Spacer()
                        Text("\(String(format: "%.1f", store.debounceInterval)) s")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $store.debounceInterval, in: 0.2...2.0, step: 0.1)
                    Text("How long after you stop typing before a correction is requested.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Timing")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One app bundle ID per line. Leave empty to enable in all apps.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $allowListText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 80)
                        .border(Color(NSColor.separatorColor), width: 0.5)
                    Button("Save allow-list") {
                        let ids = allowListText
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        store.allowedBundleIds = Set(ids)
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("App allow-list")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

// MARK: - Permissions tab

private struct PermissionsTab: View {
    @Binding var accessibilityGranted: Bool
    @Binding var inputMonitoringGranted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("GrammarBar requires two system permissions to work. Grant them below, then restart the app.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Allows reading and writing text in focused fields.",
                granted: accessibilityGranted
            ) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            PermissionRow(
                icon: "keyboard",
                title: "Input Monitoring",
                detail: "Allows detecting when you pause typing to trigger a correction.",
                granted: inputMonitoringGranted
            ) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }

            Button("Re-check permissions") {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
                accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
                inputMonitoringGranted = CGPreflightListenEventAccess()
            }
            .controlSize(.small)

            Spacer()
        }
        .padding(20)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .frame(width: 32)
                .foregroundColor(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Open Settings") { onGrant() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }
}
