import Foundation

/// CatVod's `url` field, which is three shapes rather than one.
///
/// `app/src/main/java/com/fongmi/android/tv/gson/UrlAdapter.java` is the authority:
///
/// - a JSON **string** is one unnamed value;
/// - a JSON **array** is alternating `name, url` pairs, and a trailing odd element is dropped —
///   `convert` steps in twos while `i + 1 < size`;
/// - a JSON **object** is `{"values": [{"n", "v"}], "position": n}`, and `Url.objectFrom` catches
///   its own parse failure and yields an empty `Url` rather than propagating one.
///
/// Reading only the string shape is what made a multi-quality source fail in two different ways:
/// `decodeIfPresent(String.self)` on the spider path **throws** `DecodingError.typeMismatch` (a
/// type mismatch is an error, not a nil), which surfaced as a raw decoder message, while the CMS
/// path's `try?` swallowed the same error into `nil` and reported 「這一集沒有可播放的網址」.
/// Neither is the source being broken; both are us not reading it.
public struct PlayURL: Decodable, Sendable, Equatable {
    /// One entry of the menu. `Value.n`/`Value.v` are the field names Android's `Value` declares.
    public struct Value: Decodable, Sendable, Equatable {
        /// The quality's display name, absent for the single-string shape.
        public let n: String?
        public let v: String

        public init(n: String? = nil, v: String) {
            self.n = n
            self.v = v
        }

        enum CodingKeys: String, CodingKey { case n, v }

