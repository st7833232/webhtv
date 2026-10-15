/// The order a channel's lines are tried in (IOS-POC-59 U1, D§6.3.1). X-3: one round that starts
/// with the chosen line itself and wraps, where Android stops at the last line. Lines iOS cannot
/// play are skipped; rtmp/rtsp are tried. "Retry" is `select` of the start again.
public struct LiveLineSwitcher: Sendable {
    private let tried: [Bool]
    private var round: [Int] = []

    public init(lines: [LiveLine], start: Int) {
        tried = lines.map(\.support.isTried)
        select(start)
    }

    /// The next line to try, or nil once every usable line of this round has been tried.
    public mutating func next() -> Int? {
        round.isEmpty ? nil : round.removeFirst()
    }

    /// Starts a new round from `index` (a line picked by hand, or the start for a retry).
    public mutating func select(_ index: Int) {
        let count = tried.count
        round = (0..<count).map { (index + $0) % count }.filter { tried[$0] }
    }
}
