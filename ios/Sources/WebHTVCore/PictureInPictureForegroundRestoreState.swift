/// Ensures one foreground restore request is made for each active Picture in Picture session.
/// UIKit remains in the app target; this state-only gate exists so lifecycle decisions are testable.
public struct PictureInPictureForegroundRestoreState: Sendable {
    private var requested = false

    public init() {}

    public mutating func pictureInPictureWillStart() {
        requested = false
    }

    public mutating func consumeForegroundRequest(isPictureInPictureActive: Bool) -> Bool {
        guard isPictureInPictureActive else {
            requested = false
            return false
        }
        guard !requested else { return false }
        requested = true
        return true
    }

    /// The system is already ending the session (the window's "back to the app" button), so the
    /// foreground must not ask again: a second stop mid-restore is the one-frame flash of the app
    /// before AVKit's animation that a device recording showed (IOS-POC-17H-4).
    public mutating func pictureInPictureWillStop() {
        requested = true
    }

    public mutating func pictureInPictureDidStop() {
        requested = false
    }
}
