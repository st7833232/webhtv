/// Which page a category or filtered listing asks for next (W-214). A page that fails is asked again on
/// the next scroll to the bottom, as FongMi's CustomScroller does (it steps `page` back on a failure);
/// after `retries` failures in a row the listing stops, so a dead source is not called on every scroll.
/// An empty page counts as a failure: a Python spider swallows its network error and answers
/// `{list: []}` (py/duboku.py `_api`), so a real last page costs at most `retries` more calls. A page
/// whose titles are all already listed ends it: a source that ignores `pg` (`merging(newTitlesFrom:)`).
public struct ListingPager: Equatable, Sendable {
    public static let retries = 3
    /// The last page on screen.
    public private(set) var page = 1
    public private(set) var failures = 0
    public private(set) var ended = false

    public init() {}

    public var canLoadMore: Bool { !ended && failures < Self.retries }
    public var next: Int { page + 1 }

    /// `next` came back with `listed` titles, `added` of them new to the listing.
    public mutating func loaded(listing listed: Int, adding added: Int) {
        guard listed > 0 else { return failed() }
        failures = 0
        if added > 0 { page += 1 } else { ended = true }
    }

    /// `next` failed; the same page is asked again next time.
    public mutating func failed() { failures += 1 }
}
