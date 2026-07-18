import Foundation

/// A voice profile as reported by the local engine (`GET /v1/voices`). Metadata only — the raw
/// reference audio never leaves the Mac and is not carried here. Full profile management (import,
/// record, transcript, consent) is built out in Phase 3.
struct VoxCPMVoiceProfile: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let language: String
    let kind: String              // default | design | clone
    let hasReferenceAudio: Bool
    let hasReferenceTranscript: Bool
    let notes: String?
    let consentConfirmed: Bool
    let createdDate: String?
    let modifiedDate: String?

    enum CodingKeys: String, CodingKey {
        case id, displayName, language, kind
        case hasReferenceAudio, hasReferenceTranscript
        case notes, consentConfirmed, createdDate, modifiedDate
    }

    /// Tolerant decoding: the server always sends id/displayName/language/kind; the rest default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "default"
        hasReferenceAudio = try c.decodeIfPresent(Bool.self, forKey: .hasReferenceAudio) ?? false
        hasReferenceTranscript = try c.decodeIfPresent(Bool.self, forKey: .hasReferenceTranscript) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        consentConfirmed = try c.decodeIfPresent(Bool.self, forKey: .consentConfirmed) ?? false
        createdDate = try c.decodeIfPresent(String.self, forKey: .createdDate)
        modifiedDate = try c.decodeIfPresent(String.self, forKey: .modifiedDate)
    }

    init(id: String, displayName: String, language: String = "auto", kind: String = "default",
         hasReferenceAudio: Bool = false, hasReferenceTranscript: Bool = false, notes: String? = nil,
         consentConfirmed: Bool = false, createdDate: String? = nil, modifiedDate: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.kind = kind
        self.hasReferenceAudio = hasReferenceAudio
        self.hasReferenceTranscript = hasReferenceTranscript
        self.notes = notes
        self.consentConfirmed = consentConfirmed
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
    }

    /// The built-in no-reference voice always present on the engine.
    static let builtinDefault = VoxCPMVoiceProfile(id: "default", displayName: "VoxCPM2 Default")

    /// Map to the app's generic `TTSVoice` for the shared voice picker.
    var asTTSVoice: TTSVoice {
        TTSVoice(id: id, name: displayName, language: language == "auto" ? "" : language,
                 isDefault: id == "default")
    }
}
