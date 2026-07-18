import Foundation
import AVFoundation

/// Records a short reference clip (to a temporary `.m4a`) for voice cloning. Kept local; the file is
/// handed to the engine as base64 and can be discarded afterward.
@MainActor
final class VoxCPMReferenceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var errorMessage: String?

    private var recorder: AVAudioRecorder?

    /// Request microphone access (macOS prompts once, then remembers).
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async {
        errorMessage = nil
        guard await requestPermission() else {
            errorMessage = NSLocalizedString("Microphone access denied", comment: "VoxCPM recorder error")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxcpm_ref_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record() else {
                errorMessage = NSLocalizedString("Failed to start recording", comment: "VoxCPM recorder error")
                return
            }
            self.recorder = recorder
            lastRecordingURL = url
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
    }

    /// Read the recorded clip and clear it from disk.
    func consumeRecording() -> Data? {
        guard let url = lastRecordingURL else { return nil }
        defer {
            try? FileManager.default.removeItem(at: url)
            lastRecordingURL = nil
        }
        return try? Data(contentsOf: url)
    }
}

extension VoxCPMReferenceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.isRecording = false }
    }
}
