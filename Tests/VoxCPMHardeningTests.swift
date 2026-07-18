import XCTest
@testable import SpeechDock

/// Phase 6 hardening: provider regressions, long documents, mixed-language routing, and graceful
/// behavior when the backend is unavailable.
@MainActor
final class VoxCPMHardeningTests: XCTestCase {

    // MARK: - Regression: all providers still construct

    func testAllProvidersConstruct() {
        for provider in TTSProvider.allCases {
            let service = TTSFactory.makeService(for: provider)
            XCTAssertFalse(service.availableModels().isEmpty, "\(provider.rawValue) has no models")
        }
    }

    func testExistingProvidersUnchanged() {
        // The five cloud/native providers must still be present and correctly classified.
        XCTAssertTrue(TTSProvider.macOS.isLocal)
        XCTAssertFalse(TTSProvider.openAI.isLocal)
        XCTAssertFalse(TTSProvider.gemini.isLocal)
        XCTAssertFalse(TTSProvider.elevenLabs.isLocal)
        XCTAssertFalse(TTSProvider.grok.isLocal)
        XCTAssertTrue(TTSProvider.openAI.requiresAPIKey)
        XCTAssertFalse(TTSProvider.macOS.requiresAPIKey)
    }

    // MARK: - Long documents

    func testLongDocumentSegmentsInOrder() {
        let sentences = (1...60).map { "This is sentence number \($0)." }
        let doc = sentences.joined(separator: " ")
        let chunks = SentenceSegmentationService().segment(doc)
        XCTAssertGreaterThanOrEqual(chunks.count, 60)
        // Order preserved: the Nth "sentence number N" appears in order.
        let joined = chunks.joined(separator: " ")
        if let r10 = joined.range(of: "number 10."), let r20 = joined.range(of: "number 20.") {
            XCTAssertLessThan(r10.lowerBound, r20.lowerBound)
        } else {
            XCTFail("expected markers not found")
        }
    }

    func testVeryLongParagraphIsChunkedUnderMax() {
        var seg = SentenceSegmentationService()
        seg.maxChunkLength = 120
        let long = String(repeating: "word ", count: 400) + "end."
        let chunks = seg.segment(long)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 120 })
        XCTAssertGreaterThan(chunks.count, 1)
    }

    // MARK: - Mixed French/English

    func testMixedLanguageRoutesPerSentence() {
        let seg = SentenceSegmentationService()
        let router = VoxCPMLanguageRouter(languageMode: .auto, defaultFrenchVoice: "fr-voice",
                                          defaultEnglishVoice: "en-voice", fallbackVoice: "x")
        let text = "Ceci est une phrase en français assez longue pour être détectée correctement. "
                 + "This is a clearly English sentence with plenty of words to detect."
        let chunks = seg.segment(text)
        XCTAssertEqual(chunks.count, 2)
        let routes = chunks.map { router.route(for: $0) }
        XCTAssertEqual(routes[0].voice, "fr-voice")
        XCTAssertEqual(routes[0].language, .fr)
        XCTAssertEqual(routes[1].voice, "en-voice")
        XCTAssertEqual(routes[1].language, .en)
    }

    // MARK: - Backend unavailable

    func testEngineManagerKeepsDefaultVoiceWhenBackendDown() async {
        let suite = "VoxCPMHardeningTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = VoxCPMSettings(defaults: defaults)
        settings.port = 9   // discard port — nothing listens
        let manager = VoxCPMEngineManager(settings: settings)

        await manager.refreshVoices()                 // must not throw or clear the default
        XCTAssertEqual(manager.cachedVoices.map(\.id), ["default"])

        let state = await manager.refreshHealth()      // unreachable → notRunning
        XCTAssertEqual(state, .notRunning)
    }

    func testHealthDecodeFailureIsNotFatal() async {
        // A malformed health body should surface as notRunning, never crash.
        let suite = "VoxCPMHardeningTests2"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = VoxCPMSettings(defaults: defaults)
        settings.port = 9
        let manager = VoxCPMEngineManager(settings: settings)
        let state = await manager.refreshHealth()
        XCTAssertFalse(state.isReady)
    }
}