        /// Tolerant on purpose: Gson leaves a missing field null and `Url.isEmpty` decides later,
        /// so one odd member must not discard the whole menu.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            n = (try? values.decodeIfPresent(String.self, forKey: .n)) ?? nil
            v = ((try? values.decodeIfPresent(String.self, forKey: .v)) ?? nil) ?? ""
        }
    }

    public let values: [Value]
    /// The source's own preferred index, clamped into range the way `Url.set(int)` clamps it.
    public let position: Int

    public init(values: [Value], position: Int = 0) {
        self.values = values
        self.position = values.isEmpty ? 0 : min(max(position, 0), values.count - 1)
    }

    /// The single-URL shape, which is what every CMS source and every ported spider but `Bili`
    /// produces today.
    public init(_ url: String) {
        self.init(values: [Value(v: url)])
    }

    /// `Url.isEmpty`: no values at all, or the one at `position` has no address. An empty menu is
    /// an unplayable episode, which is a thing to report rather than a decode failure.
    public var isEmpty: Bool {
        values.isEmpty || values[position].v.isEmpty
    }

    enum CodingKeys: String, CodingKey { case values, position }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self.init(text)
            return
        }
        if var array = try? decoder.unkeyedContainer() {
            var flat = [String]()
            while !array.isAtEnd {
                if let text = try? array.decode(String.self) {
                    flat.append(text)
                } else if let number = try? array.decode(Int.self) {
                    flat.append(String(number))
                } else {
                    // `Skip` always succeeds, which is what advances the container; a failed decode
                    // leaves `currentIndex` where it was and would spin here forever.
                    _ = try? array.decode(Skip.self)
                    flat.append("")
                }
            }
            var values = [Value]()
            var index = 0
            while index + 1 < flat.count {
                values.append(Value(n: flat[index], v: flat[index + 1]))
                index += 2
            }
            self.init(values: values)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let values = ((try? keyed.decodeIfPresent([Value].self, forKey: .values)) ?? nil) ?? []
        let position = ((try? keyed.decodeIfPresent(Int.self, forKey: .position)) ?? nil) ?? 0
        self.init(values: values, position: position)
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// The quality menu of what is playing now — the control bar's since the 播放 page went
/// (IOS-POC-17E) — and which entry is on screen.
///
/// **Only the source's default entry went through the probe and the sniffer**, so it is the one
/// played from its *resolved* address; any other entry is opened exactly as the source gave it.
/// ponytail: that asymmetry is the cost of resolving one URL instead of every one. Resolve the chosen
/// entry through `SourceClient` if a real multi-value source ever needs the hop on a non-default one.
public struct PlaybackQualityChoice: Sendable, Equatable {
    public let qualities: [PlaybackQuality]
    public private(set) var selected: Int
    private let resolvedIndex: Int
    private let resolvedURL: URL

    /// Starts on the remembered quality, else the source's default (IOS-POC-5Q D8, 5R R6).
    public init(target: PlaybackTarget, preferred: String) {
        qualities = target.qualities
        resolvedIndex = target.defaultIndex
        resolvedURL = target.url
        selected = PlaybackQuality.defaultIndex(in: target.qualities, position: target.position,
                                                preferred: preferred.isEmpty ? nil : preferred)
    }

    /// A menu with one entry decides nothing, so the bar shows it only when there is a choice.
    public var offersChoice: Bool { qualities.count > 1 }
    public var name: String { qualities.indices.contains(selected) ? qualities[selected].name : "" }
    public var url: URL {
        guard selected != resolvedIndex, qualities.indices.contains(selected) else { return resolvedURL }
        return qualities[selected].url
    }

    /// Returns whether the choice actually changed.
    @discardableResult
    public mutating func select(_ index: Int) -> Bool {
        guard qualities.indices.contains(index), index != selected else { return false }
        selected = index
        return true
    }
}

/// One selectable stream: what a source called it, and where it is.
public struct PlaybackQuality: Sendable, Equatable {
    /// The source's own label. Empty for a single-URL source, which names nothing.
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// Where the menu starts, in the source's own order.
    ///
    /// Priority, which is D8 of the IOS-POC-5Q plan: a remembered choice first, because a name the
    /// user picked by hand must not be overridden by a default; then the highest-ranking label;
    /// then the source's own `position`. The menu itself is never reordered — Android keeps
    /// `Url.values` in the order the source sent and only moves `position`.
    ///
    /// `preferred` is a parameter rather than a lookup so this stays a pure function: the watch
    /// history that will supply it (IOS-POC-5R R6) does not exist yet.
    public static func defaultIndex(in qualities: [PlaybackQuality],
                                   position: Int = 0,
                                   preferred: String? = nil) -> Int {
        guard !qualities.isEmpty else { return 0 }
        let fallback = min(max(position, 0), qualities.count - 1)
        if let preferred, let remembered = qualities.firstIndex(where: { $0.name == preferred }) {
            return remembered
        }
        let ranked = qualities.enumerated().compactMap { index, quality in
            rank(quality.name).map { (index: index, rank: $0) }
        }
        // Nothing in any label matched, so there is no evidence to reorder on: keep the source's
        // own preference rather than guessing.
        guard let best = ranked.max(by: { $0.rank < $1.rank }) else { return fallback }
        return best.index
    }

    /// Ranks a free-text quality label. Higher is better; `nil` means nothing in it matched.
    ///
    /// ponytail: a heuristic over site-authored free text, because no one publishes a table of
    /// these words. If a source ever ranks wrongly, add its wording to this list — do not grow a
    /// parser. The `qn` numbers bilibili uses are deliberately absent: IOS-POC-5Q Q2 gives that
    /// source one flag per quality, so a bare `qn` never reaches a `url` array.
    static func rank(_ label: String) -> Int? {
        let table: [(String, Int)] = [
            ("8k", 110),
            ("4320", 110),
            ("2160", 100), ("4k", 100),
            ("1440", 90), ("2k", 90),
            ("1080", 80), ("藍光", 80), ("蓝光", 80), ("超清", 80),
            ("720", 70), ("高清", 70),
            ("480", 60), ("標清", 60), ("标清", 60),
            ("360", 50), ("流暢", 50), ("流畅", 50),
            ("240", 40)
        ]
        let lower = label.lowercased()
        // The maximum of every match, not the first: 「藍光 4K」 names two and means the higher one.
        return table.filter { lower.contains($0.0) }.map(\.1).max()
    }
}
