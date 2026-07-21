import Foundation
import Combine

enum CorrectionState: Equatable {
    case idle
    case correcting
    case finished
    case error(String)
}

@MainActor
final class CorrectionEngine: ObservableObject {
    @Published private(set) var state: CorrectionState = .idle
    @Published private(set) var correctionText: String = ""

    private let serverManager: LlamaServerManager
    private let debouncer: Debouncer
    private var currentTask: Task<Void, Never>?

    init(serverManager: LlamaServerManager) {
        self.serverManager = serverManager
        self.debouncer = Debouncer(delay: SettingsStore.shared.debounceInterval)
    }

    // Called on every keystroke; resets the debounce window.
    func schedule(text: String) {
        // Cancel in-progress stream immediately when new text arrives
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        correctionText = ""

        debouncer.delay = SettingsStore.shared.debounceInterval
        debouncer.schedule { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginCorrection(text: text)
            }
        }
    }

    func cancel() {
        debouncer.cancel()
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        correctionText = ""
    }

    // MARK: - Private

    private func beginCorrection(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard serverManager.isRunning else {
            state = .error("No model running — download one in Settings")
            return
        }

        state = .correcting
        correctionText = ""

        let port = serverManager.port
        currentTask = Task { [weak self] in
            guard let self else { return }
            let client = LlamaClient(port: port)
            do {
                for try await token in client.correct(trimmed) {
                    if Task.isCancelled { return }
                    self.correctionText += token
                }
                if !Task.isCancelled {
                    // Models frequently trail a response with a stray newline/space;
                    // strip it so Accept doesn't introduce a line break the user never typed.
                    self.correctionText = self.correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .finished
                }
            } catch {
                if !Task.isCancelled {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }
}
