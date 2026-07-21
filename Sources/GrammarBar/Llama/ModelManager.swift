import Foundation
import Combine

enum ModelDownloadState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case error(String)
}

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadStates: [String: ModelDownloadState] = [:]

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    private init() {
        refreshInstalledStates()
    }

    // MARK: - Paths

    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("GrammarBar/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func installedPath(for entry: ModelEntry) -> URL? {
        let path = Self.modelsDirectory.appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func diskUsageMB(for entry: ModelEntry) -> Int? {
        guard let path = installedPath(for: entry),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? Int else { return nil }
        return size / (1024 * 1024)
    }

    // MARK: - Install / Delete

    func refreshInstalledStates() {
        for entry in ModelCatalog.all {
            if installedPath(for: entry) != nil {
                if downloadStates[entry.id] != .installed {
                    downloadStates[entry.id] = .installed
                }
            } else if case .downloading = downloadStates[entry.id] {
                // leave it
            } else {
                downloadStates[entry.id] = .notInstalled
            }
        }
    }

    func delete(entry: ModelEntry) {
        guard let path = installedPath(for: entry) else { return }
        try? FileManager.default.removeItem(at: path)
        downloadStates[entry.id] = .notInstalled

        // Deselect if this was the active model
        if SettingsStore.shared.selectedModelId == entry.id {
            SettingsStore.shared.selectedModelId = nil
        }
    }

    // MARK: - Download

    func download(entry: ModelEntry) {
        guard downloadStates[entry.id] != .installed else { return }
        guard case .downloading = downloadStates[entry.id] else { startDownload(entry: entry); return }
    }

    func cancelDownload(entry: ModelEntry) {
        downloadTasks[entry.id]?.cancel()
        downloadTasks[entry.id] = nil
        observations[entry.id] = nil
        downloadStates[entry.id] = .notInstalled
    }

    private func startDownload(entry: ModelEntry) {
        guard let url = URL(string: entry.downloadURL) else {
            downloadStates[entry.id] = .error("Invalid download URL")
            return
        }

        downloadStates[entry.id] = .downloading(progress: 0)

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self else { return }

            self.downloadTasks[entry.id] = nil
            self.observations[entry.id] = nil

            if let error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                Task { @MainActor in
                    self.downloadStates[entry.id] = .error(error.localizedDescription)
                }
                return
            }

            guard let tempURL else {
                Task { @MainActor in
                    self.downloadStates[entry.id] = .error("No file received")
                }
                return
            }

            let dest = Self.modelsDirectory.appendingPathComponent(entry.filename)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                Task { @MainActor in
                    self.downloadStates[entry.id] = .installed
                }
            } catch {
                Task { @MainActor in
                    self.downloadStates[entry.id] = .error(error.localizedDescription)
                }
            }
        }

        // Progress observation
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.downloadStates[entry.id] = .downloading(progress: progress.fractionCompleted)
            }
        }
        observations[entry.id] = observation
        downloadTasks[entry.id] = task
        task.resume()
    }
}
