import Foundation

/// Abstraction over the audio player the queue drives, so the queue can be unit-tested with a fake.
@MainActor
protocol VoxCPMChunkPlaying: AnyObject {
    var isPaused: Bool { get }
    var isPlaying: Bool { get }
    func play(_ wav: Data, rate: Float)
    func pause()
    func resume()
    func stop()
    func setRate(_ rate: Float)
    var onStarted: (() -> Void)? { get set }
    var onFinished: ((Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
}

/// Sequential playback of synthesized chunks with **one-ahead concurrent generation**: while a chunk
/// plays, the next is already being generated so queued reading has no gaps once generation keeps pace.
/// Supports stop (immediate — clears pending audio and cancels outstanding generation), pause/resume,
/// skip, and previous. `onStarted` fires once at first audio; `onFinished` once at the end.
@MainActor
final class VoxCPMPlaybackQueue {
    struct Chunk: Equatable {
        let text: String
        let voice: String
        let language: VoxCPMLanguage
    }

    typealias Synthesizer = (Chunk) async throws -> Data

    var onStarted: (() -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// How many chunks ahead of the current one to pre-generate.
    var prefetchCount = 1

    private let player: VoxCPMChunkPlaying
    private let synthesize: Synthesizer
    private var rate: Float = 1.0

    private var chunks: [Chunk] = []
    private var cache: [Int: Data] = [:]
    private var tasks: [Int: Task<Data, Error>] = [:]
    private var index = 0
    private var isActive = false
    private var didStart = false

    init(player: VoxCPMChunkPlaying, synthesize: @escaping Synthesizer) {
        self.player = player
        self.synthesize = synthesize
        self.player.onStarted = { [weak self] in self?.handleChunkStarted() }
        self.player.onFinished = { [weak self] ok in self?.handleChunkFinished(ok) }
        self.player.onError = { [weak self] error in self?.handleError(error) }
    }

    var isPaused: Bool { player.isPaused }
    var isPlaying: Bool { isActive }
    var currentIndex: Int { index }
    var count: Int { chunks.count }

    // MARK: - Control

    /// Start playing `chunks`. `preloaded` seeds already-generated audio by index (e.g. a pre-flighted
    /// first chunk) so it is not regenerated.
    func start(_ chunks: [Chunk], rate: Float = 1.0, preloaded: [Int: Data] = [:]) {
        stop()
        guard !chunks.isEmpty else { onFinished?(true); return }
        self.chunks = chunks
        self.rate = rate
        self.cache = preloaded
        isActive = true
        didStart = false
        index = 0
        Task { await playCurrent() }
    }

    func stop() {
        isActive = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        cache.removeAll()
        chunks = []
        index = 0
        player.stop()
    }

    func pause() { player.pause() }
    func resume() { player.resume() }
    func setRate(_ rate: Float) { self.rate = rate; player.setRate(rate) }

    /// Jump to the next chunk (or finish if past the end).
    func skip() { jump(to: index + 1) }

    /// Jump to the previous chunk (clamped at the first).
    func previous() { jump(to: max(0, index - 1)) }

    private func jump(to newIndex: Int) {
        guard isActive else { return }
        player.stop() // does not fire onFinished
        guard chunks.indices.contains(newIndex) else { finish(success: true); return }
        index = newIndex
        Task { await playCurrent() }
    }

    // MARK: - Generation & playback

    private func playCurrent() async {
        guard isActive, chunks.indices.contains(index) else {
            if isActive { finish(success: true) }
            return
        }
        prefetch()
        do {
            let wav = try await audio(for: index)
            guard isActive else { return }
            player.play(wav, rate: rate)
            prefetch() // now that playback started, ensure the following chunk is generating
        } catch is CancellationError {
            // stop() was called — nothing to do.
        } catch {
            if isActive { handleError(error) }
        }
    }

    private func audio(for i: Int) async throws -> Data {
        if let cached = cache[i] { return cached }
        let data = try await generation(for: i).value
        cache[i] = data
        return data
    }

    @discardableResult
    private func generation(for i: Int) -> Task<Data, Error> {
        if let existing = tasks[i] { return existing }
        let chunk = chunks[i]
        let task = Task { try await synthesize(chunk) }
        tasks[i] = task
        return task
    }

    private func prefetch() {
        let last = min(index + prefetchCount, chunks.count - 1)
        guard last >= index else { return }
        for i in index...last where chunks.indices.contains(i) {
            generation(for: i)
        }
    }

    // MARK: - Player callbacks

    private func handleChunkStarted() {
        guard isActive else { return }
        if !didStart {
            didStart = true
            onStarted?()
        }
    }

    private func handleChunkFinished(_ success: Bool) {
        guard isActive else { return }
        guard success else { finish(success: false); return }
        index += 1
        if chunks.indices.contains(index) {
            Task { await playCurrent() }
        } else {
            finish(success: true)
        }
    }

    private func handleError(_ error: Error) {
        guard isActive else { return }
        isActive = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        onError?(error)
    }

    private func finish(success: Bool) {
        isActive = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        cache.removeAll()
        onFinished?(success)
    }
}

/// Real player: wraps the shared `TTSAudioPlaybackController` (AVAudio playback, output-device routing).
@MainActor
final class TTSChunkPlayer: VoxCPMChunkPlaying {
    private let controller: TTSAudioPlaybackController

    var onStarted: (() -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(controller: TTSAudioPlaybackController) {
        self.controller = controller
        controller.onPlaybackStarted = { [weak self] in self?.onStarted?() }
        controller.onFinishSpeaking = { [weak self] ok in self?.onFinished?(ok) }
        controller.onError = { [weak self] error in self?.onError?(error) }
    }

    var isPaused: Bool { controller.isPaused }
    var isPlaying: Bool { controller.isSpeaking }

    var outputDeviceUID: String {
        get { controller.outputDeviceUID }
        set { controller.outputDeviceUID = newValue }
    }

    func play(_ wav: Data, rate: Float) {
        controller.setPlaybackRate(rate)
        do {
            try controller.playAudio(data: wav, fileExtension: "wav")
        } catch {
            onError?(error)
        }
    }

    func pause() { controller.pause() }
    func resume() { controller.resume() }
    func stop() { controller.stopPlayback() }
    func setRate(_ rate: Float) { controller.setPlaybackRate(rate) }
}
