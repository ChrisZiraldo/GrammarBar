import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var serverManager: LlamaServerManager
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

            StyleTab(store: store)
                .tabItem { Label("Style", systemImage: "textformat") }
                .tag(2)

            AppsTab(store: store)
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(3)

            StatsTab(store: store)
                .tabItem { Label("Stats", systemImage: "chart.bar") }
                .tag(4)

            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(5)
        }
        .frame(width: 580, height: 520)
        .onAppear {
            modelManager.refreshInstalledStates()
        }
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

/// Installed RAM in whole gigabytes.
private let installedMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

private struct ModelRow: View {
    let entry: ModelEntry
    let state: ModelDownloadState
    let isSelected: Bool
    @ObservedObject var serverManager: LlamaServerManager

    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var store = SettingsStore.shared

    private var needsMoreRAM: Bool { entry.minRAMGB > installedMemoryGB }

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
                if needsMoreRAM {
                    Label(
                        "Needs \(entry.minRAMGB) GB of RAM — this Mac has \(installedMemoryGB) GB, so it may be slow or fail to load.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
                        selectedBadge
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

    /// "In use" once the server is up with this model; otherwise a neutral "Selected".
    private var selectedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: serverManager.isRunning ? "checkmark.circle.fill" : "clock.fill")
                .foregroundColor(serverManager.isRunning ? .green : .orange)
                .font(.system(size: 14))
            Text(serverManager.isRunning ? "In use" : "Selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(serverManager.isRunning ? .green : .orange)
        }
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

    var body: some View {
        Form {
            // ── Enable ──────────────────────────────────────────────
            Section {
                Toggle("Enable GrammarBar", isOn: $store.isEnabled)
            }

            // ── Timing ──────────────────────────────────────────────
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

            // ── Appearance ──────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Float bubble above the text field", isOn: $store.anchorBubbleToTextField)
                    Text("Instead of hanging below the menu-bar icon, the bubble appears just above the field you're typing in. In tall editors it follows the cursor line. Falls back to the menu bar when an app doesn't share its text position.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("“Corrected” toast", selection: $store.toastLocation) {
                        ForEach(ToastLocation.allCases) { location in
                            Text(location.title).tag(location)
                        }
                    }
                    Text("What you see for a few seconds after accepting a suggestion. The green check turns the menu-bar icon into a quick confirmation — click the icon and choose “Undo Last Correction”. Typing dismisses it, and Ctrl+Z undoes during that window in every mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Resize bubble to fit long text", isOn: $store.resizeBubbleToFitText)
                    Text("When enabled, the correction bubble grows taller to show long suggestions in full instead of scrolling within a fixed height.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Appearance")
            }

            // ── System ──────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { LoginItem.setEnabled($0) }
                    ))
                    Text("Start GrammarBar automatically when you log in.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("System")
            }

