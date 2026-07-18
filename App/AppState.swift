import SwiftUI
import Combine
import AVFoundation
import ApplicationServices

#if compiler(>=6.1)
import Translation
#endif

enum TranscriptionState: Equatable {
    case idle
    case preparing  // Starting up audio capture and connection
    case recording
    case transcribingFile  // Transcribing an audio file
    case processing
    case result(String)
    case error(String)

    var statusText: String {
        switch self {
        case .idle: return ""
        case .preparing: return NSLocalizedString("Starting...", comment: "Transcription state")
        case .recording: return NSLocalizedString("Recording...", comment: "Transcription state")
        case .transcribingFile: return NSLocalizedString("Transcribing file...", comment: "Transcription state")
        case .processing: return NSLocalizedString("Processing...", comment: "Transcription state")
        case .result: return ""
        case .error(let msg): return String(format: NSLocalizedString("Error: %@", comment: "Transcription error with message"), msg)
        }
    }
}

/// Panel window style for STT/TTS panels
enum PanelStyle: String, CaseIterable {
    case floating = "floating"
    case standardWindow = "standardWindow"

    var displayName: String {
        switch self {
        case .floating: return NSLocalizedString("Floating", comment: "Panel style name")
        case .standardWindow: return NSLocalizedString("Standard Window", comment: "Panel style name")
        }
    }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: - App Initialization
    /// Flag indicating whether the app has completed initialization
    /// AppleScript commands should wait for this before executing
    var isInitialized = false

