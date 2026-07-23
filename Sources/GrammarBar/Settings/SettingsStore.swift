import Foundation
import Combine

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: - Enable / Disable

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "isEnabled") }
    }

    // MARK: - Model

    @Published var selectedModelId: String? {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: "selectedModelId") }
    }

    // MARK: - Timing

    @Published var debounceInterval: Double {
        didSet { UserDefaults.standard.set(debounceInterval, forKey: "debounceInterval") }
    }

    // MARK: - Appearance

    /// When enabled, the correction bubble grows to fit long suggestions instead of
    /// scrolling internally within a fixed height.
    @Published var resizeBubbleToFitText: Bool {
        didSet { UserDefaults.standard.set(resizeBubbleToFitText, forKey: "resizeBubbleToFitText") }
    }

    // MARK: - Correction mode

    /// The active correction style applied globally (unless a per-app override exists).
    @Published var correctionMode: CorrectionMode {
        didSet { UserDefaults.standard.set(correctionMode.rawValue, forKey: "correctionMode") }
    }

    // MARK: - Custom dictionary

    /// Words/terms the model should never alter.
    @Published var customDictionary: [String] {
        didSet { UserDefaults.standard.set(customDictionary, forKey: "customDictionary") }
    }

    // MARK: - Per-app tone overrides

    /// Maps bundle IDs to per-app correction modes that override `correctionMode`.
    @Published var appToneOverrides: [String: CorrectionMode] {
        didSet {
            let raw = appToneOverrides.mapValues { $0.rawValue }
            UserDefaults.standard.set(raw, forKey: "appToneOverrides")
        }
    }

    // MARK: - App block-list

    /// Bundle IDs of apps where correction is disabled entirely. Empty = active everywhere.
    @Published var blockedBundleIds: Set<String> {
        didSet {
            let arr = Array(blockedBundleIds)
            UserDefaults.standard.set(arr, forKey: "blockedBundleIds")
        }
    }

    // MARK: - Stats

    @Published var totalSuggestions: Int {
        didSet { UserDefaults.standard.set(totalSuggestions, forKey: "totalSuggestions") }
    }

    @Published var totalAccepted: Int {
        didSet { UserDefaults.standard.set(totalAccepted, forKey: "totalAccepted") }
    }

    /// ISO8601 date string for the start of the current weekly window.
    @Published var weekWindowStart: String {
        didSet { UserDefaults.standard.set(weekWindowStart, forKey: "weekWindowStart") }
    }

    @Published var weekAccepted: Int {
        didSet { UserDefaults.standard.set(weekAccepted, forKey: "weekAccepted") }
    }

    // MARK: - Launch at login

    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        selectedModelId = defaults.string(forKey: "selectedModelId")
        debounceInterval = defaults.object(forKey: "debounceInterval") as? Double ?? 0.4
        resizeBubbleToFitText = defaults.object(forKey: "resizeBubbleToFitText") as? Bool ?? false

        // Migrate legacy proofreadOnly bool → correctionMode
        if let storedRaw = defaults.string(forKey: "correctionMode"),
           let mode = CorrectionMode(rawValue: storedRaw) {
            correctionMode = mode
        } else if defaults.object(forKey: "proofreadOnly") as? Bool == true {
            correctionMode = .proofread
        } else {
            correctionMode = .standard
        }

        customDictionary = defaults.array(forKey: "customDictionary") as? [String] ?? []

        let rawOverrides = defaults.dictionary(forKey: "appToneOverrides") as? [String: String] ?? [:]
        appToneOverrides = rawOverrides.compactMapValues { CorrectionMode(rawValue: $0) }

        let arr = defaults.array(forKey: "blockedBundleIds") as? [String] ?? []
        blockedBundleIds = Set(arr)

        totalSuggestions = defaults.integer(forKey: "totalSuggestions")
        totalAccepted = defaults.integer(forKey: "totalAccepted")
        weekWindowStart = defaults.string(forKey: "weekWindowStart") ?? Self.currentWeekStart()
        weekAccepted = defaults.integer(forKey: "weekAccepted")
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
    }

    // MARK: - Stats helpers

    /// Call when the engine produces a new suggestion.
    func recordSuggestion() {
        rollWeekIfNeeded()
        totalSuggestions += 1
    }

    /// Call when the user accepts a suggestion.
    func recordAccepted() {
        rollWeekIfNeeded()
        totalAccepted += 1
        weekAccepted += 1
    }

    private func rollWeekIfNeeded() {
        let current = Self.currentWeekStart()
        if current != weekWindowStart {
            weekWindowStart = current
            weekAccepted = 0
        }
    }

    private static func currentWeekStart() -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // Monday
        let startOfWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return ISO8601DateFormatter().string(from: startOfWeek)
    }
}