            // ── Shortcuts ───────────────────────────────────────────
            Section {
                shortcutRow("⌃Return", "Accept the suggestion")
                shortcutRow("Esc", "Dismiss the suggestion (it won't come back until you edit the text)")
                shortcutRow("⌃Z", "Undo a correction while the “Corrected” toast is showing")
            } header: {
                Text("Shortcuts")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func shortcutRow(_ keys: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 64, alignment: .leading)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Style tab

private struct StyleTab: View {
    @ObservedObject var store: SettingsStore
    @State private var newDictionaryWord = ""

    var body: some View {
        Form {
            // ── Correction Style ─────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Style", selection: $store.correctionMode) {
                        ForEach(CorrectionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(correctionModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Default Style")
            }

            // ── Custom Dictionary ────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Words and terms that are never altered. GrammarBar restores them if the model changes one, except that a lowercase word is still capitalized at the start of a sentence. You can also right-click a change in the bubble and choose “Never change…”.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if store.customDictionary.isEmpty {
                        Text("No custom words added.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.customDictionary, id: \.self) { word in
                                HStack {
                                    Text(word).font(.system(size: 12))
                                    Spacer()
                                    Button {
                                        store.customDictionary.removeAll { $0 == word }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                                if word != store.customDictionary.last {
                                    Divider()
                                }
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("Add word or term…", text: $newDictionaryWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addDictionaryWord() }
                        Button("Add") { addDictionaryWord() }
                            .controlSize(.small)
                            .disabled(newDictionaryWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Custom Dictionary")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var correctionModeDescription: String {
        switch store.correctionMode {
        case .standard:  return "Fixes grammar, spelling, and punctuation while preserving your voice."
        case .proofread: return "Only fixes clear errors — never rewords or restyles anything correct."
        case .formal:    return "Rewrites in a professional, business-appropriate tone."
        case .casual:    return "Keeps the text natural and conversational."
        case .concise:   return "Removes filler and redundancy to make the text shorter."
        case .confident: return "Turns passive voice and hedging into assertive, direct language."
        case .friendly:  return "Warms up the tone to feel approachable and personable."
        }
    }

    private func addDictionaryWord() {
        let word = newDictionaryWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !store.customDictionary.contains(word) else { return }
        store.customDictionary.append(word)
        newDictionaryWord = ""
    }
}

// MARK: - Apps tab (per-app on/off + style, in one list)

/// What GrammarBar does in one app.
private enum AppRule: Hashable {
    /// Follows the global settings (no entry stored).
    case useDefault
    /// GrammarBar stays out of this app entirely.
    case off
    /// Active, using this style instead of the global one.
    case mode(CorrectionMode)
}

/// Reads and writes an app's rule across the two stores it lives in.
private func appRuleBinding(store: SettingsStore, bundleId: String) -> Binding<AppRule> {
    Binding(
        get: {
            if store.blockedBundleIds.contains(bundleId) { return .off }
            if let mode = store.appToneOverrides[bundleId] { return .mode(mode) }
            return .useDefault
        },
        set: { rule in
            store.blockedBundleIds.remove(bundleId)
            store.appToneOverrides.removeValue(forKey: bundleId)
            switch rule {
            case .useDefault: break
            case .off:        store.blockedBundleIds.insert(bundleId)
            case .mode(let mode): store.appToneOverrides[bundleId] = mode
            }
        }
    )
}

private struct AppRulePicker: View {
    @Binding var rule: AppRule

    var body: some View {
        Picker("", selection: $rule) {
            Text("Default").tag(AppRule.useDefault)
            Text("Off").tag(AppRule.off)
            Divider()
            ForEach(CorrectionMode.allCases) { mode in
                Text(mode.displayName).tag(AppRule.mode(mode))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
    }
}

private struct AppsTab: View {
    @ObservedObject var store: SettingsStore
    @State private var showingPicker = false

    /// Apps that have a non-default rule.
    private var configuredIds: [String] {
        Set(store.blockedBundleIds)
            .union(store.appToneOverrides.keys)
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how GrammarBar behaves in specific apps. Everything else follows your global settings.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if configuredIds.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary)
                    Text("No per-app rules yet")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(configuredIds, id: \.self) { bundleId in
                        AppRuleRow(
                            bundleId: bundleId,
                            rule: appRuleBinding(store: store, bundleId: bundleId)
                        )
                    }
                }
            }

            HStack {
                Button("Add App…") { showingPicker = true }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(20)
        .sheet(isPresented: $showingPicker) {
            AppRuleSheet(store: store)
        }
    }

    private func displayName(for bundleId: String) -> String {
        InstalledAppsScanner.resolve(bundleId: bundleId)?.name ?? bundleId
    }
}

private struct AppRuleRow: View {
    let bundleId: String
    @Binding var rule: AppRule

    var body: some View {
        let app = InstalledAppsScanner.resolve(bundleId: bundleId)

        HStack(spacing: 8) {
            if let app {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
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

            AppRulePicker(rule: $rule)

            Button {
                rule = .useDefault
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this rule")
        }
        .padding(.vertical, 3)
    }
}

private struct AppRuleSheet: View {
    @ObservedObject var store: SettingsStore
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
                Text("App Rules")
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
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text(app.name)
                            .font(.system(size: 12))
                        Spacer()
                        AppRulePicker(rule: appRuleBinding(store: store, bundleId: app.bundleId))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 440, height: 480)
        .onAppear(perform: loadApps)
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

// MARK: - Stats tab

private struct StatsTab: View {
    @ObservedObject var store: SettingsStore

    private var acceptanceRate: String {
        guard store.totalSuggestions > 0 else { return "—" }
        let rate = Double(store.totalAccepted) / Double(store.totalSuggestions)
        return "\(Int((min(rate, 1) * 100).rounded()))%"
    }

    var body: some View {
        Form {
            Section {
                statRow("Accepted this week", "\(store.weekAccepted)")
                statRow("Accepted in total", "\(store.totalAccepted)")
                statRow("Suggestions shown", "\(store.totalSuggestions)")
                statRow("Acceptance rate", acceptanceRate)
            } header: {
                Text("Corrections")
            } footer: {
                Text("Text that needed no changes doesn't count as a suggestion. Everything is stored on this Mac only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

// MARK: - Permissions tab

private struct PermissionsTab: View {
    @StateObject private var monitor = PermissionMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("GrammarBar needs two system permissions to work. This page updates on its own as soon as you grant them — no restart needed.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Allows reading and writing text in focused fields.",
                granted: monitor.accessibilityGranted
            ) {
                monitor.openAccessibilitySettings()
            }

            PermissionRow(
                icon: "keyboard",
                title: "Input Monitoring",
                detail: "Allows detecting when you pause typing to trigger a correction.",
                granted: monitor.inputMonitoringGranted
            ) {
                monitor.openInputMonitoringSettings()
            }

            Spacer()
        }
        .padding(20)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

struct PermissionRow: View {
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
