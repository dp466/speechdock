import Foundation

/// Decides which voice and language to use for a piece of text, given the user's language mode and
/// their default French/English voices. Pure logic (no I/O) so it is fully unit-testable.
///
/// - `.auto` mode: detect the language locally and route to the matching default voice — the user
///   never picks a language.
/// - explicit `.fr`/`.fr-CA`/`.en`/`.en-CA`: force that language and its default voice.
struct VoxCPMLanguageRouter {
    var languageMode: VoxCPMLanguage
    var defaultFrenchVoice: String
    var defaultEnglishVoice: String
    /// Voice explicitly chosen in the picker; used as a fallback when detection is undetermined.
    var fallbackVoice: String
    var detector = VoxCPMLanguageDetector()

    struct Route: Equatable {
        let voice: String
        let language: VoxCPMLanguage
    }

    func route(for text: String) -> Route {
        switch languageMode {
        case .fr, .frCA:
            return Route(voice: nonEmpty(defaultFrenchVoice), language: languageMode)
        case .en, .enCA:
            return Route(voice: nonEmpty(defaultEnglishVoice), language: languageMode)
        case .auto:
            switch detector.detect(text) {
            case .french:
                return Route(voice: nonEmpty(defaultFrenchVoice), language: .fr)
            case .english:
                return Route(voice: nonEmpty(defaultEnglishVoice), language: .en)
            case .undetermined:
                // Ambiguous (short/technical/mixed) → keep the user's picked voice, let the model auto-detect.
                return Route(voice: nonEmpty(fallbackVoice), language: .auto)
            }
        }
    }

    private func nonEmpty(_ voice: String) -> String {
        voice.trimmingCharacters(in: .whitespaces).isEmpty ? "default" : voice
    }
}
