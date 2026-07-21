import Foundation
import Combine

@MainActor
final class LlamaServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var statusMessage = "No model selected"

    let port: Int = 8765

    private var process: Process?
    private var currentModelPath: String?
    private var healthCheckTimer: Timer?
    private var restartAttempts = 0

    // MARK: - Lifecycle

    func start(modelPath: String) async {
        stop()
        currentModelPath = modelPath
        restartAttempts = 0
        // If a previous launch of this app crashed or was force-killed, its
        // llama-server child can be orphaned (reparented to launchd) and keep
        // holding our port, which makes every fresh launch fail immediately
        // and look like a crash loop. Clear the port before starting.
        await killAnyProcessOnPort()
        await launch(modelPath: modelPath)
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        process?.terminate()
        process = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - Private

    private func launch(modelPath: String) async {
        guard let serverURL = Bundle.main.url(forResource: "llama-server", withExtension: nil) else {
            statusMessage = "llama-server binary not found. Run scripts/setup.sh first."
            return
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            statusMessage = "Model file not found at: \(modelPath)"
            return
        }

        let proc = Process()
        proc.executableURL = serverURL
        proc.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "-ngl", "99",
            "-c", "4096",
            "--log-disable"
        ]
        // Suppress stdout/stderr from the subprocess
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedTermination()
            }
        }

        do {
            try proc.run()
            self.process = proc
            statusMessage = "Starting…"
        } catch {
            statusMessage = "Failed to launch: \(error.localizedDescription)"
            return
        }

        // Wait up to 15 seconds for the server to become healthy
        let healthy = await waitForHealth(seconds: 15)
        if healthy {
            isRunning = true
            statusMessage = "Running"
            startHealthMonitor()
        } else {
            statusMessage = "Server failed to start (health check timed out)"
            proc.terminate()
            process = nil
        }
    }

    private func waitForHealth(seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if await checkHealth() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func killAnyProcessOnPort() async {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()

        let pids = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
        guard !pids.isEmpty else { return }

        for pid in pids {
            kill(pid, SIGKILL)
        }
        // Give the kernel a moment to release the socket before we bind to it again.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func checkHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        do {
            var req = URLRequest(url: url, timeoutInterval: 2)
            req.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func startHealthMonitor() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                let ok = await self.checkHealth()
                if !ok {
                    self.isRunning = false
                    self.handleUnexpectedTermination()
                }
            }
        }
    }

    private func handleUnexpectedTermination() {
        guard isRunning || process != nil else { return }
        isRunning = false
        process = nil

        guard restartAttempts < 3, let path = currentModelPath else {
            statusMessage = "Server crashed. Open Settings to restart."
            return
        }

        restartAttempts += 1
        statusMessage = "Restarting… (attempt \(restartAttempts))"

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.launch(modelPath: path)
        }
    }
}
