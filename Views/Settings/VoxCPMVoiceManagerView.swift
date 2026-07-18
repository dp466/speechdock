import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Voice-profile management for the local engine: list, import (file or recording), preview, delete,
/// and choose default French/English voices. All reference audio stays on the Mac.
struct VoxCPMVoiceManagerView: View {
    @State private var manager = VoxCPMEngineManager.shared
    @State private var settings = VoxCPMSettings.shared
    @StateObject private var recorder = VoxCPMReferenceRecorder()
    @Environment(\.dismiss) private var dismiss

    // Import form
    @State private var newName = ""
    @State private var newLanguage: VoxCPMLanguage = .fr
    @State private var newKind = "clone"
    @State private var newTranscript = ""
    @State private var newControl = ""
    @State private var consent = false
    @State private var pickedAudio: Data?
    @State private var pickedFilename: String?
    @State private var showingFileImporter = false
    @State private var isBusy = false
    @State private var status: String?

    private var previewPlayer = PreviewPlayer()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Voices").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Form {
                existingVoicesSection
                importSection
                if let status {
                    Section { Text(status).font(.caption).foregroundColor(.secondary) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 560)
        .task { await manager.refreshVoices() }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.wav, .mp3, .mpeg4Audio, .audio],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Existing voices

    private var existingVoicesSection: some View {
        Section {
            ForEach(manager.cachedVoices) { voice in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.displayName)
                        HStack(spacing: 6) {
                            Text(voice.language).font(.caption2).foregroundColor(.secondary)
                            Text(voice.kind).font(.caption2).foregroundColor(.secondary)
                            if settings.defaultFrenchVoice == voice.id {
                                Text("FR default").font(.caption2).foregroundColor(.blue)
                            }
                            if settings.defaultEnglishVoice == voice.id {
                                Text("EN default").font(.caption2).foregroundColor(.blue)
                            }
                        }
                    }
                    Spacer()
                    Menu {
                        Button("Preview") { Task { await preview(voice.id) } }
                        Button("Set as French default") { settings.defaultFrenchVoice = voice.id }
                        Button("Set as English default") { settings.defaultEnglishVoice = voice.id }
                        if voice.id != "default" {
                            Divider()
                            Button("Delete", role: .destructive) { Task { await delete(voice.id) } }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        } header: {
            Text("Voices")
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            TextField("Name", text: $newName)
            Picker("Primary language", selection: $newLanguage) {
                ForEach(VoxCPMLanguage.allCases) { l in Text(l.displayName).tag(l) }
            }
            Picker("Type", selection: $newKind) {
                Text("Cloned from reference audio").tag("clone")
                Text("Designed from description").tag("design")
            }

            if newKind == "clone" {
                HStack {
                    Button {
                        showingFileImporter = true
                    } label: { Label("Choose Audio File…", systemImage: "folder") }
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        Label(recorder.isRecording ? "Stop Recording" : "Record",
                              systemImage: recorder.isRecording ? "stop.circle" : "mic")
                    }
                    .tint(recorder.isRecording ? .red : nil)
                }
                if let name = pickedFilename {
                    Text("Selected: \(name)").font(.caption2).foregroundColor(.secondary)
                }
                TextField("Reference transcript (optional)", text: $newTranscript, axis: .vertical)
                    .lineLimit(1...3)
            } else {
                TextField("Voice description (e.g. warm young woman)", text: $newControl, axis: .vertical)
                    .lineLimit(1...3)
            }

            Toggle(isOn: $consent) {
                Text("I confirm I have the right to use this reference audio.")
                    .font(.caption)
            }

            Button {
                Task { await importVoice() }
            } label: {
                if isBusy { ProgressView().scaleEffect(0.6) } else { Text("Add Voice") }
            }
            .disabled(!canImport || isBusy)
        } header: {
            Text("Add a Voice")
        } footer: {
            Text("Reference audio never leaves your Mac. Québec-French and Canadian-English voices are just profiles tagged fr-CA / en-CA.")
                .font(.caption2)
        }
    }

    private var canImport: Bool {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, consent else { return false }
        if newKind == "clone" { return pickedAudio != nil }
        return !newControl.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                pickedAudio = data
                pickedFilename = url.lastPathComponent
            } else {
                status = NSLocalizedString("Could not read the selected file.", comment: "VoxCPM import error")
            }
        case .failure(let error):
            status = error.localizedDescription
        }
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            recorder.stop()
            // Give the encoder a moment to finalize the file.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let data = recorder.consumeRecording() {
                pickedAudio = data
                pickedFilename = "recording.m4a"
            } else if let err = recorder.errorMessage {
                status = err
            }
        } else {
            await recorder.start()
        }
    }

    private func importVoice() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let profile = try await manager.importVoice(
                displayName: newName, language: newLanguage.rawValue, kind: newKind,
                audioData: newKind == "clone" ? pickedAudio : nil,
                filename: pickedFilename, transcript: newTranscript,
                control: newKind == "design" ? newControl : nil, notes: nil, consentConfirmed: consent)
            status = String(format: NSLocalizedString("Added \"%@\".", comment: "VoxCPM import ok"), profile.displayName)
            // Reset form
            newName = ""; newTranscript = ""; newControl = ""; consent = false
            pickedAudio = nil; pickedFilename = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        do {
            try await manager.deleteVoice(id: id)
            if settings.defaultFrenchVoice == id { settings.defaultFrenchVoice = "default" }
            if settings.defaultEnglishVoice == id { settings.defaultEnglishVoice = "default" }
            status = NSLocalizedString("Voice deleted.", comment: "VoxCPM delete ok")
        } catch {
            status = error.localizedDescription
        }
    }

    private func preview(_ voiceId: String) async {
        do {
            let sample = newLanguage == .fr
                ? "Bonjour, ceci est un aperçu de la voix."
                : "Hello, this is a preview of the voice."
            let wav = try await manager.previewVoice(voiceId, text: sample, quality: settings.quality)
            previewPlayer.play(wav)
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Tiny holder for preview playback so SwiftUI doesn't deallocate the player mid-clip.
final class PreviewPlayer {
    private var player: AVAudioPlayer?
    func play(_ data: Data) {
        player = try? AVAudioPlayer(data: data)
        player?.play()
    }
}
