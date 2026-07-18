import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) var appState
    @State private var engine = VoxCPMEngineManager.shared

    private var engineStatusColor: Color {
        switch engine.state {
        case .ready, .generating: return .green
        case .starting, .loadingModel: return .orange
        case .crashed, .unavailable: return .red
        case .notRunning, .unknown: return .secondary
        }
    }

    private var engineStatusText: String {
        switch engine.state {
        case .ready, .generating: return NSLocalizedString("ScreenVoice engine ready", comment: "Menu bar engine status")
        case .starting, .loadingModel: return NSLocalizedString("Starting engine…", comment: "Menu bar engine status")
        case .crashed, .unavailable: return NSLocalizedString("Engine unavailable — using macOS voice", comment: "Menu bar engine status")
        case .notRunning, .unknown: return NSLocalizedString("Engine not running — using macOS voice", comment: "Menu bar engine status")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // App title and status
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)

                Text("Screen Voice")
                    .font(.headline)

                Spacer()

                // Status indicator (text-to-speech only)
                if appState.ttsState == .speaking {
                    Text("Speaking")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .cornerRadius(4)
                } else if appState.ttsState == .loading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Divider()
                .padding(.vertical, 4)

            // MARK: - Engine status (ScreenVoice local engine)
            if appState.selectedTTSProvider == .voxCPM {
                HStack(spacing: 7) {
                    Circle()
                        .fill(engineStatusColor)
                        .frame(width: 7, height: 7)
                    Text(engineStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .task { await engine.refreshHealth() }
            }

            // Accessibility permission warning
            if !appState.hasAccessibilityPermission {
                permissionWarning(
                    icon: "hand.raised.slash",
                    text: "Accessibility access required",
                    action: openAccessibilitySettings
                )
            }

            // Screen Recording permission warning
            if !appState.hasScreenRecordingPermission {
                permissionWarning(
                    icon: "rectangle.dashed.badge.record",
                    text: "Screen Recording access recommended",
                    action: openScreenRecordingSettings
                )
            }

            // TTS Action button with shortcut
            Button(action: {
                // Capture frontmost app BEFORE closing the panel to ensure
                // we know which browser/app to copy the selected text from
                let capturedFrontmost = NSWorkspace.shared.frontmostApplication
                StatusBarManager.shared.closePanel()
                appState.startTTS(frontmostApp: capturedFrontmost)
            }) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .foregroundColor(appState.hasAccessibilityPermission ? .accentColor : .secondary)
                        .frame(width: 20)
                    Text("Read Selected Text")
                        .font(.callout)
                        .foregroundColor(appState.hasAccessibilityPermission ? .primary : .secondary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ttsKeyCombo.displayString ?? "\u{2303}\u{2325}T")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.ttsState == .speaking || appState.ttsState == .loading || !appState.hasAccessibilityPermission)

            // Open an empty TTS panel to type or paste text (no selection needed)
            Button(action: {
                StatusBarManager.shared.closePanel()
                appState.showTTSPanel()
            }) {
                HStack {
                    Image(systemName: "text.bubble")
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    Text("Open TTS Panel")
                        .font(.callout)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())

            // OCR to TTS Action button with shortcut
            Button(action: {
                StatusBarManager.shared.closePanel()
                appState.startOCR()
            }) {
                let ocrEnabled = appState.hasScreenRecordingPermission
                HStack {
                    Image(systemName: "text.viewfinder")
                        .foregroundColor(ocrEnabled ? .accentColor : .secondary)
                        .frame(width: 20)
                    Text("Read Screen Region")
                        .font(.callout)
                        .foregroundColor(ocrEnabled ? .primary : .secondary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ocrKeyCombo.displayString ?? "\u{2303}\u{2325}\u{21E7}O")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.ocrCoordinator.isSelecting || appState.ocrCoordinator.isProcessing || !appState.hasScreenRecordingPermission)

            Divider()
                .padding(.vertical, 4)

            // MARK: - Footer Actions
            VStack(spacing: 2) {
                // Settings
                Button(action: {
                    openSettings()
                }) {
                    HStack {
                        Image(systemName: "gear")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text("Settings...")
                            .font(.callout)
                        Spacer()
                        shortcutBadge("\u{2318},")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())

                // Check for Updates
                CheckForUpdatesView()
                    .buttonStyle(MenuBarActionButtonStyle())

                // Help
                Button(action: {
                    openHelp()
                }) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text("Help & Documentation")
                            .font(.callout)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())

                Divider()
                    .padding(.vertical, 4)

                // Quit
                Button(action: {
                    (NSApplication.shared.delegate as? AppDelegate)?.isExplicitQuit = true
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "power")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text("Quit SpeechDock")
                            .font(.callout)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())
            }
        }
        .padding(6)
        .frame(width: 280)
        .onAppear {
            appState.updatePermissionStatus()
        }
    }

    // Shortcut badge view
    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
    }

    // Permission warning view
    private func permissionWarning(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func openMicrophoneSettings() {
        StatusBarManager.shared.closePopover()
        PermissionService.shared.openMicrophoneSettings()
    }

    private func openAccessibilitySettings() {
        StatusBarManager.shared.closePopover()
        PermissionService.shared.openAccessibilitySettings()
    }

    private func openScreenRecordingSettings() {
        StatusBarManager.shared.closePopover()
        PermissionService.shared.openScreenRecordingSettings()
    }

    private func openAbout() {
        StatusBarManager.shared.closePopover()
        WindowManager.shared.openSettingsWindow(selectedCategory: .about)
    }

    private func openHelp() {
        StatusBarManager.shared.closePopover()
        let isJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") == true
        let urlString = isJapanese
            ? "https://yohasebe.github.io/speechdock/index_ja.html"
            : "https://yohasebe.github.io/speechdock/"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSettings() {
        StatusBarManager.shared.closePopover()
        WindowManager.shared.openSettingsWindow()
    }
}

// MARK: - Menu Bar Action Button Style

/// Custom button style with hover effect for menu bar action buttons
struct MenuBarActionButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(0.25)
        } else if isHovering {
            return Color.accentColor.opacity(0.12)
        } else {
            return Color.clear
        }
    }
}

/// Transcription history submenu for menu bar
struct TranscriptionHistoryMenu: View {
    var appState: AppState
    @State private var entries: [TranscriptionHistoryEntry] = []

    var body: some View {
        Menu {
            if entries.isEmpty {
                Text(NSLocalizedString("No history", comment: "Empty transcription history"))
                    .foregroundColor(.secondary)
            } else {
                ForEach(entries) { entry in
                    Button(action: {
                        loadHistoryEntry(entry)
                    }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entry.formattedDate) [\(entry.provider)]")
                                .font(.caption2)
                            Text(entry.preview)
                        }
                    }
                }

                Divider()

                Button(action: {
                    TranscriptionHistoryService.shared.clearHistory()
                    entries = []
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(NSLocalizedString("Clear History", comment: "Clear transcription history button"))
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                Text(NSLocalizedString("Transcription History", comment: "Transcription history menu title"))
                    .font(.callout)
                Spacer()
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .tint(.accentColor)
        .onAppear {
            entries = TranscriptionHistoryService.shared.allEntries
        }
    }

    private func loadHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        StatusBarManager.shared.closePanel()
        appState.showSTTPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appState.currentTranscription = entry.text
            appState.transcriptionState = .result(entry.text)
        }
    }
}
