import Foundation
import Combine

// MARK: - State enums

enum CorrectionState: Equatable {
    case idle
    case correcting
    case finished
    case error(String)
}

enum RephraseState: Equatable {
    case idle
    case loading
    case finished([String])
    case error(String)
}

enum ExplanationState: Equatable {
    case idle
    case loading
    case finished(String)
    case error(String)
}

// MARK: - CorrectionEngine

@MainActor
final class CorrectionEngine: ObservableObject {

    // MARK: Correction

    @Published private(set) var state: CorrectionState = .idle
    @Published private(set) var originalText: String = ""
    @Published private(set) var correctionText: String = ""

    /// The correction style used for the current suggestion. Resolved from the
    /// per-app override or global setting when a correction begins, and can be
    /// overridden on-the-fly for just this text via `applyMode(_:)`.
    @Published private(set) var activeMode: CorrectionMode = .standard

    // MARK: Rephrase

    @Published private(set) var rephraseState: RephraseState = .idle
    /// Index of the alternative currently shown in the overlay (0-based).
    @Published var rephraseIndex: Int = 0

    // MARK: Explanation

    @Published private(set) var explanationState: ExplanationState = .idle

    // MARK: Private

    private let serverManager: LlamaServerManager
    private let debouncer: Debouncer
    private var currentTask: Task<Void, Never>?
    private var rephraseTask: Task<Void, Never>?
    private var explanationTask: Task<Void, Never>?

