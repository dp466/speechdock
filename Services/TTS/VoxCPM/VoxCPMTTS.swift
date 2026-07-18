import Foundation
@preconcurrency import AVFoundation

/// Local, fully offline neural TTS provider backed by the VoxCPM2 loopback engine.
///
/// Phase 2: non-streaming — fetch a full WAV from `POST /v1/audio/speech`, then play it through the
/// shared `TTSAudioPlaybackController` (same playback/word-highlight/output-device path as other
/// providers). Streaming and sentence queueing arrive in Phase 4. When the engine is unavailable,
/// `speak` throws a `VoxCPMError` whose `shouldFallBackToNative` is true so AppState can degrade to
/// macOS Native TTS — never to a cloud provider.
@MainActor
final class VoxCPMTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool { playbackController.isSpeaking }
    var isPaused: Bool { playbackController.isPaused }

    var selectedVoice: String = "default"
    var selectedModel: String = "openbmb/VoxCPM2"
    var selectedSpeed: Double = 1.0
    var selectedLanguage: String = ""   // "" = auto
    var audioOutputDeviceUID: String = "" {
        didSet { playbackController.outputDeviceUID = audioOutputDeviceUID }
    }

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { "wav" }

    var supportsSpeedControl: Bool { true }
    /// Streaming is added in Phase 4; Phase 2 always generates the full clip first.
    var useStreamingMode: Bool {
        get { false }
        set { /* ignored until Phase 4 */ }
    }

    private let settings: VoxCPMSettings
    private let manager: VoxCPMEngineManager
    private let playbackController = TTSAudioPlaybackController()
    private var synthesisTask: Task<Void, Never>?

    init(settings: VoxCPMSettings = .shared, manager: VoxCPMEngineManager = .shared) {
        self.settings = settings
        self.manager = manager
        super.init()
        setupPlaybackController()
    }

    private var client: VoxCPMClient {
        VoxCPMClient(baseURL: settings.baseURL, tokenProvider: { [settings] in settings.readSessionToken() })
    }

    private func setupPlaybackController() {
        playbackController.onPlaybackStarted = { [weak self] in
            guard let self else { return }
            self.delegate?.ttsDidStartSpeaking(self)
        }
        playbackController.onWordHighlight = { [weak self] range, text in
            guard let self else { return }
            self.delegate?.tts(self, willSpeakRange: range, of: text)
        }
        playbackController.onFinishSpeaking = { [weak self] success in
            guard let self else { return }
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        playbackController.onError = { [weak self] error in
            guard let self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    func speak(text: String) async throws {
        guard !text.isEmpty else { throw TTSError.noTextProvided }
        stop()

        // Autonomous routing: in "Automatic" mode the language is detected locally (no user choice);
        // explicit fr/en modes force that language. Falls back to the picked voice when ambiguous.
        let router = VoxCPMLanguageRouter(
            languageMode: settings.languageMode,
            defaultFrenchVoice: settings.defaultFrenchVoice,
            defaultEnglishVoice: settings.defaultEnglishVoice,
            fallbackVoice: selectedVoice.isEmpty ? "default" : selectedVoice
        )
        let route = router.route(for: text)

        let options = VoxCPMGenerationOptions(
            voice: route.voice,
            language: route.language,
            quality: settings.quality,
            speed: selectedSpeed,
            seed: nil
        )

        let wav = try await client.synthesize(text: text, model: selectedModel, options: options)
        lastAudioData = wav

        // Speed is applied at playback (AVAudioEngine time-pitch), matching other providers.
        playbackController.setPlaybackRate(Float(selectedSpeed))
        // Phase 2: sentence-level unit, no word highlighting (accurate timestamps come later).
        try playbackController.playAudio(data: wav, fileExtension: "wav")
    }

    func pause() { playbackController.pause() }
    func resume() { playbackController.resume() }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        playbackController.stopPlayback()
    }

    func setPlaybackRate(_ rate: Float) {
        playbackController.setPlaybackRate(rate)
    }

    func clearAudioCache() {
        lastAudioData = nil
    }

    func availableVoices() -> [TTSVoice] {
        let voices = manager.cachedVoices.map { $0.asTTSVoice }
        return voices.isEmpty ? [VoxCPMVoiceProfile.builtinDefault.asTTSVoice] : voices
    }

    func availableModels() -> [TTSModelInfo] {
        [TTSModelInfo(id: "openbmb/VoxCPM2", name: "VoxCPM2",
                      description: NSLocalizedString("Local neural TTS", comment: "VoxCPM model"),
                      isDefault: true)]
    }

    func speedRange() -> ClosedRange<Double> { 0.5...2.0 }

    /// Whether an error thrown from `speak` should trigger macOS-Native fallback.
    static func shouldFallBackToNative(for error: Error) -> Bool {
        (error as? VoxCPMError)?.shouldFallBackToNative ?? false
    }
}