    // MARK: - Donation Reminder
    var firstLaunchDate: Date? {
        didSet {
            guard !isLoadingPreferences else { return }
            UserDefaults.standard.set(firstLaunchDate, forKey: "firstLaunchDate")
        }
    }
    var donationReminderCount: Int = 0 {
        didSet {
            guard !isLoadingPreferences else { return }
            UserDefaults.standard.set(donationReminderCount, forKey: "donationReminderCount")
        }
    }
    var donationDismissedPermanently: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            UserDefaults.standard.set(donationDismissedPermanently, forKey: "donationDismissedPermanently")
        }
    }
    var nextDonationReminderDate: Date? {
        didSet {
            guard !isLoadingPreferences else { return }
            UserDefaults.standard.set(nextDonationReminderDate, forKey: "nextDonationReminderDate")
        }
    }

    // MARK: - TTS State
    var ttsState: TTSState = .idle
    var ttsText = ""
    // ScreenVoice (local VoxCPM2) is the default engine. If it is unavailable at speak time the app
    // degrades to macOS Native automatically — see fallbackToMacOSNative.
    var selectedTTSProvider: TTSProvider = .voxCPM {
        didSet {
            guard !isLoadingPreferences else { return }
            // Reset voice and model to defaults for new provider
            let service = TTSFactory.makeService(for: selectedTTSProvider)

            // Set default voice
            if let defaultVoice = service.availableVoices().first(where: { $0.isDefault }) {
                selectedTTSVoice = defaultVoice.id
            } else if let firstVoice = service.availableVoices().first {
                selectedTTSVoice = firstVoice.id
            } else {
                selectedTTSVoice = ""
            }

            // Set default model
            if let defaultModel = service.availableModels().first(where: { $0.isDefault }) {
                selectedTTSModel = defaultModel.id
            } else if let firstModel = service.availableModels().first {
                selectedTTSModel = firstModel.id
            } else {
                selectedTTSModel = ""
            }

            // Clear audio cache when provider changes
            lastSynthesizedText = ""
            ttsService = nil

            savePreferences()
        }
    }
    var selectedTTSVoice: String = "" {  // Empty means auto-detect
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var selectedTTSModel: String = "" {  // Empty means use default
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var selectedTTSSpeed: Double = 1.0 {  // Speed multiplier (1.0 = normal)
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var showTTSWindow = false
    var lastSynthesizedText = ""  // Track last synthesized text for cache
    var isSavingAudio = false  // Loading state for audio save

    // MARK: - Language Settings
    var selectedTTSLanguage: String = "" {  // "" = Auto (only used by ElevenLabs)
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Audio Output Settings
    var selectedAudioOutputDeviceUID: String = "" {  // "" = System Default
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Auto-Start Settings
    /// Whether to automatically start speaking when TTS panel opens with text (default: false = wait for user action)
    var ttsAutoSpeak: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Panel window style (floating or standard window)
    var panelStyle: PanelStyle = .floating {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Panel Text Font Size

    /// Font size for the TTS panel text area (default: 13 = system font size)
    var panelTextFontSize: Double = 13.0 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    static let defaultPanelTextFontSize: Double = 13.0
    static let minPanelTextFontSize: Double = 10.0
    static let maxPanelTextFontSize: Double = 24.0
    static let panelTextFontSizeStep: Double = 1.0

    /// Increase panel text font size
    func increasePanelTextFontSize() {
        let newSize = min(panelTextFontSize + Self.panelTextFontSizeStep, Self.maxPanelTextFontSize)
        if newSize != panelTextFontSize {
            panelTextFontSize = newSize
        }
    }

    /// Decrease panel text font size
    func decreasePanelTextFontSize() {
        let newSize = max(panelTextFontSize - Self.panelTextFontSizeStep, Self.minPanelTextFontSize)
        if newSize != panelTextFontSize {
            panelTextFontSize = newSize
        }
    }

    /// Reset panel text font size to default
    func resetPanelTextFontSize() {
        if panelTextFontSize != Self.defaultPanelTextFontSize {
            panelTextFontSize = Self.defaultPanelTextFontSize
        }
    }

    /// Shortcut HUD overlay (text-to-speech actions only)
    func toggleShortcutHUD() {
        let actions: [String: () -> Void] = [
            "toggleTTS": { [weak self] in self?.toggleTTS() },
            "ocr": { [weak self] in self?.startOCR() },
        ]
        ShortcutHUDManager.shared.toggle(
            hotKeyService: hotKeyService,
            shortcutManager: ShortcutSettingsManager.shared,
            globalActions: actions
        )
    }

    // MARK: - Permission Status (delegated to PermissionService)

    var hasMicrophonePermission: Bool {
        PermissionService.shared.microphoneGranted
    }

    var hasAccessibilityPermission: Bool {
        PermissionService.shared.accessibilityGranted
    }

    var hasScreenRecordingPermission: Bool {
        PermissionService.shared.screenRecordingGranted
    }

    /// Update permission status — refreshes PermissionService state
    func updatePermissionStatus() {
        PermissionService.shared.refreshAllPermissions()
    }

    // MARK: - Common State
    var isProcessing = false
    var errorMessage: String?
    var showFloatingWindow = false
    var showFloatingMicButton = false

    let apiKeyManager = APIKeyManager.shared
    let floatingWindowManager = FloatingWindowManager()

    // MARK: - OCR
    let ocrCoordinator = OCRCoordinator()

    // Expose hotKeyService for settings UI
    private(set) var hotKeyService: HotKeyService?
    private var isLoadingPreferences = false  // Flag to prevent saving during load
    private var savePreferencesWorkItem: DispatchWorkItem?  // Debounce coalescing for savePreferences
    private var ttsService: TTSService?

    private init() {
        loadPreferences()
        // Record first launch date if not already set
        if firstLaunchDate == nil {
            firstLaunchDate = Date()
        }
        refreshVoiceCachesInBackground()
        updatePermissionStatus()
        setupOCRCallbacks()
    }

    private func setupOCRCallbacks() {
        ocrCoordinator.onTextRecognized = { [weak self] text in
            guard let self = self else { return }
            // Show recognized text in TTS panel without auto-speaking
            // OCR results often need correction, so we always wait for user action
            self.showTTSPanelWithText(text)
        }

        ocrCoordinator.onError = { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                dprint("OCR Error: \(error.localizedDescription)")

                self.errorMessage = error.localizedDescription
            }
            // nil error indicates cancellation - no action needed
        }
    }

    /// Refresh voice caches in background (non-blocking)
    private func refreshVoiceCachesInBackground() {
        // Check cache status on main actor first
        let shouldRefreshElevenLabs = TTSVoiceCache.shared.isCacheExpired(for: .elevenLabs)

        Task.detached(priority: .background) {
            // Refresh ElevenLabs voices if cache is expired or empty
            if shouldRefreshElevenLabs {
                await ElevenLabsTTS.fetchAndCacheVoices()
            }
        }
    }

    func setupHotKey(_ service: HotKeyService) {
        hotKeyService = service
        service.delegate = self
        service.registerAllHotKeys()
    }

    // MARK: - TTS Methods

    func toggleTTS(frontmostApp: NSRunningApplication? = nil, precopiedText: String? = nil) {
        if ttsState == .speaking || ttsState == .paused {
            stopTTS()
        } else {
            startTTS(frontmostApp: frontmostApp, precopiedText: precopiedText)
        }
    }

    func startTTS(frontmostApp: NSRunningApplication? = nil, precopiedText: String? = nil) {
        dprint("TTS: startTTS called, frontmostApp: \(frontmostApp?.localizedName ?? "nil"), precopiedText: \(precopiedText != nil)")


        // Stop any existing TTS before starting a new session
        stopTTSPlayback()

        // Show the panel immediately for snappy perceived open latency, even when
        // selected text retrieval takes 200-800ms (e.g. for browsers). For hotkey-
        // triggered TTS, `precopiedText` is already populated synchronously by
        // `ttsHotKeyPressed`, so the panel appears with the text right away. For
        // menu-bar TTS, the panel appears empty first and is populated when the
        // async text fetch completes below.
        let initialText = precopiedText ?? ""
        ttsText = initialText
        ttsState = .idle
        if !showTTSWindow || !floatingWindowManager.isVisible {
            showTTSFloatingWindow()
        } else {
            floatingWindowManager.bringToFront()
        }

        // If text was already supplied by the caller, trigger auto-speak and skip
        // the async retrieval — there is no further text to load.
        if !initialText.isEmpty {
            dprint("TTS: Using precopied text, length: \(initialText.count)")
            if ttsAutoSpeak {
                speakCurrentText()
            }
            return
        }

        // Otherwise retrieve selected text from the frontmost app in the background
        // and populate the panel when it arrives. The user can also start typing
        // in the meantime; if they do, we won't overwrite their input.
        //
        // Thread-safety note: `AppState` is `@MainActor`, so this `Task` inherits
        // MainActor isolation. The `ttsText.isEmpty` check and the subsequent
        // `ttsText = fetched` assignment run as a single atomic unit of work on
        // the main actor — any user typing that modifies `ttsText` is serialized
        // with this block, so there is no read-modify-write race in practice.
        Task {
            guard let fetched = await TextSelectionService.shared.getSelectedText(from: frontmostApp),
                  !fetched.isEmpty else {
                dprint("TTS: No selected text retrieved; panel ready for manual input")
                return
            }
            dprint("TTS: Got selected text, length: \(fetched.count), content: '\(fetched.prefix(200))'")

            // Only populate if the panel text is still empty (user hasn't typed)
            guard ttsText.isEmpty else {
                dprint("TTS: Panel already has user-entered text; skipping auto-populate")
                return
            }
            ttsText = fetched
            if ttsAutoSpeak {
                speakCurrentText()
            }
        }
    }

    /// Show TTS panel with text, respecting auto-speak setting
    func startTTSWithText(_ text: String) {
        guard !text.isEmpty else { return }

        // Show panel with text
        showTTSPanelWithText(text)

        // Auto-speak if setting is enabled
        if ttsAutoSpeak {
            speakCurrentText()
        }
    }

    /// Show TTS panel with text without speaking (user can click Speak button)
    func showTTSPanelWithText(_ text: String) {
        guard !text.isEmpty else { return }
        dprint("TTS: showTTSPanelWithText, text length: \(text.count)")


        // Stop any existing TTS
        stopTTSPlayback()

        ttsText = text
        ttsState = .idle

        // Always ensure window is shown and brought to front
        if !showTTSWindow || !floatingWindowManager.isVisible {
            showTTSFloatingWindow()
        } else {
            floatingWindowManager.bringToFront()
        }
    }

    /// Speak the current ttsText (can be called from panel button)
    func speakCurrentText() {
        guard !ttsText.isEmpty else { return }
        dprint("TTS: speakCurrentText, text length: \(ttsText.count), provider: \(selectedTTSProvider.rawValue)")


        ttsState = .loading

        // Apply text replacement rules before speaking
        let processedText = TextReplacementService.shared.applyReplacements(to: ttsText)

        // Start TTS playback
        ttsService = TTSFactory.makeService(for: selectedTTSProvider)
        ttsService?.delegate = self
        ttsService?.selectedVoice = selectedTTSVoice
        if !selectedTTSModel.isEmpty {
            ttsService?.selectedModel = selectedTTSModel
        }
        ttsService?.selectedSpeed = selectedTTSSpeed
        if !selectedTTSLanguage.isEmpty {
            ttsService?.selectedLanguage = selectedTTSLanguage
        }
        ttsService?.audioOutputDeviceUID = selectedAudioOutputDeviceUID

        // Store the text being spoken
        lastSynthesizedText = ttsText

        Task {
            do {
                // speak() will call delegate.ttsDidStartSpeaking() when playback starts
                // and delegate.tts(didFinishSpeaking:) when it completes
                try await ttsService?.speak(text: processedText)
            } catch {
                dprint("TTS: Error occurred: \(error)")

                // If the local VoxCPM engine is unavailable, degrade cleanly to macOS Native TTS —
                // never silently to a cloud provider. Preserves the text currently being read.
                if selectedTTSProvider == .voxCPM, VoxCPMTTS.shouldFallBackToNative(for: error) {
                    await fallbackToMacOSNative(text: processedText, reason: error.localizedDescription)
                } else {
                    ttsState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Fall back to macOS Native TTS when the VoxCPM local engine can't serve the request.
    private func fallbackToMacOSNative(text: String, reason: String) async {
        dprint("TTS: VoxCPM unavailable (\(reason)); falling back to macOS Native")
        let native = MacOSTTS()
        native.delegate = self
        native.selectedSpeed = selectedTTSSpeed
        native.audioOutputDeviceUID = selectedAudioOutputDeviceUID
        ttsService = native
        do {
            try await native.speak(text: text)
        } catch {
            ttsState = .error(error.localizedDescription)
        }
    }

    func pauseResumeTTS() {
        guard let service = ttsService else { return }
        if service.isPaused {
            service.resume()
            ttsState = .speaking
        } else if service.isSpeaking {
            service.pause()
            ttsState = .paused
        }
    }

    /// Set TTS playback rate dynamically during playback (0.25 to 4.0)
    func setTTSPlaybackRate(_ rate: Float) {
        ttsService?.setPlaybackRate(rate)
    }

    /// Skip to the next sentence (VoxCPM sentence queue; no-op for other providers).
    func skipTTSSentence() { (ttsService as? VoxCPMTTS)?.skipToNextSentence() }

    /// Go back one sentence (VoxCPM sentence queue; no-op for other providers).
    func previousTTSSentence() { (ttsService as? VoxCPMTTS)?.goToPreviousSentence() }

    /// Stop TTS playback without resetting UI state (used internally)
    private func stopTTSPlayback() {
        ttsService?.stop()
        ttsService?.clearAudioCache()
        ttsService = nil
    }

    func stopTTS() {
        stopTTSPlayback()
        ttsState = .idle
        lastSynthesizedText = ""  // Clear cache reference

        // Ensure window state flag is in sync (in case stopTTS is called directly)
        if showTTSWindow && !floatingWindowManager.isVisible {
            showTTSWindow = false
        }
    }

    /// Check if TTS audio save is available (text >= 5 chars)
    func canSaveTTSAudio(for text: String) -> Bool {
        text.count >= 5
    }

    /// Get the file extension for TTS audio
    var ttsAudioFileExtension: String {
        ttsService?.audioFileExtension ?? "mp3"
    }

    /// Task for save audio operation (to allow cancellation)
    private var saveAudioTask: Task<Void, Never>?

    /// Synthesize and save TTS audio
    /// - Reuses existing audio data if text matches lastSynthesizedText and audio is complete
    /// - Otherwise synthesizes new audio using non-streaming mode before saving
    func synthesizeAndSaveTTSAudio(_ text: String) {
        guard text.count >= 5 else { return }

        // Check if we can reuse existing audio data (must be complete, not partial streaming data)
        if text == lastSynthesizedText,
           let audioData = ttsService?.lastAudioData,
           !audioData.isEmpty {
            // Reuse existing audio - show save panel directly (no loading state needed)
            showSavePanel(with: audioData, fileExtension: ttsAudioFileExtension)
            return
        }

        // Cancel any existing save task
        saveAudioTask?.cancel()

        // Need to synthesize new audio
        isSavingAudio = true

        // Create a new TTS service for synthesis (don't disturb current playback state)
        let saveService = TTSFactory.makeService(for: selectedTTSProvider)
        saveService.selectedVoice = selectedTTSVoice
        if !selectedTTSModel.isEmpty {
            saveService.selectedModel = selectedTTSModel
        }
        saveService.selectedSpeed = selectedTTSSpeed
        if !selectedTTSLanguage.isEmpty {
            saveService.selectedLanguage = selectedTTSLanguage
        }

        // IMPORTANT: Use non-streaming mode for save operations
        // This ensures audio is fully generated before playback starts,
        // allowing us to stop playback and get complete audio data
        saveService.useStreamingMode = false

        // Capture file extension before Task (MainActor isolated)
        let fileExtension = saveService.audioFileExtension

        saveAudioTask = Task { @MainActor in
            defer {
                // Clean up
                saveService.stop()
                saveService.clearAudioCache()
            }

            do {
                // Apply text replacement rules before synthesis
                let processedText = TextReplacementService.shared.applyReplacements(to: text)

                // Synthesize audio (this will start playback, but we'll stop it immediately)
                try await saveService.speak(text: processedText)

                // Check if cancelled
                if Task.isCancelled {
                    self.isSavingAudio = false
                    return
                }

                // Stop playback immediately - we only want the audio data, not playback
                saveService.stop()

                // Check if TTS window is still open before showing save panel
                guard self.showTTSWindow else {
                    self.isSavingAudio = false
                    return
                }

                // Get the audio data
                if let audioData = saveService.lastAudioData, !audioData.isEmpty {
                    // Update cache for potential reuse
                    self.lastSynthesizedText = text
                    self.isSavingAudio = false
                    self.showSavePanel(with: audioData, fileExtension: fileExtension)
                } else {
                    self.isSavingAudio = false
                    self.ttsState = .error("Failed to generate audio")
                }
            } catch {
                if !Task.isCancelled {
                    self.isSavingAudio = false
                    self.ttsState = .error(error.localizedDescription)
                } else {
                    self.isSavingAudio = false
                }
            }
        }
    }

    /// Cancel any ongoing save audio operation
    func cancelSaveAudio() {
        saveAudioTask?.cancel()
        saveAudioTask = nil
        isSavingAudio = false
    }

    /// Show save panel with the given audio data
    private func showSavePanel(with audioData: Data, fileExtension: String) {
        // Dispatch to next run loop to avoid any blocking issues
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.audio]
            savePanel.nameFieldStringValue = "tts_audio.\(fileExtension)"
            savePanel.title = NSLocalizedString("Save Audio", comment: "Save panel title")
            savePanel.message = NSLocalizedString("Choose a location to save the audio file", comment: "Save panel message")

            // Configure save panel to appear above all floating panels
            WindowLevelCoordinator.configureSavePanel(savePanel)

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    do {
                        try audioData.write(to: url)
                        dprint("Audio saved to: \(url.path)")

                    } catch {
                        dprint("Failed to save audio: \(error)")

                    }
                }
            }
        }
    }

    /// Show TTS panel without text (for manual input)
    /// Public for AppleScript access
    func showTTSPanel() {
        ttsText = ""
        ttsState = .idle
        showTTSFloatingWindow()
    }

    private func showTTSFloatingWindow() {
        floatingWindowManager.showTTSFloatingWindow(
            appState: self,
            onClose: { [weak self] in
                self?.closeTTSWindow()
            }
        )
        showTTSWindow = true
    }

    private func closeTTSWindow() {
        // Cancel any ongoing save operation
        cancelSaveAudio()
        stopTTS()
        floatingWindowManager.hideFloatingWindow()
        showTTSWindow = false
        ttsText = ""
    }

    // MARK: - OCR Methods

    /// Start OCR region selection
    func startOCR() {
        // Close the TTS panel first
        if showTTSWindow || ttsState == .speaking || ttsState == .paused || ttsState == .loading {
            closeTTSWindow()
        }

        // Start OCR selection
        ocrCoordinator.startSelection()
    }

    /// Cancel OCR operation
    func cancelOCR() {
        ocrCoordinator.cancel()
    }

    // MARK: - Preferences

    private func loadPreferences() {
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }

        if let providerRaw = UserDefaults.standard.string(forKey: "selectedTTSProvider"),
           let provider = TTSProvider(rawValue: providerRaw) {
            selectedTTSProvider = provider
        }
        if let voice = UserDefaults.standard.string(forKey: "selectedTTSVoice") {
            selectedTTSVoice = voice
        }
        if let model = UserDefaults.standard.string(forKey: "selectedTTSModel") {
            selectedTTSModel = model
        }
        if UserDefaults.standard.object(forKey: "selectedTTSSpeed") != nil {
            selectedTTSSpeed = UserDefaults.standard.double(forKey: "selectedTTSSpeed")
        }
        if let ttsLanguage = UserDefaults.standard.string(forKey: "selectedTTSLanguage") {
            selectedTTSLanguage = ttsLanguage
        }
        if let outputUID = UserDefaults.standard.string(forKey: "selectedAudioOutputDeviceUID") {
            selectedAudioOutputDeviceUID = outputUID
        }
        if UserDefaults.standard.object(forKey: "panelTextFontSize") != nil {
            let size = UserDefaults.standard.double(forKey: "panelTextFontSize")
            panelTextFontSize = min(max(size, Self.minPanelTextFontSize), Self.maxPanelTextFontSize)
        }
        if UserDefaults.standard.object(forKey: "ttsAutoSpeak") != nil {
            ttsAutoSpeak = UserDefaults.standard.bool(forKey: "ttsAutoSpeak")
        }
        if let styleRaw = UserDefaults.standard.string(forKey: "panelStyle"),
           let style = PanelStyle(rawValue: styleRaw) {
            panelStyle = style
        }

        // Donation reminder state
        firstLaunchDate = UserDefaults.standard.object(forKey: "firstLaunchDate") as? Date
        donationReminderCount = UserDefaults.standard.integer(forKey: "donationReminderCount")
        donationDismissedPermanently = UserDefaults.standard.bool(forKey: "donationDismissedPermanently")
        nextDonationReminderDate = UserDefaults.standard.object(forKey: "nextDonationReminderDate") as? Date

        validateSelectedProviders()
    }

    /// Validate that the selected provider is usable (has an API key if it requires one).
    /// ScreenVoice (local) and macOS Native never require a key.
    private func validateSelectedProviders() {
        if selectedTTSProvider.requiresAPIKey && !hasAPIKeyForTTS(selectedTTSProvider) {
            selectedTTSProvider = .voxCPM
        }
    }


    private func hasAPIKeyForTTS(_ provider: TTSProvider) -> Bool {
        switch provider {
        case .openAI:
            return apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .grok:
            return apiKeyManager.hasAPIKey(for: .grok)
        case .macOS, .voxCPM:
            return true
        }
    }

    private func savePreferences() {
        // Debounce: coalesce rapid didSet calls into a single UserDefaults write
        savePreferencesWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.savePreferencesNow()
        }
        savePreferencesWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func savePreferencesNow() {
        UserDefaults.standard.set(selectedTTSProvider.rawValue, forKey: "selectedTTSProvider")
        UserDefaults.standard.set(selectedTTSVoice, forKey: "selectedTTSVoice")
        UserDefaults.standard.set(selectedTTSModel, forKey: "selectedTTSModel")
        UserDefaults.standard.set(selectedTTSSpeed, forKey: "selectedTTSSpeed")
        UserDefaults.standard.set(selectedTTSLanguage, forKey: "selectedTTSLanguage")
        UserDefaults.standard.set(selectedAudioOutputDeviceUID, forKey: "selectedAudioOutputDeviceUID")
        UserDefaults.standard.set(panelTextFontSize, forKey: "panelTextFontSize")
        UserDefaults.standard.set(ttsAutoSpeak, forKey: "ttsAutoSpeak")
        UserDefaults.standard.set(panelStyle.rawValue, forKey: "panelStyle")
    }

    // MARK: - Donation Reminder

    /// Check if the donation reminder should be shown
    func shouldShowDonationReminder() -> Bool {
        // Already dismissed permanently
        guard !donationDismissedPermanently else { return false }

        guard let firstLaunch = firstLaunchDate else { return false }

        let now = Date()

        if let nextDate = nextDonationReminderDate {
            // Subsequent reminders: after nextDonationReminderDate
            return now >= nextDate
        } else {
            // First reminder: 30 days after first launch
            let daysSinceFirstLaunch = Calendar.current.dateComponents([.day], from: firstLaunch, to: now).day ?? 0
            return daysSinceFirstLaunch >= 30
        }
    }

    /// Show the donation reminder dialog
    func showDonationReminder() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Thank you for using SpeechDock", comment: "Donation reminder title")
        alert.informativeText = NSLocalizedString("This app is free and open source. Development and maintenance costs (Apple Developer Program, etc.) are covered by the developer. If SpeechDock has been helpful to you, please consider supporting its continued development.", comment: "Donation reminder message")
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage

        // Buttons are added in order: first = rightmost (default)
        alert.addButton(withTitle: NSLocalizedString("Support", comment: "Donation reminder button"))
        alert.addButton(withTitle: NSLocalizedString("Already Supported", comment: "Donation reminder button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Donation reminder button"))

        alert.window.level = .floating + 1

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Support → Open GitHub Sponsors
            if let url = URL(string: "https://github.com/sponsors/yohasebe") {
                NSWorkspace.shared.open(url)
            }
            donationDismissedPermanently = true
        case .alertSecondButtonReturn:
            // Already Supported → Never show again
            donationDismissedPermanently = true
        case .alertThirdButtonReturn:
            // Later → Show again in 30 days
            donationReminderCount += 1
            nextDonationReminderDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())
        default:
            break
        }
    }
}

