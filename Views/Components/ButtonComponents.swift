import SwiftUI

// Shared button components for the TTS panel. These previously lived in the transcription panel,
// which was removed when ScreenVoice became text-to-speech only.

/// Button label with icon and keyboard shortcut text
struct ButtonLabelWithShortcut: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let shortcut: String
    var icon: String? = nil
    var isProminent: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.body)
            }
            Text(title)
                .font(.body)
            if !shortcut.isEmpty {
                Text(shortcut)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}

/// Custom prominent button style for primary panel actions (Speak / Record / Stop / Resume).
///
/// macOS's built-in `.borderedProminent` style dims its accent-colored background
/// heavily when the containing window is not the key window. SpeechDock's floating
/// panels frequently lose key status (Cmd+Tab to another app while speaking,
/// click-through overlays, etc.), making the main CTA nearly invisible. This
/// style uses an explicit `Color.accentColor` fill that is independent of
/// `controlActiveState`, keeping the button readable in all window states.
struct ProminentActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        isPressed ? Color.accentColor.opacity(0.85) : Color.accentColor
    }
}

extension View {
    /// Apply a custom keyboard shortcut to a view
    @ViewBuilder
    func applyCustomShortcut(_ shortcut: CustomShortcut) -> some View {
        if let keyEquiv = shortcut.keyEquivalent {
            self.keyboardShortcut(keyEquiv, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
