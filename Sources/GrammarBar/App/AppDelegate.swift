import AppKit
import ApplicationServices
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Nonisolated init so main.swift can create this without main-actor isolation.
    /// All actual setup happens in applicationDidFinishLaunching which AppKit
    /// calls on the main thread.
    nonisolated override init() {
        super.init()
    }


    // MARK: - Components

    let settings = SettingsStore.shared
    let modelManager = ModelManager.shared
    lazy var serverManager = LlamaServerManager()
    lazy var correctionEngine = CorrectionEngine(serverManager: serverManager)
    lazy var focusTracker = FocusTracker()
    lazy var textWriter = TextWriter()
    lazy var eventTapController = EventTapController()
    lazy var statusBarController = StatusBarController()

    private var overlayPanel: OverlayPanel?
    private var currentFocusedElement: AXUIElement?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensurePermissions()

        // Wire up the event tap → schedule a correction when the user pauses
        eventTapController.onKeystroke = { [weak self] in
            self?.handleKeystroke()
        }
        // Return is handled separately from generic keystrokes: plain Return
        // clears the bubble (and lets the app send the original text as normal);
        // Ctrl+Return accepts the pending correction and is swallowed so the
        // frontmost app doesn't also see a Ctrl+Return.
        eventTapController.onReturnKey = { [weak self] ctrlHeld in
            MainActor.assumeIsolated {
                self?.handleReturnKey(ctrlHeld: ctrlHeld) ?? false
            }
        }
        eventTapController.start()

        // Observe correction state changes to show/hide the overlay
        correctionEngine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleCorrectionState(state)
            }
            .store(in: &cancellables)

        // Set up the status bar
        statusBarController.setup(
            serverManager: serverManager,
            correctionEngine: correctionEngine,
            settings: settings
        )

        // Start the server if a model is already downloaded and selected
        if let modelId = settings.selectedModelId,
           let entry = ModelCatalog.model(for: modelId),
           let path = modelManager.installedPath(for: entry) {
            Task { await serverManager.start(modelPath: path.path) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTapController.stop()
        serverManager.stop()
    }

    // MARK: - Permissions

    /// GrammarBar's keystroke capture relies on Accessibility (to read/write focused
    /// text fields) and Input Monitoring (to tap key events system-wide). Neither
    /// permission auto-prompts just by calling CGEventTap/AXUIElement APIs — we have
    /// to explicitly request them, and if still missing, send the user to System
    /// Settings ourselves, since silently failing looks identical to "nothing broke."
    private func ensurePermissions() {
        let axTrusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }

        // Both prompts (if shown) are async and the user may take a while to respond,
        // so re-check shortly after instead of blocking startup on them.
        guard !axTrusted || !CGPreflightListenEventAccess() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.warnIfPermissionsMissing()
        }
    }

    private func warnIfPermissionsMissing() {
        guard !AXIsProcessTrusted() || !CGPreflightListenEventAccess() else { return }

        let alert = NSAlert()
        alert.messageText = "GrammarBar needs two permissions"
        alert.informativeText = """
        To detect what you're typing and show suggestions, GrammarBar needs Accessibility \
        and Input Monitoring access. Open System Settings → Privacy & Security, enable \
        GrammarBar in both Accessibility and Input Monitoring, then relaunch GrammarBar.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Input Monitoring Settings")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openSettingsPane("com.apple.preference.security?Privacy_Accessibility")
        case .alertSecondButtonReturn:
            openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
        default:
            break
        }
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Keystroke handling

    private func handleKeystroke() {
        guard settings.isEnabled else { return }

        // Dismiss in-progress overlay and cancel any running stream — new typing context
        dismissOverlay()

        let element = focusTracker.focusedElement()
        guard let element else { return }
        guard !focusTracker.isSecureTextField(element) else { return }
        guard focusTracker.isEditableTextField(element) else { return }

        // Enforce per-app block-list
        if !settings.blockedBundleIds.isEmpty,
           let bundleId = focusTracker.frontmostAppBundleId(),
           settings.blockedBundleIds.contains(bundleId) {
            return
        }

        currentFocusedElement = element

        let text = focusTracker.value(of: element) ?? ""
        guard text.count >= 3 else { return }  // Skip trivially short strings

        correctionEngine.schedule(text: text)
    }

    // MARK: - Return key handling

    /// Returns whether the keystroke should be swallowed (kept from reaching the frontmost app).
    private func handleReturnKey(ctrlHeld: Bool) -> Bool {
        guard settings.isEnabled else { return false }

        if ctrlHeld {
            guard overlayPanel?.isVisible == true,
                  correctionEngine.state == .finished,
                  !correctionEngine.correctionText.isEmpty else {
                return false // nothing ready to accept — let Ctrl+Return behave normally
            }
            acceptCorrection()
            return true
        }

        // Plain Return: clear the bubble immediately. The Return keystroke itself
        // is left untouched so the app sends/inserts the user's original text as usual.
        dismissOverlay()
        return false
    }

    // MARK: - Correction state → overlay

    private func handleCorrectionState(_ state: CorrectionState) {
        switch state {
        case .idle:
            break

        case .correcting:
            // Show overlay as tokens start arriving
            showOrPositionOverlay()

        case .finished:
            showOrPositionOverlay()

        case .error:
            // Don't show overlay for errors — they appear in the overlay if it's already visible
            if overlayPanel?.isVisible == true {
                showOrPositionOverlay()
            }
        }
    }

    private func showOrPositionOverlay() {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel(
                correctionEngine: correctionEngine,
                onAccept: { [weak self] in self?.acceptCorrection() },
                onDismiss: { [weak self] in self?.dismissOverlay() }
            )
        }

        if let statusFrame = statusBarController.statusItemScreenFrame {
            overlayPanel?.position(belowStatusItem: statusFrame)
        }

        if overlayPanel?.isVisible == false {
            overlayPanel?.orderFront(nil)
        }
    }

    // MARK: - Accept / Dismiss

    private func acceptCorrection() {
        guard let element = currentFocusedElement else { return }
        let corrected = correctionEngine.correctionText
        guard !corrected.isEmpty else { return }

        // Re-resolve the live focused element and verify it is still the same
        // field we captured the correction for. Focus can silently drift if the
        // user clicked elsewhere without typing (no keyDown → no dismissOverlay),
        // and TextWriter always pastes into the *current* focus — so writing
        // without this check would select-all-replace whatever field happens to
        // be focused, potentially destroying its contents.
        //
        // The overlay is a nonactivatingPanel (canBecomeKey = false), so clicking
        // the Accept button never moves focus away from the target field, meaning
        // the normal accept path is unaffected by this guard.
        let liveElement = focusTracker.focusedElement()
        guard let liveElement,
              CFEqual(element, liveElement),
              !focusTracker.isSecureTextField(liveElement),
              focusTracker.isEditableTextField(liveElement) else {
            // Focus has moved — silently dismiss rather than paste into the wrong field.
            dismissOverlay()
            return
        }

        textWriter.write(corrected, to: element)
        overlayPanel?.orderOut(nil)
        correctionEngine.cancel()
    }

    private func dismissOverlay() {
        overlayPanel?.orderOut(nil)
        correctionEngine.cancel()
    }
}
