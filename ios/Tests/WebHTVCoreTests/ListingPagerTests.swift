import Testing
@testable import WebHTVCore

/// W-214: a listing's next page after a failure, an empty page, a page of repeats and failures in a row.
struct ListingPagerTests {
    @Test func aFailedPageIsAskedAgainAndThenTheListingGoesOn() {
        var pager = ListingPager()
        pager.loaded(listing: 20, adding: 20)
        #expect(pager.next == 3)
        pager.failed()
        #expect(pager.canLoadMore && pager.next == 3)
        pager.loaded(listing: 20, adding: 20)
        #expect(pager.page == 3 && pager.failures == 0 && pager.next == 4)
    }

    /// py/duboku.py answers `{list: []}` when its request fails: tried again, then the listing goes on.
    @Test func anEmptyPageIsAFailureAndTheNextTryGoesOn() {
        var pager = ListingPager()
        pager.loaded(listing: 0, adding: 0)
        #expect(pager.canLoadMore && pager.failures == 1 && pager.next == 2)
        pager.loaded(listing: 20, adding: 20)
        #expect(pager.page == 2 && pager.failures == 0)
    }

    @Test func emptyPagesInARowStopAtTheLimit() {
        var pager = ListingPager()
        for _ in 0..<ListingPager.retries { pager.loaded(listing: 0, adding: 0) }
        #expect(!pager.canLoadMore && !pager.ended)
    }

    /// A source that ignores `pg` answers page 1 again: titles, none of them new.
    @Test func aPageOfTitlesAlreadyListedEndsTheListing() {
        var pager = ListingPager()
        pager.loaded(listing: 20, adding: 0)
        #expect(!pager.canLoadMore && pager.ended && pager.page == 1)
    }

    @Test func failuresInARowStopAtTheLimitAndASuccessResetsThem() {
        var pager = ListingPager()
        for _ in 1..<ListingPager.retries { pager.failed() }
        #expect(pager.canLoadMore)
        pager.loaded(listing: 5, adding: 5)
        for _ in 1..<ListingPager.retries { pager.failed() }
        #expect(pager.canLoadMore)
        pager.failed()
        #expect(!pager.canLoadMore && pager.next == 3)
    }
}
