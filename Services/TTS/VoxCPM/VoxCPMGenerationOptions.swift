import Foundation

/// Quality presets exposed to the user, mapped server-side to VoxCPM generation parameters
/// (see voxcpm_server/engine.py::QUALITY_PRESETS and docs/LOCAL_ENGINE_API.md).
enum VoxCPMQuality: String, CaseIterable, Codable, Identifiable {
    case fast
    case balanced
    case quality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return NSLocalizedString("Fast", comment: "VoxCPM quality preset")
        case .balanced: return NSLocalizedString("Balanced", comment: "VoxCPM quality preset")
        case .quality: return NSLocalizedString("Quality", comment: "VoxCPM quality preset")
        }
    }
}

/// Application-level language selection. `fr-CA`/`en-CA` are voice-profile preferences; VoxCPM2
/// auto-detects the language from the text itself.
enum VoxCPMLanguage: String, CaseIterable, Codable, Identifiable {
    case auto
    case fr
    case frCA = "fr-CA"
    case en
    case enCA = "en-CA"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return NSLocalizedString("Automatic", comment: "VoxCPM language mode")
        case .fr: return NSLocalizedString("French", comment: "VoxCPM language mode")
        case .frCA: return NSLocalizedString("French (Canada)", comment: "VoxCPM language mode")
        case .en: return NSLocalizedString("English", comment: "VoxCPM language mode")
        case .enCA: return NSLocalizedString("English (Canada)", comment: "VoxCPM language mode")
        }
    }
}

/// Options for a single synthesis request. Mirrors the loopback API request body.
struct VoxCPMGenerationOptions: Equatable {
    var voice: String = "default"
    var language: VoxCPMLanguage = .auto
    var quality: VoxCPMQuality = .balanced
    var speed: Double = 1.0
    var seed: Int?

    /// JSON body for `POST /v1/audio/speech`.
    func requestBody(input: String, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "input": input,
            "model": model,
            "voice": voice,
            "language": language.rawValue,
            "quality": quality.rawValue,
            "speed": speed,
            "response_format": "wav",
        ]
        if let seed { body["seed"] = seed }
        return body
    }
}
