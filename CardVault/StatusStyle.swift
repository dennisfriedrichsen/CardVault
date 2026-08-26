import CardVaultCore
import SwiftUI

/// The one place a status tone becomes a colour.
///
/// Colour is the *last* channel a status uses here: every place that reads this
/// also renders the tone's symbol and states the status in words, so a user who
/// cannot distinguish these hues loses nothing. Keeping the mapping in a single
/// extension is what makes that reviewable.
extension StatusTone {
    var color: Color {
        switch self {
        case .neutral: .accentColor
        case .inProgress: .accentColor
        case .attention: .orange
        case .blocked: .red
        case .success: .green
        }
    }
}

extension View {
    /// Speaks a status the moment the app enters it. Without this a VoiceOver
    /// user gets no notice of "do not remove card yet", because nothing they are
    /// focused on has changed.
    func announcesStatus(_ presentation: StatusPresentation) -> some View {
        onChange(of: presentation.state) { _, _ in
            AccessibilityNotification.Announcement(presentation.announcement).post()
        }
    }
}
