import XCTest
@testable import SpeechDock

/// Phase 4: playback queue — ordering, one-ahead prefetch, completion, stop, skip/previous, and
/// single onStarted. Driven with a fake player + fake synthesizer (no audio, no engine).
@MainActor
final class VoxCPMQueueTests: XCTestCase {

    private func chunk(_ t: String) -> VoxCPMPlaybackQueue.Chunk {
        VoxCPMPlaybackQueue.Chunk(text: t, voice: "default", language: .auto)
    }

    /// Let queued Tasks run.
    private func settle(_ times: Int = 40) async {
        for _ in 0..<times { await Task.yield() }
    }

    func testPlaysChunksInOrder() async {
        let player = FakeChunkPlayer()
        let rec = GenRecorder()
        let queue = VoxCPMPlaybackQueue(player: player) { c in rec.record(c.text); return Data(c.text.utf8) }
        var finished: Bool?
        queue.onFinished = { finished = $0 }

        queue.start([chunk("A"), chunk("B"), chunk("C")])
        await settle()
        XCTAssertEqual(player.played, [Data("A".utf8)])

        player.finishCurrent(); await settle()
        XCTAssertEqual(player.played.last, Data("B".utf8))

        player.finishCurrent(); await settle()
        XCTAssertEqual(player.played.last, Data("C".utf8))

        player.finishCurrent(); await settle()
        XCTAssertEqual(finished, true)
    }

    func testPrefetchesNextWhileCurrentPlays() async {
        let player = FakeChunkPlayer()
        let rec = GenRecorder()
        let queue = VoxCPMPlaybackQueue(player: player) { c in rec.record(c.text); return Data(c.text.utf8) }
        queue.start([chunk("A"), chunk("B")])
        await settle()
        // Before "A" finishes, "B" should already be generating (prefetch = 1).
        XCTAssertTrue(rec.texts.contains("B"))
    }

    func testOnStartedFiresOnce() async {
        let player = FakeChunkPlayer()
        let queue = VoxCPMPlaybackQueue(player: player) { c in Data(c.text.utf8) }
        var startedCount = 0
        queue.onStarted = { startedCount += 1 }
        queue.start([chunk("A"), chunk("B")])
        await settle()
        player.finishCurrent(); await settle()
        XCTAssertEqual(startedCount, 1)
    }

    func testStopHaltsQueue() async {
        let player = FakeChunkPlayer()
        let queue = VoxCPMPlaybackQueue(player: player) { c in Data(c.text.utf8) }
        var finished: Bool?
        queue.onFinished = { finished = $0 }
        queue.start([chunk("A"), chunk("B")])
        await settle()
        queue.stop()
        let playedAfterStop = player.played.count
        player.finishCurrent(); await settle()
        XCTAssertEqual(player.played.count, playedAfterStop) // no new playback
        XCTAssertNil(finished)                               // stop != natural finish
        XCTAssertFalse(queue.isPlaying)
    }

    func testSkipAdvances() async {
        let player = FakeChunkPlayer()
        let queue = VoxCPMPlaybackQueue(player: player) { c in Data(c.text.utf8) }
        queue.start([chunk("A"), chunk("B"), chunk("C")])
        await settle()
        queue.skip(); await settle()
        XCTAssertEqual(player.played.last, Data("B".utf8))
        XCTAssertEqual(queue.currentIndex, 1)
    }

    func testPreviousGoesBack() async {
        let player = FakeChunkPlayer()
        let queue = VoxCPMPlaybackQueue(player: player) { c in Data(c.text.utf8) }
        queue.start([chunk("A"), chunk("B"), chunk("C")])
        await settle()
        queue.skip(); await settle()
        queue.previous(); await settle()
        XCTAssertEqual(player.played.last, Data("A".utf8))
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testErrorSurfacesAndStops() async {
        struct Boom: Error {}
        let player = FakeChunkPlayer()
        let queue = VoxCPMPlaybackQueue(player: player) { _ in throw Boom() }
        var errored = false
        var finished: Bool?
        queue.onError = { _ in errored = true }
        queue.onFinished = { finished = $0 }
        queue.start([chunk("A")])
        await settle()
        XCTAssertTrue(errored)
        XCTAssertNil(finished)   // error path does not also report finished
        XCTAssertFalse(queue.isPlaying)
    }
}

// MARK: - Test doubles

@MainActor
final class FakeChunkPlayer: VoxCPMChunkPlaying {
    var isPaused = false
    var isPlaying = false
    var onStarted: (() -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var played: [Data] = []

    func play(_ wav: Data, rate: Float) {
        played.append(wav)
        isPlaying = true
        onStarted?()
    }
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func stop() { isPlaying = false }
    func setRate(_ rate: Float) {}

    /// Simulate the current clip finishing.
    func finishCurrent(success: Bool = true) {
        isPlaying = false
        onFinished?(success)
    }
}

/// Reference-type recorder so the @escaping synthesizer can note which chunks were generated.
final class GenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var texts: [String] = []
    func record(_ t: String) { lock.lock(); texts.append(t); lock.unlock() }
}
