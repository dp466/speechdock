import Foundation
import NaturalLanguage

/// On-device French/English detection using Apple's Natural Language framework. Fully local, no
/// network, no LLM (per spec §Language handling). Detects the language of selected text or OCR'd
/// screen text so the app can pick the right voice without the user choosing a language.
struct VoxCPMLanguageDetector {

    /// Minimum confidence for the top hypothesis to be trusted; below this we report `.auto`
    /// (ambiguous) so routing falls back to the configured default rather than guessing on, e.g.,
    /// a lone technical word or a URL.
    var confidenceThreshold: Double = 0.60

    /// Detect the dominant language of a whole passage, collapsed to the languages we route on.
    func detect(_ text: String) -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .undetermined }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)

        let french = hypotheses[.french] ?? 0
        let english = hypotheses[.english] ?? 0

        // Prefer whichever of fr/en scores higher, but only if it clears the threshold.
        if french >= english, french >= confidenceThreshold { return .french }
        if english > french, english >= confidenceThreshold { return .english }

        // Fall back to the dominant language if it happens to be fr/en with any confidence.
        switch recognizer.dominantLanguage {
        case .french: return .french
        case .english: return .english
        default: return .undetermined
        }
    }

    /// Split text into sentences (for per-segment detection in mixed-language passages). Used by the
    /// Phase 4 queue; exposed now so routing logic is testable end to end.
    func sentences(in text: String) -> [String] {
        var result: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    /// Detect the language of each sentence, preserving order (for Phase 4 mixed-language reading).
    func detectPerSentence(_ text: String) -> [(sentence: String, language: DetectedLanguage)] {
        sentences(in: text).map { ($0, detect($0)) }
    }
}

/// Result of detection, limited to the languages ScreenVoice routes on.
enum DetectedLanguage: Equatable {
    case french
    case english
    case undetermined

    /// The generic language code sent to the engine (`"fr"`, `"en"`, or `"auto"`).
    var languageCode: VoxCPMLanguage {
        switch self {
        case .french: return .fr
        case .english: return .en
        case .undetermined: return .auto
        }
    }
}
