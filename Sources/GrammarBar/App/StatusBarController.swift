import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var serverManager: LlamaServerManager!
    private var correctionEngine: CorrectionEngine!
    private var settings: SettingsStore!
    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var cancellables = Set<AnyCancellable>()
    private var undoTimer: Timer?

    // Menu item tags
    private enum Tag: Int {
        case toggle = 100
        case model = 200
        case serverStatus = 201
        case weekStats = 202
        case undoItem = 300
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
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        // Enable / Disable toggle
        let toggleItem = NSMenuItem(
            title: settings.isEnabled ? "Disable GrammarBar" : "Enable GrammarBar",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.tag = Tag.toggle.rawValue
        menu.addItem(toggleItem)

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

        // Undo last correction (hidden until available)
        let undoItem = NSMenuItem(title: "Undo Last Correction", action: #selector(undoLastCorrection), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = self
        undoItem.tag = Tag.undoItem.rawValue
        undoItem.isHidden = true
        menu.addItem(undoItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit GrammarBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
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
                self?.updateIcon(enabled: enabled)
            }
            .store(in: &cancellables)

        serverManager.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.updateStatusLabel(message)
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
    }

    // MARK: - Update helpers

    private func updateToggleItem(enabled: Bool) {
        guard let item = statusItem.menu?.item(withTag: Tag.toggle.rawValue) else { return }
        item.title = enabled ? "Disable GrammarBar" : "Enable GrammarBar"
    }

    private func updateIcon(enabled: Bool) {
        statusItem.button?.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "GrammarBar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.alphaValue = enabled ? 1.0 : 0.5
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
        let n = settings.weekAccepted
        return "Corrections this week: \(n)"
    }

    private func statusAttributedString(_ message: String) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    // MARK: - Undo affordance

    /// Show the Undo menu item for 10 seconds, then hide it automatically.
    func flashUndoAvailable() {
        guard let item = statusItem.menu?.item(withTag: Tag.undoItem.rawValue) else { return }
        item.isHidden = false
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.clearUndoAvailable() }
        }
    }

    func clearUndoAvailable() {
        undoTimer?.invalidate()
        undoTimer = nil
        statusItem.menu?.item(withTag: Tag.undoItem.rawValue)?.isHidden = true
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func setToneMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CorrectionMode(rawValue: raw) else { return }
        settings.correctionMode = mode
    }

    @objc private func undoLastCorrection() {
        appDelegate?.undoLastCorrection()
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
