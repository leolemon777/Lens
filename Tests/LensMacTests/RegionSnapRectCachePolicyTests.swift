import XCTest
@testable import LensMac

final class RegionSnapRectCachePolicyTests: XCTestCase {
    private let policy = RegionSnapRectCachePolicy.standard

    func testNeverPopulatedCacheIsUnusableAndRefreshesImmediately() {
        // The coordinator seeds the timestamp with -.infinity before the first
        // window enumeration finishes. An overlay must not snap to nothing, and
        // the first prewarm must not be throttled away.
        XCTAssertFalse(policy.isUsable(cachedAt: -.infinity, now: 12))
        XCTAssertTrue(
            policy.shouldRefresh(
                cachedAt: -.infinity,
                now: 12,
                isRefreshing: false
            )
        )
    }

    func testCacheStaysUsableAcrossAGapThatWouldHaveExpiredTheOldWindow() {
        // The previous three second lifetime meant a menu bar utility running
        // for hours took every capture down the cold path.
        XCTAssertTrue(policy.isUsable(cachedAt: 100, now: 104))
        XCTAssertTrue(policy.isUsable(cachedAt: 100, now: 129.9))
    }

    func testCacheStopsBeingUsableOnceTheLayoutIsTooOldToTrust() {
        XCTAssertFalse(policy.isUsable(cachedAt: 100, now: 130.1))
        XCTAssertFalse(policy.isUsable(cachedAt: 100, now: 400))
    }

    func testRefreshIsThrottledSoApplicationSwitchingCannotStormEnumeration() {
        XCTAssertFalse(
            policy.shouldRefresh(cachedAt: 100, now: 100.4, isRefreshing: false)
        )
        XCTAssertTrue(
            policy.shouldRefresh(cachedAt: 100, now: 101, isRefreshing: false)
        )
    }

    func testRefreshAlreadyInFlightWins() {
        XCTAssertFalse(
            policy.shouldRefresh(cachedAt: 0, now: 10_000, isRefreshing: true)
        )
    }

    func testClockGoingBackwardsIsTreatedAsUnusableRatherThanFresh() {
        // systemUptime should be monotonic, but a negative age must never be
        // read as a zero-age cache.
        XCTAssertFalse(policy.isUsable(cachedAt: 200, now: 100))
    }

    func testNonFiniteConfigurationCollapsesToSafeBounds() {
        let policy = RegionSnapRectCachePolicy(
            usableLifetime: .nan,
            minimumRefreshInterval: -5
        )

        XCTAssertEqual(policy.usableLifetime, 0)
        XCTAssertEqual(policy.minimumRefreshInterval, 0)
        XCTAssertTrue(policy.isUsable(cachedAt: 100, now: 100))
        XCTAssertFalse(policy.isUsable(cachedAt: 100, now: 100.1))
    }
}
