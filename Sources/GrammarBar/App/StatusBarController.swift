import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var serverManager: LlamaServerManager!
    private var correctionEngine: CorrectionEngine!
    private var settings: SettingsStore!
    private var pulseTimer: Timer?
    private var pulseFilled = false
    private var showingNoChangesFlash = false
    private var noChangesFlashWork: DispatchWorkItem?
    private var showingCorrectedFlash = false
    private var correctedFlashWork: DispatchWorkItem?
    private var pauseExpiryTimer: Timer?
    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var cancellables = Set<AnyCancellable>()

    /// The app that was frontmost when the menu opened (never GrammarBar itself),
    /// used by the "Disable in <app>" shortcut.
    private var menuTargetApp: (bundleId: String, name: String)?

    // Menu item tags
    private enum Tag: Int {
        case toggle = 100
        case pause = 101
        case appToggle = 102
        case undo = 103
        case model = 200
        case serverStatus = 201
        case weekStats = 202
    }

    /// Screen frame (AppKit coordinates, origin bottom-left) of the menu bar icon,
    /// used to anchor the correction bubble's tail beneath it.
    var statusItemScreenFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.frame)
    }

    func setup(serverManager: LlamaServerManager, correctionEngine: CorrectionEngine, settings: SettingsStore) {
        self.serverManager = serverManager
        self.correctionEngine = correctionEngine
        self.settings = settings

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "GrammarBar")
            button.image?.isTemplate = true
            button.toolTip = "GrammarBar"
        }

        buildMenu()
        observeChanges()
        refreshIcon()
        schedulePauseExpiry()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        // Undo the last accepted correction — only visible while undo is available.
        let undoItem = NSMenuItem(title: "Undo Last Correction  (⌃Z)", action: #selector(undoLastCorrection), keyEquivalent: "")
        undoItem.target = self
        undoItem.tag = Tag.undo.rawValue
        undoItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        undoItem.isHidden = true
        menu.addItem(undoItem)

        // Enable / Disable toggle
        let toggleItem = NSMenuItem(
            title: settings.isEnabled ? "Disable GrammarBar" : "Enable GrammarBar",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.tag = Tag.toggle.rawValue
        menu.addItem(toggleItem)

        // Pause for an hour (auto-resumes)
        let pauseItem = NSMenuItem(title: pauseTitle(), action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.tag = Tag.pause.rawValue
        menu.addItem(pauseItem)

        // Per-app shortcut — title and visibility are filled in when the menu opens.
        let appItem = NSMenuItem(title: "Disable in This App", action: #selector(toggleAppBlock), keyEquivalent: "")
        appItem.target = self
        appItem.tag = Tag.appToggle.rawValue
        appItem.isHidden = true
        menu.addItem(appItem)

        menu.addItem(.separator())

        // Active model display
        let modelTitle: String
        if let modelId = settings.selectedModelId,
           let entry = ModelCatalog.model(for: modelId) {
            modelTitle = "Model: \(entry.name)"
        } else {
            modelTitle = "No model selected"
        }
        let modelLabel = NSMenuItem(title: modelTitle, action: nil, keyEquivalent: "")
        modelLabel.tag = Tag.model.rawValue
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        // Server status
        let statusLabel = NSMenuItem(title: serverManager.statusMessage, action: nil, keyEquivalent: "")
        statusLabel.tag = Tag.serverStatus.rawValue
        statusLabel.isEnabled = false
        statusLabel.attributedTitle = statusAttributedString(serverManager.statusMessage)
        menu.addItem(statusLabel)

        menu.addItem(.separator())

        // Correction style submenu
        menu.addItem(buildToneSubmenu())

        menu.addItem(.separator())

        // Weekly stats
        let statsItem = NSMenuItem(title: weekStatsTitle(), action: nil, keyEquivalent: "")
        statsItem.tag = Tag.weekStats.rawValue
        statsItem.isEnabled = false
        statsItem.attributedTitle = statusAttributedString(weekStatsTitle())
        menu.addItem(statsItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Setup guide (permissions, model, try-it)
        let setupItem = NSMenuItem(title: "Setup Guide…", action: #selector(openSetupGuide), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit GrammarBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // The menu opens without activating GrammarBar, so the frontmost app is
            // still the one the user was working in.
            if let app = NSWorkspace.shared.frontmostApplication,
               let bundleId = app.bundleIdentifier,
               bundleId != Bundle.main.bundleIdentifier {
                menuTargetApp = (bundleId, app.localizedName ?? bundleId)
            } else {
                menuTargetApp = nil
            }
            updateAppToggleItem()
            updatePauseItem()
            statusItem.menu?.item(withTag: Tag.undo.rawValue)?.isHidden = !(appDelegate?.isUndoAvailable ?? false)
        }
    }

    private func updateAppToggleItem() {
        guard let item = statusItem.menu?.item(withTag: Tag.appToggle.rawValue) else { return }
        guard let target = menuTargetApp else {
            item.isHidden = true
            return
        }
        item.isHidden = false
        item.title = settings.blockedBundleIds.contains(target.bundleId)
            ? "Enable in \(target.name)"
            : "Disable in \(target.name)"
    }

    private func updatePauseItem() {
        statusItem.menu?.item(withTag: Tag.pause.rawValue)?.title = pauseTitle()
    }

    private func pauseTitle() -> String {
        guard settings.isPaused, let until = settings.pausedUntil else { return "Pause for 1 Hour" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Resume (paused until \(formatter.string(from: until)))"
    }

    private func buildToneSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Correction Style", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Correction Style")

        for mode in CorrectionMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(setToneMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (settings.correctionMode == mode) ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Observation

    private func observeChanges() {
        settings.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.updateToggleItem(enabled: enabled)
                self?.refreshIcon()
            }
            .store(in: &cancellables)

        serverManager.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.updateStatusLabel(message)
                self?.refreshIcon()
            }
            .store(in: &cancellables)

        serverManager.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        correctionEngine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .unchanged {
                    self.flashNoChanges()
                } else {
                    self.refreshIcon()
                }
            }
            .store(in: &cancellables)

        settings.$selectedModelId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] modelId in
                self?.updateModelLabel(modelId: modelId)
            }
            .store(in: &cancellables)

        settings.$correctionMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshToneSubmenu()
            }
            .store(in: &cancellables)

        settings.$weekAccepted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWeekStats()
            }
            .store(in: &cancellables)

        settings.$totalSuggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateWeekStats() }
            .store(in: &cancellables)

        settings.$totalAccepted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateWeekStats() }
            .store(in: &cancellables)

        settings.$pausedUntil
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePauseItem()
                self?.schedulePauseExpiry()
                self?.refreshIcon()
            }
            .store(in: &cancellables)
    }

    // MARK: - Pause

    /// Resumes automatically when the pause window ends.
    private func schedulePauseExpiry() {
        pauseExpiryTimer?.invalidate()
        pauseExpiryTimer = nil

        guard let until = settings.pausedUntil, until > Date() else { return }
        pauseExpiryTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow + 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.settings.isPaused { self.settings.pausedUntil = nil }
                self.refreshIcon()
            }
        }
    }

    // MARK: - Update helpers

    private func updateToggleItem(enabled: Bool) {
        guard let item = statusItem.menu?.item(withTag: Tag.toggle.rawValue) else { return }
        item.title = enabled ? "Disable GrammarBar" : "Enable GrammarBar"
    }

    // MARK: - Icon state

    private enum IconState {
        case normal
        case disabled
        case paused
        case serverDown
        case correcting
        case suggestionReady
        case corrected
        case noChanges
    }

    private func currentIconState() -> IconState {
        if !settings.isEnabled { return .disabled }
        if settings.isPaused { return .paused }

        // Server problems matter more than transient activity — except while it's
        // legitimately (re)starting, which isn't an error.
        if !serverManager.isRunning {
            let message = serverManager.statusMessage
            let isStarting = message.hasPrefix("Starting") || message.hasPrefix("Restarting")
            if !isStarting { return .serverDown }
        }

        switch correctionEngine.state {
        case .correcting: return .correcting
        case .finished:   return .suggestionReady
        default:          break
        }

        if showingCorrectedFlash { return .corrected }
        return showingNoChangesFlash ? .noChanges : .normal
    }

    /// Re-derives the menu-bar icon from the current enabled / server / correction state.
    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let state = currentIconState()

        let symbol: String
        let tooltip: String
        var alpha: CGFloat = 1.0

        switch state {
        case .normal:
            symbol = "pencil.circle"
            tooltip = "GrammarBar"
        case .disabled:
            symbol = "pencil.slash"
            tooltip = "GrammarBar is disabled"
            alpha = 0.6
        case .paused:
            symbol = "pause.circle"
            tooltip = "GrammarBar is paused"
        case .serverDown:
            symbol = "exclamationmark.triangle"
            tooltip = "GrammarBar: \(serverManager.statusMessage)"
        case .correcting:
            // Alternates between outline and filled via the pulse timer.
            symbol = pulseFilled ? "pencil.circle.fill" : "pencil.circle"
            tooltip = "GrammarBar is checking your text…"
        case .suggestionReady:
            symbol = "pencil.circle.fill"
            tooltip = "GrammarBar has a suggestion"
        case .noChanges:
            symbol = "checkmark.circle"
            tooltip = "Looks good"
        case .corrected:
            symbol = "checkmark.circle.fill"
            tooltip = "Corrected — click to undo"
        }

        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GrammarBar")
            ?? NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "GrammarBar")
        if state == .corrected {
            // Template images are tinted by the system; the confirmation needs real green.
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            image = image?.withSymbolConfiguration(config)
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.alphaValue = alpha
        button.toolTip = tooltip

        if state == .correcting {
            startPulse()
        } else {
            stopPulse()
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseFilled.toggle()
                self.refreshIcon()
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseFilled = false
    }

    /// Briefly shows a checkmark when a pass found nothing to fix.
    private func flashNoChanges() {
        showingNoChangesFlash = true
        refreshIcon()

        noChangesFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.showingNoChangesFlash = false
                self?.refreshIcon()
            }
        }
        noChangesFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Shows a green check on the icon after a correction is accepted. Clicking the
    /// icon then offers "Undo Last Correction".
    func showCorrectedFlash(duration: TimeInterval) {
        showingCorrectedFlash = true
        refreshIcon()

        correctedFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.clearCorrectedFlash() }
        }
        correctedFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func clearCorrectedFlash() {
        correctedFlashWork?.cancel()
        correctedFlashWork = nil
        guard showingCorrectedFlash else { return }
        showingCorrectedFlash = false
        refreshIcon()
    }

    private func updateStatusLabel(_ message: String) {
        guard let item = statusItem.menu?.item(withTag: Tag.serverStatus.rawValue) else { return }
        item.attributedTitle = statusAttributedString(message)
    }

    private func updateModelLabel(modelId: String?) {
        guard let item = statusItem.menu?.item(withTag: Tag.model.rawValue) else { return }
        if let modelId, let entry = ModelCatalog.model(for: modelId) {
            item.title = "Model: \(entry.name)"
        } else {
            item.title = "No model — open Settings"
        }
    }

    private func refreshToneSubmenu() {
        guard let menu = statusItem.menu else { return }
        // Find the Correction Style parent item and rebuild its submenu
        for item in menu.items {
            if item.title == "Correction Style" {
                item.submenu?.items.forEach { subItem in
                    guard let raw = subItem.representedObject as? String,
                          let mode = CorrectionMode(rawValue: raw) else { return }
                    subItem.state = (settings.correctionMode == mode) ? .on : .off
                }
                break
            }
        }
    }

    private func updateWeekStats() {
        guard let item = statusItem.menu?.item(withTag: Tag.weekStats.rawValue) else { return }
        item.attributedTitle = statusAttributedString(weekStatsTitle())
    }

    private func weekStatsTitle() -> String {
        var title = "This week: \(settings.weekAccepted) accepted"
        if settings.totalSuggestions > 0 {
            let rate = Double(settings.totalAccepted) / Double(settings.totalSuggestions)
            title += " · \(Int((min(rate, 1) * 100).rounded()))% acceptance"
        }
        return title
    }

    private func statusAttributedString(_ message: String) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    // MARK: - Actions

    @objc private func undoLastCorrection() {
        appDelegate?.undoLastCorrection()
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func togglePause() {
        if settings.isPaused {
            settings.pausedUntil = nil
        } else {
            settings.pausedUntil = Date().addingTimeInterval(60 * 60)
        }
    }

    @objc private func toggleAppBlock() {
        guard let target = menuTargetApp else { return }
        if settings.blockedBundleIds.contains(target.bundleId) {
            settings.blockedBundleIds.remove(target.bundleId)
        } else {
            settings.blockedBundleIds.insert(target.bundleId)
        }
    }

    @objc private func openSetupGuide() {
        appDelegate?.showOnboarding()
    }

    @objc private func setToneMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CorrectionMode(rawValue: raw) else { return }
        settings.correctionMode = mode
    }

    @objc private func openSettings() {
        if settingsWindow == nil || settingsWindow?.isVisible == false {
            let view = SettingsView(serverManager: serverManager)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "GrammarBar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
