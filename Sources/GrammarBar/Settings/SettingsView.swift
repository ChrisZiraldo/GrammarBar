import SwiftUI
import AppKit
import ApplicationServices

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var serverManager: LlamaServerManager
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var selectedTab = 0

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ModelsTab(serverManager: serverManager)
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(0)

            GeneralTab(store: store)
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
    @State private var showingAppPicker = false

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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Proofread only (no rewording)", isOn: $store.proofreadOnly)
                    Text("When enabled, only spelling, grammar, and punctuation are fixed. The text is never reworded or restyled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Correction Style")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GrammarBar is active everywhere except these apps.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    let blocked = store.blockedBundleIds.sorted()
                    if blocked.isEmpty {
                        Text("No apps blocked.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(blocked, id: \.self) { bundleId in
                                BlockedAppRow(bundleId: bundleId) {
                                    store.blockedBundleIds.remove(bundleId)
                                }
                                if bundleId != blocked.last {
                                    Divider()
                                }
                            }
                        }
                    }

                    Button("Add App…") {
                        showingAppPicker = true
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("App block-list")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerSheet(blockedIds: $store.blockedBundleIds)
        }
    }
}

private struct BlockedAppRow: View {
    let bundleId: String
    let onRemove: () -> Void

    var body: some View {
        let app = InstalledAppsScanner.resolve(bundleId: bundleId)

        HStack(spacing: 8) {
            if let app {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(app?.name ?? bundleId)
                    .font(.system(size: 12))
                if app != nil {
                    Text(bundleId)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - App picker sheet

private struct AppPickerSheet: View {
    @Binding var blockedIds: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var query = ""

    private var filteredApps: [InstalledApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Block an App")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Scanning Applications folder…")
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                Text("No apps found.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(filteredApps) { app in
                    Button {
                        toggle(app)
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 22, height: 22)
                            Text(app.name)
                                .font(.system(size: 12))
                            Spacer()
                            if blockedIds.contains(app.bundleId) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 380, height: 440)
        .onAppear(perform: loadApps)
    }

    private func toggle(_ app: InstalledApp) {
        if blockedIds.contains(app.bundleId) {
            blockedIds.remove(app.bundleId)
        } else {
            blockedIds.insert(app.bundleId)
        }
    }

    private func loadApps() {
        guard apps.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = InstalledAppsScanner.scanAll()
            DispatchQueue.main.async {
                apps = scanned
                isLoading = false
            }
        }
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