    /// The bundle ID of the frontmost app at the time `schedule` was called.
    /// Used to resolve per-app tone overrides.
    private var scheduledBundleId: String?

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
        self.debouncer = Debouncer(delay: SettingsStore.shared.debounceInterval)
    }

    // MARK: - Schedule / cancel

    /// Called on every keystroke; resets the debounce window.
    /// `bundleId` is the frontmost app's bundle ID, used to resolve per-app tone.
    func schedule(text: String, bundleId: String?) {
        // Cancel in-progress correction and any secondary requests immediately
        cancelAll()

        scheduledBundleId = bundleId
        debouncer.delay = SettingsStore.shared.debounceInterval
        debouncer.schedule { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginCorrection(text: text)
            }
        }
    }

    func cancel() {
        cancelAll()
    }

    // MARK: - On-demand actions

    /// Request 3 rephrase alternatives for the current corrected text.
    func requestRephrase() {
        guard case .finished = state, !correctionText.isEmpty else { return }
        guard serverManager.isRunning else { return }

        rephraseTask?.cancel()
        rephraseTask = nil
        rephraseState = .loading
        rephraseIndex = 0

        let text = correctionText
        let port = serverManager.port

        rephraseTask = Task { [weak self] in
            guard let self else { return }
            var raw = ""
            let client = LlamaClient(port: port)
            do {
                for try await token in client.rephrase(text) {
                    if Task.isCancelled { return }
                    raw += token
                }
                if !Task.isCancelled {
                    let alternatives = Self.parseAlternatives(from: raw)
                    self.rephraseState = alternatives.isEmpty
                        ? .error("Could not parse alternatives")
                        : .finished(alternatives)
                }
            } catch {
                if !Task.isCancelled {
                    self.rephraseState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Advance to the next rephrase alternative (wraps around).
    func nextRephrase() {
        guard case .finished(let alts) = rephraseState, !alts.isEmpty else { return }
        rephraseIndex = (rephraseIndex + 1) % alts.count
    }

    /// The alternative text currently selected, or nil if not in rephrase mode.
    var currentAlternative: String? {
        guard case .finished(let alts) = rephraseState else { return nil }
        guard rephraseIndex < alts.count else { return nil }
        return alts[rephraseIndex]
    }

    /// Request an explanation of what changed between original and corrected text.
    func requestExplanation() {
        guard case .finished = state,
              !originalText.isEmpty, !correctionText.isEmpty else { return }
        guard serverManager.isRunning else { return }

        explanationTask?.cancel()
        explanationTask = nil

        // Toggle: if already showing, hide it.
        if case .finished = explanationState {
            explanationState = .idle
            return
        }

        explanationState = .loading
        let original = originalText
        let corrected = correctionText
        let port = serverManager.port

        explanationTask = Task { [weak self] in
            guard let self else { return }
            var raw = ""
            let client = LlamaClient(port: port)
            do {
                for try await token in client.explain(original: original, corrected: corrected) {
                    if Task.isCancelled { return }
                    raw += token
                }
                if !Task.isCancelled {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.explanationState = trimmed.isEmpty
                        ? .error("No explanation returned")
                        : .finished(trimmed)
                }
            } catch {
                if !Task.isCancelled {
                    self.explanationState = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Private

    private func cancelAll() {
        debouncer.cancel()
        currentTask?.cancel()
        currentTask = nil
        rephraseTask?.cancel()
        rephraseTask = nil
        explanationTask?.cancel()
        explanationTask = nil
        state = .idle
        originalText = ""
        correctionText = ""
        rephraseState = .idle
        rephraseIndex = 0
        explanationState = .idle
    }

    private func beginCorrection(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard serverManager.isRunning else {
            state = .error("No model running — download one in Settings")
            return
        }

        // Resolve effective correction mode: per-app override > global setting
        let settings = SettingsStore.shared
        let effectiveMode: CorrectionMode
        if let bundleId = scheduledBundleId,
           let override = settings.appToneOverrides[bundleId] {
            effectiveMode = override
        } else {
            effectiveMode = settings.correctionMode
        }

        originalText = trimmed
        runCorrection(mode: effectiveMode, recordStats: true)
    }

    /// Re-run the correction on the current original text using a different style,
    /// without changing any global or per-app settings. Used by the overlay's
    /// on-the-fly style picker.
    func applyMode(_ mode: CorrectionMode) {
        guard !originalText.isEmpty else { return }
        guard mode != activeMode else { return }
        guard serverManager.isRunning else { return }

        // Reset secondary results — they no longer match the new correction.
        rephraseTask?.cancel()
        rephraseTask = nil
        rephraseState = .idle
        rephraseIndex = 0
        explanationTask?.cancel()
        explanationTask = nil
        explanationState = .idle

        runCorrection(mode: mode, recordStats: false)
    }

    /// Runs a streaming correction of `originalText` with the given mode.
    private func runCorrection(mode: CorrectionMode, recordStats: Bool) {
        currentTask?.cancel()

        activeMode = mode
        state = .correcting
        correctionText = ""

        let text = originalText
        let port = serverManager.port
        let dictionary = SettingsStore.shared.customDictionary

        currentTask = Task { [weak self] in
            guard let self else { return }
            let client = LlamaClient(port: port, mode: mode, dictionary: dictionary)
            do {
                for try await token in client.correct(text) {
                    if Task.isCancelled { return }
                    self.correctionText += token
                }
                if !Task.isCancelled {
                    // Trim stray trailing whitespace/newlines that models sometimes append.
                    self.correctionText = self.correctionText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .finished
                    if recordStats {
                        SettingsStore.shared.recordSuggestion()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Parses numbered alternatives ("1. ...\n2. ...\n3. ...") from raw model output.
    private static func parseAlternatives(from raw: String) -> [String] {
        let lines = raw.components(separatedBy: "\n")
        var results: [String] = []
        var currentText = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match "1.", "2.", "3." (with optional space after)
            if trimmed.count >= 2,
               let first = trimmed.first, first.isNumber,
               trimmed.dropFirst().hasPrefix(".") {
                // Save previous
                let prev = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prev.isEmpty { results.append(prev) }
                // Start new: strip "N. " prefix
                let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                currentText = rest
            } else if !currentText.isEmpty {
                currentText += "\n" + trimmed
            }
        }
        // Save last
        let last = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { results.append(last) }

        return results
    }
}
