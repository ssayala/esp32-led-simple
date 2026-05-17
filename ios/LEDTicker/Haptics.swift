import UIKit

/// Thin wrapper around UIKit's feedback generators. Generator instances
/// are cached as `static let` per Apple's recommendation — reusing the
/// same instance keeps the Taptic Engine warm and is cheaper than
/// allocating per call.
///
/// Use the semantic methods (`success`, `warning`, `error`, `tap`)
/// rather than instantiating generators inline so the rest of the
/// app stays UIKit-free.
enum Haptics {
    private static let notification = UINotificationFeedbackGenerator()
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)

    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func error()   { notification.notificationOccurred(.error) }

    /// Light tap for non-consequential confirmation (e.g. tapping a
    /// chip, switching mode). Skip for navigation taps — iOS's own
    /// tab-bar haptics already cover those.
    static func tap() { impactLight.impactOccurred() }
}
