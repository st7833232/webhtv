import Foundation

/// W-263 (W-259 plan C): the lines a failed VOD episode is tried on next. One round that starts
/// after the line that failed and wraps, each line at most once, as `LiveLineSwitcher` does for
/// live — where FongMi only moves forward. A line without the same episode is skipped, and the
/// round ends at a time limit so a title with many dead lines cannot keep switching for minutes.
public struct VodLineSwitcher: Sendable {
    public struct Step: Equatable, Sendable {
        public let flag: Int
        public let episode: Int
    }

    /// Two minutes: a line can take its resolve plus W-253's startup give-up (about 30 s) on both
    /// engines, so this covers two or three lines and then shows the failure.
    public static let roundLimit: TimeInterval = 120

    private let flags: [Flag]
    private let source: Flag
    private let episode: Episode
    private let spider: Bool
    private let deadline: Date
    private var round: [Int]

    /// `failed` is the line `episode` just failed on; it is not tried again in this round.
    public init(flags: [Flag], failed: Int, episode: Episode, spider: Bool, now: Date = Date(),
                limit: TimeInterval = VodLineSwitcher.roundLimit) {
        self.flags = flags
        source = flags.indices.contains(failed) ? flags[failed] : Flag(name: "", episodes: [episode])
        self.episode = episode
        self.spider = spider
        deadline = now.addingTimeInterval(limit)
        let count = flags.count
        round = count < 2 || !flags.indices.contains(failed) ? [] : (1..<count).map { (failed + $0) % count }
    }

    /// The next line holding the same episode, or nil once the round is used up or past its limit.
    public mutating func next(now: Date = Date()) -> Step? {
        while !round.isEmpty, now <= deadline {
            let index = round.removeFirst()
            if let match = flags[index].sameEpisode(as: episode, in: source),
               flags[index].episodes[match].isPlayable(spider: spider) {
                return Step(flag: index, episode: match)
            }
        }
        return nil
    }
}

extension Flag {
    /// The index of `episode` (from line `source`) on this line, or nil when this line cannot be
    /// trusted to hold it (W-259 review condition 1). By name first, then by the episode number in
    /// the name; the position only when both lines hold the same number of episodes — a line with
    /// a trailer or a missing episode would otherwise play the wrong one.
    public func sameEpisode(as episode: Episode, in source: Flag) -> Int? {
        let name = episode.name.trimmingCharacters(in: .whitespaces)
        if let byName = episodes.firstIndex(where: {
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
        }) { return byName }
        if let number = Self.episodeNumber(name) {
            let numbered = episodes.indices.filter { Self.episodeNumber(episodes[$0].name) == number }
            if numbered.count == 1 { return numbered[0] }
        }
        guard episodes.count == source.episodes.count,
              let position = source.episodes.firstIndex(where: { $0.url == episode.url }) else { return nil }
        return position
    }

    /// The first run of digits in an episode name: 第01集 → 1, EP12 → 12.
    static func episodeNumber(_ name: String) -> Int? {
        guard let digits = name.firstMatch(of: /\d+/) else { return nil }
        return Int(digits.output)
    }
}
