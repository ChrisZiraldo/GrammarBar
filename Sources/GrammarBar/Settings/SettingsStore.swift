import Foundation
import Combine

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "isEnabled") }
    }

    @Published var selectedModelId: String? {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: "selectedModelId") }
    }

    @Published var debounceInterval: Double {
        didSet { UserDefaults.standard.set(debounceInterval, forKey: "debounceInterval") }
    }

    /// When enabled, corrections are limited to spelling, grammar, and punctuation —
    /// the model is instructed not to reword or rephrase the text otherwise.
    @Published var proofreadOnly: Bool {
        didSet { UserDefaults.standard.set(proofreadOnly, forKey: "proofreadOnly") }
    }

    /// Bundle IDs of apps where correction is active. Empty = all native apps.
    @Published var allowedBundleIds: Set<String> {
        didSet {
            let arr = Array(allowedBundleIds)
            UserDefaults.standard.set(arr, forKey: "allowedBundleIds")
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        selectedModelId = defaults.string(forKey: "selectedModelId")
        debounceInterval = defaults.object(forKey: "debounceInterval") as? Double ?? 0.4
        proofreadOnly = defaults.object(forKey: "proofreadOnly") as? Bool ?? false
        let arr = defaults.array(forKey: "allowedBundleIds") as? [String] ?? []
        allowedBundleIds = Set(arr)
    }
}
