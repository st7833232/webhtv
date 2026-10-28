/// Which page a category or filtered listing asks for next (W-214). A page that fails is asked again on
/// the next scroll to the bottom, as FongMi's CustomScroller does (it steps `page` back on a failure);
/// after `retries` failures in a row the listing stops, so a dead source is not called on every scroll.
/// A page that adds no title ends it: the end of the list, or a source that ignores `pg`
/// (`merging(newTitlesFrom:)`).
public struct ListingPager: Equatable, Sendable {
    public static let retries = 3
    /// The last page on screen.
    public private(set) var page = 1
    public private(set) var failures = 0
    public private(set) var ended = false

    public init() {}

    public var canLoadMore: Bool { !ended && failures < Self.retries }
    public var next: Int { page + 1 }

    /// `next` came back and added `added` titles to the listing.
    public mutating func loaded(adding added: Int) {
        failures = 0
        if added > 0 { page += 1 } else { ended = true }
    }

    /// `next` failed; the same page is asked again next time.
    public mutating func failed() { failures += 1 }
}
