import Foundation
import Observation

/// Lifecycle/health state of the local engine, surfaced in Settings. Mirrors the server's health
/// states plus app-side connection states.
enum VoxCPMEngineState: Equatable {
    case unknown
    case notRunning          // cannot connect / no token
    case starting
    case loadingModel
    case ready
    case generating
    case crashed(String)
    case unavailable(String)

    var displayName: String {
        switch self {
        case .unknown: return NSLocalizedString("Unknown", comment: "VoxCPM engine state")
        case .notRunning: return NSLocalizedString("Not running", comment: "VoxCPM engine state")
        case .starting: return NSLocalizedString("Starting…", comment: "VoxCPM engine state")
        case .loadingModel: return NSLocalizedString("Loading model…", comment: "VoxCPM engine state")
        case .ready: return NSLocalizedString("Ready", comment: "VoxCPM engine state")
        case .generating: return NSLocalizedString("Generating…", comment: "VoxCPM engine state")
        case .crashed: return NSLocalizedString("Crashed", comment: "VoxCPM engine state")
        case .unavailable: return NSLocalizedString("Unavailable", comment: "VoxCPM engine state")
        }
    }

    var isReady: Bool { self == .ready || self == .generating }

    /// Map a health `status` string to a state.
    static func from(status: String, detail: String?) -> VoxCPMEngineState {
        switch status {
        case "starting": return .starting
        case "loading_model": return .loadingModel
        case "ready": return .ready
        case "generating": return .generating
        case "crashed": return .crashed(detail ?? "")
        case "unavailable": return .unavailable(detail ?? "")
        default: return .unknown
        }
    }
}

/// Supervises the local engine: health polling, readiness, device/model reporting, and (Phase-2
/// convenience) an optional launch of the manual start script. App-managed spawn/hardening is Phase 5.
@Observable
@MainActor
final class VoxCPMEngineManager {
    static let shared = VoxCPMEngineManager()

    private(set) var state: VoxCPMEngineState = .unknown
    private(set) var device: String?
    private(set) var modelId: String?
    private(set) var sampleRate: Int?
    private(set) var version: String?
    private(set) var lastError: String?
    private(set) var cachedVoices: [VoxCPMVoiceProfile] = [.builtinDefault]

    private let settings: VoxCPMSettings
    private var pollTask: Task<Void, Never>?

    init(settings: VoxCPMSettings = .shared) {
        self.settings = settings
    }

    private var client: VoxCPMClient {
        VoxCPMClient(baseURL: settings.baseURL, tokenProvider: { [settings] in settings.readSessionToken() })
    }

    var isReady: Bool { state.isReady }

    // MARK: - Health

    /// One-shot health probe; updates published state. Never throws.
    @discardableResult
    func refreshHealth() async -> VoxCPMEngineState {
        do {
            let health = try await client.health()
            device = health.device
            modelId = health.model
            sampleRate = health.sampleRate
            version = health.version
            lastError = health.detail
            state = VoxCPMEngineState.from(status: health.status, detail: health.detail)
            if state.isReady { await refreshVoices() }
        } catch let error as VoxCPMError {
            lastError = error.localizedDescription
            state = .notRunning
        } catch {
            lastError = error.localizedDescription
            state = .notRunning
        }
        return state
    }

    /// Refresh the voice list from the engine (best-effort; keeps the built-in default on failure).
    func refreshVoices() async {
        guard let voices = try? await client.listVoices(), !voices.isEmpty else { return }
        cachedVoices = voices
    }

    // MARK: - Voice management

    @discardableResult
    func importVoice(displayName: String, language: String, kind: String, audioData: Data?,
                     filename: String?, transcript: String?, control: String?, notes: String?,
                     consentConfirmed: Bool) async throws -> VoxCPMVoiceProfile {
        let profile = try await client.importVoice(
            displayName: displayName, language: language, kind: kind, audioData: audioData,
            filename: filename, transcript: transcript, control: control, notes: notes,
            consentConfirmed: consentConfirmed)
        await refreshVoices()
        return profile
    }

    func deleteVoice(id: String) async throws {
        try await client.deleteVoice(id: id)
        await refreshVoices()
    }

    /// Synthesize a short preview clip for a voice and return the WAV bytes.
    func previewVoice(_ voiceId: String, text: String, quality: VoxCPMQuality) async throws -> Data {
        var options = VoxCPMGenerationOptions()
        options.voice = voiceId
        options.quality = quality
        return try await client.synthesize(text: text, model: settings.model, options: options)
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 3.0) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshHealth()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Start / restart (Phase-2 convenience)

    /// Run the user's configured launch command (if any) to start the engine, then poll for readiness.
    /// With no command configured, this is a no-op beyond a health refresh — the user starts the engine
    /// manually via `scripts/run_server.sh`.
    func start() async {
        let command = settings.serverLaunchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            state = .starting
            launch(command: command)
        }
        await waitUntilReady()
    }

    func restart() async {
        await start()
    }

    private func launch(command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
        } catch {
            lastError = "Failed to launch engine: \(error.localizedDescription)"
            state = .unavailable(lastError ?? "")
        }
    }

    private func waitUntilReady(timeout: TimeInterval = 90) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = await refreshHealth()
            if s.isReady { return }
            if case .crashed = s { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
