import Foundation
@preconcurrency import AVFoundation

/// Local, fully offline neural TTS provider backed by the VoxCPM2 loopback engine.
///
/// Phase 4: sentence-queued playback. `speak` segments the text, routes each sentence to a voice/
/// language (autonomous FR/EN detection in Automatic mode), and drives `VoxCPMPlaybackQueue`, which
/// generates the next chunk while the current one plays. The first chunk is pre-flighted so an
/// unavailable engine still throws a `VoxCPMError` (→ AppState falls back to macOS Native, never a
/// cloud provider). Streaming (server `/stream` + a streaming player) is the remaining Phase 4 tail.
@MainActor
final class VoxCPMTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool { queue.isPlaying }
    var isPaused: Bool { queue.isPaused }

    var selectedVoice: String = "default"
    var selectedModel: String = "openbmb/VoxCPM2"
    var selectedSpeed: Double = 1.0
    var selectedLanguage: String = ""   // "" = auto
    var audioOutputDeviceUID: String = "" {
        didSet { chunkPlayer.outputDeviceUID = audioOutputDeviceUID }
    }

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { "wav" }

    var supportsSpeedControl: Bool { true }
    /// Per-chunk generation is used; a true streamed-PCM path is the remaining Phase 4 item.
    var useStreamingMode: Bool {
        get { false }
        set { /* reserved for the streaming endpoint */ }
    }

    private let settings: VoxCPMSettings
    private let manager: VoxCPMEngineManager
    private let segmenter = SentenceSegmentationService()
    private let playbackController = TTSAudioPlaybackController()
    private lazy var chunkPlayer = TTSChunkPlayer(controller: playbackController)
    private lazy var queue: VoxCPMPlaybackQueue = VoxCPMPlaybackQueue(player: chunkPlayer) { [weak self] chunk in
        guard let self else { throw CancellationError() }
        return try await self.synthesizeChunk(chunk)
    }

    init(settings: VoxCPMSettings = .shared, manager: VoxCPMEngineManager = .shared) {
        self.settings = settings
        self.manager = manager
        super.init()
        queue.onStarted = { [weak self] in
            guard let self else { return }
            self.delegate?.ttsDidStartSpeaking(self)
        }
        queue.onFinished = { [weak self] success in
            guard let self else { return }
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        queue.onError = { [weak self] error in
            guard let self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    private var client: VoxCPMClient {
        VoxCPMClient(baseURL: settings.baseURL, tokenProvider: { [settings] in settings.readSessionToken() })
    }

    // MARK: - Chunking & routing

    private func buildChunks(from text: String) -> [VoxCPMPlaybackQueue.Chunk] {
        let router = VoxCPMLanguageRouter(
            languageMode: settings.languageMode,
            defaultFrenchVoice: settings.defaultFrenchVoice,
            defaultEnglishVoice: settings.defaultEnglishVoice,
            fallbackVoice: selectedVoice.isEmpty ? "default" : selectedVoice
        )
        return segmenter.segment(text).map { piece in
            let route = router.route(for: piece)  // per-sentence detection in Automatic mode
            return VoxCPMPlaybackQueue.Chunk(text: piece, voice: route.voice, language: route.language)
        }
    }

    private func synthesizeChunk(_ chunk: VoxCPMPlaybackQueue.Chunk) async throws -> Data {
        let options = VoxCPMGenerationOptions(
            voice: chunk.voice, language: chunk.language, quality: settings.quality,
            speed: selectedSpeed, seed: nil
        )
        return try await client.synthesize(text: chunk.text, model: selectedModel, options: options)
    }

    // MARK: - TTSService

    func speak(text: String) async throws {
        guard !text.isEmpty else { throw TTSError.noTextProvided }
        stop()

        let chunks = buildChunks(from: text)
        guard let first = chunks.first else { return }

        // Pre-flight the first chunk: validates connectivity (so we can fall back on failure) and seeds
        // the queue so it isn't regenerated. This throw is what triggers macOS-Native fallback.
        let firstAudio = try await synthesizeChunk(first)
        lastAudioData = chunks.count == 1 ? firstAudio : nil  // Save Audio only for single-chunk (for now)

        queue.start(chunks, rate: Float(selectedSpeed), preloaded: [0: firstAudio])
    }

    func pause() { queue.pause() }
    func resume() { queue.resume() }
    func stop() { queue.stop() }
    func setPlaybackRate(_ rate: Float) { queue.setRate(rate) }

    /// Skip to the next sentence / go back one sentence (Phase 4 queue controls).
    func skipToNextSentence() { queue.skip() }
    func goToPreviousSentence() { queue.previous() }

    func clearAudioCache() { lastAudioData = nil }

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
