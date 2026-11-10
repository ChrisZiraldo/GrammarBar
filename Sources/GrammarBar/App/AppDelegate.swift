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
    private var onboardingController: OnboardingWindowController?
    private var currentFocusedElement: AXUIElement?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    // MARK: - Undo state

    /// The text in the focused field just before the last accepted correction.
    private var undoText: String?
    /// The element that was focused when the last correction was accepted.
    private var undoElement: AXUIElement?
    /// Ctrl+Z stays available until this moment (or until the next keystroke), even
    /// when the "Corrected" toast is turned off.
    private var undoDeadline: Date?
    private static let undoWindow: TimeInterval = 5

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
        // Escape dismisses the bubble; Ctrl+Z undoes a just-accepted correction.
        eventTapController.onEscapeKey = { [weak self] in
            MainActor.assumeIsolated {
                self?.handleEscapeKey() ?? false
            }
        }
        eventTapController.onUndoKey = { [weak self] in
            MainActor.assumeIsolated {
                self?.handleUndoKey() ?? false
            }
        }
        eventTapController.start()
        startPermissionWatcher()

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

        // Sync launch-at-login after the app is fully set up (SMAppService
        // IPC can transiently affect TCC state if called during startup).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            LoginItem.syncOnLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        eventTapController.stop()
        serverManager.stop()
    }

    // MARK: - Permissions

    /// GrammarBar's keystroke capture relies on Accessibility (to read/write focused
    /// text fields) and Input Monitoring (to tap key events system-wide). Neither
    /// permission auto-prompts just by calling CGEventTap/AXUIElement APIs — we have
    /// to explicitly request them, and if still missing, guide the user through the
    /// setup window, since silently failing looks identical to "nothing broke."
    private func ensurePermissions() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }

        // The system prompts are async and the user may take a while to respond,
        // so decide about the setup window shortly after instead of blocking startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    /// Polls until both permissions are granted, starting the keystroke tap as soon as
    /// Input Monitoring becomes available so the user never has to relaunch the app.
    private func startPermissionWatcher() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermissionsAndRestartTap()
            }
        }
    }

    private func checkPermissionsAndRestartTap() {
        if !eventTapController.isRunning && CGPreflightListenEventAccess() {
            eventTapController.start()
        }
        if eventTapController.isRunning && AXIsProcessTrusted() {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    // MARK: - Onboarding

    private func showOnboardingIfNeeded() {
        let permissionsOK = AXIsProcessTrusted() && CGPreflightListenEventAccess()
        let hasModel = settings.selectedModelId != nil

        // Already set up (e.g. an existing install) — nothing to show.
        if permissionsOK && hasModel {
            settings.hasCompletedOnboarding = true
            return
        }
        // Show for first-timers, or whenever permissions have gone missing.
        if !settings.hasCompletedOnboarding || !permissionsOK {
            showOnboarding()
        }
    }

    func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(serverManager: serverManager)
        }
        onboardingController?.show()
    }

    // MARK: - Keystroke handling

    private func handleKeystroke() {
        guard settings.isActive else { return }

        // Dismiss in-progress overlay and cancel any running stream — new typing context
        dismissOverlay()
        // Typing on means Ctrl+Z belongs to the app again.
        undoDeadline = nil
        statusBarController.clearCorrectedFlash()

        let element = focusTracker.focusedElement()
        guard let element else { return }
        guard !focusTracker.isSecureTextField(element) else { return }
        guard focusTracker.isEditableTextField(element) else { return }

        // Enforce per-app block-list
        let bundleId = focusTracker.frontmostAppBundleId()
        if !settings.blockedBundleIds.isEmpty,
           let bundleId,
           settings.blockedBundleIds.contains(bundleId) {
            return
        }

        currentFocusedElement = element

        // The event tap runs before the frontmost app handles this key event.
        // Read the AX value after the debounce instead of capturing a value that
        // can still be one character behind.
        correctionEngine.schedule(bundleId: bundleId) { [weak self] in
            self?.focusTracker.value(of: element)
        }
    }

    // MARK: - Return / Escape / Undo key handling

    /// Returns whether the keystroke should be swallowed (kept from reaching the frontmost app).
    private func handleReturnKey(ctrlHeld: Bool) -> Bool {
        guard settings.isActive else { return false }

        if ctrlHeld {
            guard overlayPanel?.isShowing == true,
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

    /// Escape closes the bubble (or the "Corrected" toast) and swallows the key; with
    /// nothing showing it passes straight through.
    private func handleEscapeKey() -> Bool {
        guard let panel = overlayPanel, panel.isShowing else { return false }
        if panel.isToastShowing {
            panel.hide()
        } else {
            dismissAndIgnoreOverlay()
        }
        return true
    }

    /// Ctrl+Z undoes the last accepted correction, but only while the "Corrected"
    /// toast is up — otherwise it belongs to whatever app has focus (e.g. a terminal).
    private func handleUndoKey() -> Bool {
        guard isUndoAvailable else { return false }
        undoLastCorrection()
        return true
    }

    /// True while the last accepted correction can still be undone: its toast or
    /// menu-bar check is showing, or the short undo window hasn't run out.
    var isUndoAvailable: Bool {
        let inWindow = undoDeadline.map { Date() < $0 } ?? false
        return (overlayPanel?.isToastShowing == true || inWindow)
            && undoElement != nil && undoText != nil
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

        case .unchanged:
            // Nothing to fix — take down the streaming bubble instead of showing an
            // identical "suggestion".
            overlayPanel?.hide()

        case .error:
            // Don't show overlay for errors — they appear in the overlay if it's already visible
            if overlayPanel?.isVisible == true {
                showOrPositionOverlay()
            }
        }
    }

    /// Where the bubble should sit: above the focused text field when that option is
    /// on and the field's position can be read, otherwise under the menu-bar icon.
    private func placementTarget(nearTextField: Bool) -> OverlayPanel.PlacementTarget? {
        if nearTextField,
           let element = currentFocusedElement,
           let rect = focusTracker.bubbleAnchorRect(for: element) {
            return .textField(rect)
        }
        if let statusFrame = statusBarController.statusItemScreenFrame {
            return .statusItem(statusFrame)
        }
        return nil
    }

    private func showOrPositionOverlay() {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel(
                correctionEngine: correctionEngine,
                onAccept: { [weak self] in self?.acceptCorrection() },
                onCopy: { [weak self] in self?.copyCorrection() },
                onDismiss: { [weak self] in self?.dismissAndIgnoreOverlay() },
                onUndo: { [weak self] in self?.undoLastCorrection() }
            )
        }

        if let target = placementTarget(nearTextField: settings.anchorBubbleToTextField) {
            overlayPanel?.place(target)
        }

        overlayPanel?.present()
    }

    // MARK: - Accept / Copy / Dismiss / Undo

    private func acceptCorrection() {
        guard let element = currentFocusedElement else { return }

        // The selected rephrase alternative if one is showing, otherwise the
        // correction with any edits the user reverted put back.
        let textToWrite = correctionEngine.textToApply
        guard !textToWrite.isEmpty else { return }

        // Stash the pre-correction text for undo
        undoText = focusTracker.value(of: element)
        undoElement = element

        textWriter.write(textToWrite, to: element)
        SettingsStore.shared.recordAccepted()
        correctionEngine.cancel()

        undoDeadline = Date().addingTimeInterval(Self.undoWindow)

        // Collapse the bubble into a "Corrected · Undo" toast instead of vanishing —
        // placed (or skipped) according to its own setting, separate from the bubble's.
        switch settings.toastLocation {
        case .menuBarIcon:
            overlayPanel?.hide()
            statusBarController.showCorrectedFlash(duration: Self.undoWindow)
        case .off:
            overlayPanel?.hide()
        case .menuBar, .textField:
            if let target = placementTarget(nearTextField: settings.toastLocation == .textField) {
                overlayPanel?.place(target)
            }
            overlayPanel?.showUndoToast()
        }
    }

    private func copyCorrection() {
        let text = correctionEngine.textToApply
        guard !text.isEmpty else { return }
        textWriter.copyToClipboard(text)
        dismissOverlay()
    }

    func undoLastCorrection() {
        guard let element = undoElement, let text = undoText else { return }
        textWriter.write(text, to: element)
        undoText = nil
        undoElement = nil
        undoDeadline = nil
        statusBarController.clearCorrectedFlash()
        overlayPanel?.hide()
    }

    /// Dismisses because the user kept typing or moved on.
    private func dismissOverlay() {
        overlayPanel?.hide()
        correctionEngine.cancel()
    }

    /// Dismisses because the user said "not this one" (close button / Escape), and
    /// holds off re-suggesting until the text changes.
    private func dismissAndIgnoreOverlay() {
        overlayPanel?.hide()
        correctionEngine.dismissAndIgnore()
    }
}
