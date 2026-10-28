import Testing
@testable import WebHTVCore

/// W-214: a listing's next page after a failure, an empty page and failures in a row.
struct ListingPagerTests {
    @Test func aFailedPageIsAskedAgainAndThenTheListingGoesOn() {
        var pager = ListingPager()
        pager.loaded(adding: 20)
        #expect(pager.next == 3)
        pager.failed()
        #expect(pager.canLoadMore && pager.next == 3)
        pager.loaded(adding: 20)
        #expect(pager.page == 3 && pager.failures == 0 && pager.next == 4)
    }

    @Test func aPageThatAddsNothingEndsTheListing() {
        var pager = ListingPager()
        pager.loaded(adding: 0)
        #expect(!pager.canLoadMore && pager.page == 1)
    }

    @Test func failuresInARowStopAtTheLimitAndASuccessResetsThem() {
        var pager = ListingPager()
        for _ in 1..<ListingPager.retries { pager.failed() }
        #expect(pager.canLoadMore)
        pager.loaded(adding: 5)
        for _ in 1..<ListingPager.retries { pager.failed() }
        #expect(pager.canLoadMore)
        pager.failed()
        #expect(!pager.canLoadMore && pager.next == 3)
    }
}
