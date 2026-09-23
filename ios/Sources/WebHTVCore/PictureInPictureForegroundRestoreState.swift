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

    public mutating func pictureInPictureDidStop() {
        requested = false
    }
}
