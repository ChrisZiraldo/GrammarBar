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
    private var cancellables = Set<AnyCancellable>()

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

    private func buildMenu() {
        let menu = NSMenu()

        // Enable / Disable toggle
        let toggleItem = NSMenuItem(
            title: settings.isEnabled ? "Disable GrammarBar" : "Enable GrammarBar",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.tag = 100
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
        modelLabel.tag = 200
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        // Server status
        let statusLabel = NSMenuItem(title: serverManager.statusMessage, action: nil, keyEquivalent: "")
        statusLabel.tag = 201
        statusLabel.isEnabled = false
        statusLabel.attributedTitle = statusAttributedString(serverManager.statusMessage)
        menu.addItem(statusLabel)

        menu.addItem(.separator())

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
    }

    private func updateToggleItem(enabled: Bool) {
        guard let item = statusItem.menu?.item(withTag: 100) else { return }
        item.title = enabled ? "Disable GrammarBar" : "Enable GrammarBar"
    }

    private func updateIcon(enabled: Bool) {
        let symbolName = enabled ? "pencil.circle" : "pencil.circle"
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "GrammarBar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.alphaValue = enabled ? 1.0 : 0.5
    }

    private func updateStatusLabel(_ message: String) {
        guard let item = statusItem.menu?.item(withTag: 201) else { return }
        item.attributedTitle = statusAttributedString(message)
    }

    private func updateModelLabel(modelId: String?) {
        guard let item = statusItem.menu?.item(withTag: 200) else { return }
        if let modelId, let entry = ModelCatalog.model(for: modelId) {
            item.title = "Model: \(entry.name)"
        } else {
            item.title = "No model — open Settings"
        }
    }

    private func statusAttributedString(_ message: String) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
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
