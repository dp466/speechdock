import XCTest
@testable import SpeechDock

/// Phase 3 tests: autonomous French/English detection and voice routing. Fully local (no engine).
final class VoxCPMLanguageTests: XCTestCase {

    private let detector = VoxCPMLanguageDetector()

    // MARK: - Detection

    func testDetectsFrench() {
        let text = "Bonjour, je m'appelle Claude et je vais vous lire ce texte à voix haute."
        XCTAssertEqual(detector.detect(text), .french)
    }

    func testDetectsEnglish() {
        let text = "Hello, my name is Claude and I will read this text aloud for you."
        XCTAssertEqual(detector.detect(text), .english)
    }

    func testShortTextIsUndetermined() {
        XCTAssertEqual(detector.detect("42"), .undetermined)
        XCTAssertEqual(detector.detect("Ok"), .undetermined)
    }

    func testSentenceSegmentation() {
        let text = "Bonjour le monde. Comment ça va? This is English!"
        let sentences = detector.sentences(in: text)
        XCTAssertEqual(sentences.count, 3)
    }

    func testPerSentenceDetectionPreservesOrder() {
        let text = "Ceci est une phrase en français assez longue pour être détectée. This is a clearly English sentence with enough words."
        let results = detector.detectPerSentence(text)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].language, .french)
        XCTAssertEqual(results[1].language, .english)
    }

    func testDetectedLanguageCodeMapping() {
        XCTAssertEqual(DetectedLanguage.french.languageCode, .fr)
        XCTAssertEqual(DetectedLanguage.english.languageCode, .en)
        XCTAssertEqual(DetectedLanguage.undetermined.languageCode, .auto)
    }

    // MARK: - Routing

    private func router(mode: VoxCPMLanguage) -> VoxCPMLanguageRouter {
        VoxCPMLanguageRouter(languageMode: mode, defaultFrenchVoice: "fr-voice",
                             defaultEnglishVoice: "en-voice", fallbackVoice: "picked")
    }

    func testAutoModeRoutesFrenchTextToFrenchVoice() {
        let route = router(mode: .auto).route(for: "Bonjour, ceci est un texte en français à lire.")
        XCTAssertEqual(route.voice, "fr-voice")
        XCTAssertEqual(route.language, .fr)
    }

    func testAutoModeRoutesEnglishTextToEnglishVoice() {
        let route = router(mode: .auto).route(for: "Hello, this is an English sentence to read aloud.")
        XCTAssertEqual(route.voice, "en-voice")
        XCTAssertEqual(route.language, .en)
    }

    func testAutoModeUndeterminedFallsBackToPickedVoice() {
        let route = router(mode: .auto).route(for: "42")
        XCTAssertEqual(route.voice, "picked")
        XCTAssertEqual(route.language, .auto)
    }

    func testExplicitFrenchModeIgnoresEnglishText() {
        let route = router(mode: .fr).route(for: "This text is clearly English.")
        XCTAssertEqual(route.voice, "fr-voice")
        XCTAssertEqual(route.language, .fr)
    }

    func testExplicitCanadianEnglishRoutesToEnglishVoiceWithCATag() {
        let route = router(mode: .enCA).route(for: "N'importe quel texte.")
        XCTAssertEqual(route.voice, "en-voice")
        XCTAssertEqual(route.language, .enCA)
    }

    func testEmptyDefaultVoiceFallsBackToDefault() {
        let r = VoxCPMLanguageRouter(languageMode: .fr, defaultFrenchVoice: "",
                                     defaultEnglishVoice: "", fallbackVoice: "")
        XCTAssertEqual(r.route(for: "Bonjour").voice, "default")
    }
}
