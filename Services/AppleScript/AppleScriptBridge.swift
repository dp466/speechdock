import AppKit
import os.log

private let logger = Logger(subsystem: "com.speechdock.app", category: "AppleScript")

// MARK: - Safe Main Thread Helpers

/// Executes a closure on the main thread and returns the result.
/// If already on the main thread, executes directly. Otherwise, dispatches synchronously.
private func onMainSync<T>(_ work: @escaping () -> T) -> T {
    if Thread.isMainThread {
        return work()
    } else {
        return DispatchQueue.main.sync { work() }
    }
}

/// Executes a closure on the main thread asynchronously for setters.
/// If already on the main thread, executes directly. Otherwise, dispatches asynchronously.
private func onMainAsync(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
        work()
    } else {
        DispatchQueue.main.async { work() }
    }
}

// MARK: - NSApplication KVC Properties for AppleScript

extension NSApplication {

    // MARK: TTS Provider

    @objc var scriptTTSProvider: String {
        get {
            onMainSync {
                AppState.shared.selectedTTSProvider.rawValue
            }
        }
        set {
            onMainAsync {
                guard let provider = TTSProvider(rawValue: newValue) else {
                    logger.warning("Invalid TTS provider name: \(newValue, privacy: .public). Valid values: \(TTSProvider.allCases.map { $0.rawValue }.joined(separator: ", "), privacy: .public)")
                    return
                }
                AppState.shared.selectedTTSProvider = provider
            }
        }
    }

    // MARK: TTS Voice

    @objc var scriptTTSVoice: String {
        get {
            onMainSync {
                AppState.shared.selectedTTSVoice
            }
        }
        set {
            onMainAsync {
                AppState.shared.selectedTTSVoice = newValue
            }
        }
    }

    // MARK: TTS Speed

    @objc var scriptTTSSpeed: Double {
        get {
            onMainSync {
                AppState.shared.selectedTTSSpeed
            }
        }
        set {
            onMainAsync {
                let clampedSpeed = min(max(newValue, 0.25), 4.0)
                AppState.shared.selectedTTSSpeed = clampedSpeed
            }
        }
    }



    // MARK: Read-only State

    @objc var scriptIsSpeaking: Bool {
        onMainSync {
            AppState.shared.ttsState == .speaking || AppState.shared.ttsState == .paused
        }
    }


}
