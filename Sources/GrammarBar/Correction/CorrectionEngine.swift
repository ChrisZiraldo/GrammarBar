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
    /// Reads the focused field only after typing has stopped. A key event reaches
    /// GrammarBar before the target app updates its accessibility value, so
    /// snapshotting during the event callback can omit the latest character.
    private var scheduledTextProvider: (@MainActor () -> String?)?

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
        self.debouncer = Debouncer(delay: SettingsStore.shared.debounceInterval)
    }

    // MARK: - Schedule / cancel

    /// Called on every keystroke; resets the debounce window. The text provider
    /// is evaluated when the window expires, after the target app has processed
    /// the final key event.
    /// `bundleId` is the frontmost app's bundle ID, used to resolve per-app tone.
    func schedule(bundleId: String?, textProvider: @escaping @MainActor () -> String?) {
        // Cancel in-progress correction and any secondary requests immediately
        cancelAll()

        scheduledBundleId = bundleId
        scheduledTextProvider = textProvider
        debouncer.delay = SettingsStore.shared.debounceInterval
        debouncer.schedule { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let text = self.scheduledTextProvider?() else { return }
                self.beginCorrection(text: text)
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
        scheduledTextProvider = nil
        rephraseState = .idle
        rephraseIndex = 0
        explanationState = .idle
    }

    private func beginCorrection(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }
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
                // Accumulate the raw stream separately and show a display-cleaned
                // version each token, so the "===GB-…===" fence never flashes in
                // the overlay while it streams in (even partially).
                var raw = ""
                for try await token in client.correct(text) {
                    if Task.isCancelled { return }
                    raw += token
                    self.correctionText = Self.strippedForDisplay(raw)
                }
                if !Task.isCancelled {
                    // Run the raw output through the sanitizer to strip preambles/
                    // wrappers and reject clearly broken responses (e.g. prompt
                    // injection leakage).
                    if let clean = Self.sanitize(
                        output: raw,
                        original: text,
                        mode: mode
                    ) {
                        self.correctionText = clean
                        self.state = .finished
                        if recordStats {
                            SettingsStore.shared.recordSuggestion()
                        }
                    } else {
                        // Output was empty or implausibly malformed — surface as an error
                        // so the overlay shows a useful message instead of writing garbage.
                        self.correctionText = ""
                        self.state = .error("Unexpected model response — try again")
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

    /// Strips common leaked preambles and wrappers that small models sometimes
    /// prepend or append despite being told not to.
    ///
    /// Examples of things stripped:
    ///   "Here is the corrected text: ..."
    ///   "Sure! Here's the corrected version:\n..."
    ///   Surrounding backtick/quote pairs
    ///
    /// Returns nil when the result is clearly broken (empty after stripping, or
    /// implausibly long relative to the input in non-expanding modes).
    static func sanitize(
        output: String,
        original: String,
        mode: CorrectionMode
    ) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip GrammarBar's own anti-injection fence if the model echoed it
        // back. Small models — especially in Proofread mode, where they're told
        // to reproduce the text with the smallest possible edit — sometimes copy
        // the trailing "===GB-XXXXXXXX===" marker (and occasionally the leading
        // instruction line) verbatim into their answer.
        text = stripInjectionFence(text)

        // Strip surrounding single/double quotes or backtick fences that the
        // model sometimes wraps the entire answer in.
        let quoteChars: [Character] = ["\"", "'", "`"]
        if text.count >= 2,
           let first = text.first, quoteChars.contains(first),
           text.last == first {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip triple-backtick code fences (``` … ```)
        if text.hasPrefix("```") && text.hasSuffix("```") && text.count > 6 {
            text = String(text.dropFirst(3).dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip common preamble patterns.  We iterate so that e.g.
        // "Sure! Here is the corrected text:\n…" collapses in one pass.
        let preamblePatterns: [String] = [
            "here is the corrected text:",
            "here's the corrected text:",
            "here is the corrected version:",
            "here's the corrected version:",
            "here is the corrected sentence:",
            "here's the corrected sentence:",
            "corrected text:",
            "corrected version:",
            "sure! ",
            "sure, ",
            "of course! ",
            "of course, ",
            "certainly! ",
            "certainly, ",
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in preamblePatterns {
                if text.lowercased().hasPrefix(pattern) {
                    text = String(text.dropFirst(pattern.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }

        // Reject empty results.
        guard !text.isEmpty else { return nil }

        // For non-expanding modes (standard, proofread), reject output that is
        // wildly longer than the input — a strong signal the model went off-rails.
        // Expanding modes (formal, friendly, confident, concise, casual) can
        // legitimately grow or shrink, so we skip this check for them.
        let nonExpandingModes: Set<CorrectionMode> = [.standard, .proofread]
        if nonExpandingModes.contains(mode) {
            let ratio = Double(text.count) / Double(max(original.count, 1))
            if ratio > 3.0 {
                return nil
            }
        }

        return text
    }

    /// Removes GrammarBar's own anti-injection fence — the "===GB-XXXXXXXX==="
    /// markers (8 hex chars, random per request) and the accompanying
    /// "…enclosed by the markers…" instruction line — that a model sometimes
    /// echoes back into its output. Matches on the fixed shape since the nonce
    /// itself varies per request.
    private static func stripInjectionFence(_ input: String) -> String {
        var text = input

        // Drop the leading instruction line if it was echoed back.
        if let range = text.range(
            of: #"(?im)^.*enclosed by the markers.*$\n?"#,
            options: .regularExpression
        ) {
            text.removeSubrange(range)
        }

        // Remove any standalone marker lines or inline marker tokens.
        text = text.replacingOccurrences(
            of: #"===GB-[0-9A-Fa-f]{8}==="#,
            with: "",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live-display cleanup used while streaming. Removes complete fence markers
    /// (via `stripInjectionFence`) and additionally trims a *partial* trailing
    /// marker still being emitted token-by-token (e.g. "===GB-64A7"), so the
    /// fence never appears in the overlay before the final sanitize pass.
    private static func strippedForDisplay(_ raw: String) -> String {
        var text = stripInjectionFence(raw)
        // Drop a trailing, still-incomplete fence marker. Only affects the live
        // view; the final committed text comes from the strict `sanitize` pass.
        if let range = text.range(
            of: #"(?i)\s*=+(?:GB-?[0-9A-F]*=*)?$"#,
            options: .regularExpression
        ) {
            text.replaceSubrange(range, with: "")
        }
        return text
    }

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
