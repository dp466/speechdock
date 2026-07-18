import SwiftUI

/// Categories for the unified settings sidebar.
///
/// ScreenVoice is text-to-speech only — the speech-to-text, subtitle, and translation categories were
/// removed so the interface stays focused on reading text aloud.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case textToSpeech
    case shortcuts
    case textReplacement
    case appearance
    case apiKeys
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textToSpeech: return NSLocalizedString("Voice", comment: "Settings category")
        case .shortcuts: return NSLocalizedString("Shortcuts", comment: "Settings category")
        case .textReplacement: return NSLocalizedString("Text Replacement", comment: "Settings category")
        case .appearance: return NSLocalizedString("Appearance", comment: "Settings category")
        case .apiKeys: return NSLocalizedString("API Keys", comment: "Settings category")
        case .about: return NSLocalizedString("About", comment: "Settings category")
        }
    }

    var icon: String {
        switch self {
        case .textToSpeech: return "speaker.wave.2.fill"
        case .shortcuts: return "keyboard"
        case .textReplacement: return "text.badge.plus"
        case .appearance: return "paintbrush"
        case .apiKeys: return "key"
        case .about: return "info.circle"
        }
    }

    var iconColor: Color {
        return .accentColor
    }
}

/// Observable navigation state for settings window
/// Allows WindowManager to navigate to a specific category when the window is already open
@Observable
@MainActor
final class SettingsNavigation {
    var selectedCategory: SettingsCategory? = .textToSpeech
}
