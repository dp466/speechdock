import Foundation

/// Spawns and supervises the local engine as a child process (Phase 5, app-managed start/restart).
///
/// Runs the user's launch command via `/bin/zsh -lc`, monitors termination, and auto-restarts on an
/// unexpected exit (bounded, with backoff). No `launchd`, no privileged helper — just a child process
/// under the app's hardened runtime. The engine writes its own session token file, which the app reads.
@MainActor
final class VoxCPMProcessManager {
    private(set) var isRunning = false
    private(set) var lastExitCode: Int32?
    private(set) var restartCount = 0

    /// Called (on the main actor) whenever the child exits, with its status.
    var onExit: ((Int32) -> Void)?

    var maxAutoRestarts = 3

    private var process: Process?
    private var command: String?
    private var wantsRunning = false

    /// Start (or restart) the engine with `command`. Passing an empty command is a no-op.
    func start(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.command = trimmed
        wantsRunning = true
        restartCount = 0
        spawn()
    }

    /// Stop the child and disable auto-restart.
    func stop() {
        wantsRunning = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func spawn() {
        guard let command else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.handleExit(code) }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            isRunning = false
            lastExitCode = -1
            onExit?(-1)
        }
    }

    private func handleExit(_ code: Int32) {
        isRunning = false
        lastExitCode = code
        process = nil
        onExit?(code)

        // Auto-restart only on an *unexpected* exit while we still want it running.
        guard wantsRunning, restartCount < maxAutoRestarts else { return }
        restartCount += 1
        let delay = Double(restartCount)  // simple linear backoff
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.wantsRunning else { return }
            self.spawn()
        }
    }
}