// MARK: - HotKeyServiceDelegate

extension AppState: HotKeyServiceDelegate {

    nonisolated func ttsHotKeyPressed() {
        // Capture frontmost app IMMEDIATELY before any async scheduling
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        // Skip if SpeechDock itself is frontmost (no text to copy from ourselves)
        let isSpeechDockFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        dprint("TTS HotKey: Captured frontmost app: \(frontmostApp?.localizedName ?? "none") (bundle: \(frontmostApp?.bundleIdentifier ?? "none")), isSpeechDock: \(isSpeechDockFrontmost)")


        var copiedText: String? = nil

        if !isSpeechDockFrontmost, let targetApp = frontmostApp {
            // Save original clipboard content before overwriting
            let savedClipboardState = ClipboardService.shared.saveClipboardState()

            // Ensure target app is activated and has keyboard focus
            targetApp.activate()
            Thread.sleep(forTimeInterval: 0.05)  // 50ms for activation

            // Send Cmd+C while target app is frontmost
            let clipboardChangeCount = NSPasteboard.general.changeCount
            sendCopyCommand()

            // Wait for copy to complete
            Thread.sleep(forTimeInterval: 0.15)  // 150ms for clipboard

            // Check if clipboard was updated
            let newChangeCount = NSPasteboard.general.changeCount
            if newChangeCount != clipboardChangeCount {
                // Read the best available text representation, preferring HTML/RTF
                // so that paragraph breaks are preserved (plain text collapses them)
                copiedText = TextSelectionService.shared.readBestTextFromPasteboard()
            }
            dprint("TTS HotKey: Clipboard changed: \(newChangeCount != clipboardChangeCount), text length: \(copiedText?.count ?? 0)")


            // Restore original clipboard content after capturing text
            if copiedText != nil {
                ClipboardService.shared.restoreClipboardState(savedClipboardState)
                dprint("TTS HotKey: Restored original clipboard content")

            }
        }

        Task { @MainActor in
            self.toggleTTS(frontmostApp: frontmostApp, precopiedText: copiedText)
        }
    }

    /// Send Cmd+C via CGEvent (called synchronously from hotkey handler)
    private nonisolated func sendCopyCommand() {
        let keyCodeC: CGKeyCode = 8
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        dprint("TTS HotKey: Sent Cmd+C immediately")

    }

    nonisolated func ocrHotKeyPressed() {
        Task { @MainActor in
            self.startOCR()
        }
    }


    nonisolated func shortcutHUDHotKeyPressed() {
        Task { @MainActor in
            self.toggleShortcutHUD()
        }
    }

}

// MARK: - TTSDelegate

extension AppState: TTSDelegate {
    func tts(_ service: TTSService, willSpeakRange range: NSRange, of text: String) {
        // Word highlighting removed - streaming mode doesn't provide timing info
    }

    func ttsDidStartSpeaking(_ service: TTSService) {
        ttsState = .speaking
    }

    func tts(_ service: TTSService, didFinishSpeaking successfully: Bool) {
        ttsState = .idle
    }

    func tts(_ service: TTSService, didFailWithError error: Error) {
        ttsState = .error(error.localizedDescription)
    }
}

