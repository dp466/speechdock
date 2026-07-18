import Foundation
import Observation

/// User-configurable settings for the local VoxCPM2 engine, persisted in UserDefaults.
///
/// The session token is NOT stored here — it is read from the token file the engine writes
/// (`~/Library/Application Support/ScreenVoice/Configuration/engine.token`, 0600). In Phase 5, when the
/// app spawns the engine itself, it will generate and inject the token instead.
@Observable
@MainActor
final class VoxCPMSettings {
    static let shared = VoxCPMSettings()

    private enum Key {
        static let host = "voxcpm.host"
        static let port = "voxcpm.port"
        static let model = "voxcpm.model"
        static let quality = "voxcpm.quality"
        static let defaultFrenchVoice = "voxcpm.defaultFrenchVoice"
        static let defaultEnglishVoice = "voxcpm.defaultEnglishVoice"
        static let languageMode = "voxcpm.languageMode"
        static let serverLaunchCommand = "voxcpm.serverLaunchCommand"
    }

    private let defaults: UserDefaults
    private var isLoading = false

    var host: String { didSet { save(Key.host, host) } }
    var port: Int { didSet { save(Key.port, port) } }
    var model: String { didSet { save(Key.model, model) } }
    var quality: VoxCPMQuality { didSet { save(Key.quality, quality.rawValue) } }
    var defaultFrenchVoice: String { didSet { save(Key.defaultFrenchVoice, defaultFrenchVoice) } }
    var defaultEnglishVoice: String { didSet { save(Key.defaultEnglishVoice, defaultEnglishVoice) } }
    var languageMode: VoxCPMLanguage { didSet { save(Key.languageMode, languageMode.rawValue) } }
    /// Optional shell command the app runs to start the engine (Phase 2 convenience). Empty = manual start.
    var serverLaunchCommand: String { didSet { save(Key.serverLaunchCommand, serverLaunchCommand) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true
        host = (defaults.string(forKey: Key.host)) ?? "127.0.0.1"
        let storedPort = defaults.integer(forKey: Key.port)
        port = storedPort == 0 ? 8757 : storedPort
        model = (defaults.string(forKey: Key.model)) ?? "openbmb/VoxCPM2"
        quality = VoxCPMQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .balanced
        defaultFrenchVoice = (defaults.string(forKey: Key.defaultFrenchVoice)) ?? "default"
        defaultEnglishVoice = (defaults.string(forKey: Key.defaultEnglishVoice)) ?? "default"
        languageMode = VoxCPMLanguage(rawValue: defaults.string(forKey: Key.languageMode) ?? "") ?? .auto
        serverLaunchCommand = (defaults.string(forKey: Key.serverLaunchCommand)) ?? ""
        isLoading = false
    }

    private func save(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    // MARK: - Derived

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    /// Location the engine writes its session token to (shared ScreenVoice app-support dir).
    static var tokenFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["VOXCPM_TOKEN_FILE"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ScreenVoice/Configuration", isDirectory: true)
        return base.appendingPathComponent("engine.token")
    }

    /// Read the session token (env var wins, matching the engine), or nil if not available yet.
    func readSessionToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["VOXCPM_SERVER_TOKEN"], !env.isEmpty {
            return env
        }
        guard let raw = try? String(contentsOf: Self.tokenFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
