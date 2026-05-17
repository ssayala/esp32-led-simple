import UIKit

/// Thin wrapper around UIKit's feedback generators. Each call is
/// fire-and-forget; we don't bother with `.prepare()` because our
/// triggers fire at user-paced moments (button taps, async write
/// completions) where the prepare-warmup window doesn't help.
///
/// Use the semantic methods (`success`, `warning`, `error`, `tap`)
/// rather than instantiating generators inline so the rest of the
/// app stays UIKit-free.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Light tap for non-consequential confirmation (e.g. tapping a
    /// chip, switching mode). Skip for navigation taps — iOS's own
    /// tab-bar haptics already cover those.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
