import XCTest
import SameAgeCore
@testable import SameAge

/// Regression tests for the bug that shipped in build 0.1 (1): the feed's UIKit bridge
/// skips reconfiguration when its version is unchanged, and the version was derived from
/// the filter alone. Photos load asynchronously *after* the first render, and the filter
/// does not change while they load — so the feed configured once with empty arrays and
/// then ignored the real data forever. Symptom on device: a permanently black feed with a
/// working age rail and no error, because nothing had failed.
final class FeedVersionTests: XCTestCase {

    private func version(
        filter: FilterState = .all,
        contentVersion: Int = 0,
        axisMax: Double = 84,
        railOnLeft: Bool = true
    ) -> Int {
        FeedVersion.compute(filter: filter, contentVersion: contentVersion,
                            axisMax: axisMax, railOnLeft: railOnLeft)
    }

    /// THE regression. Same filter, content arrives — the version must move.
    func testVersionChangesWhenContentArrives() {
        let beforePhotosLoaded = version(contentVersion: 0)
        let afterPhotosLoaded  = version(contentVersion: 1)
        XCTAssertNotEqual(beforePhotosLoaded, afterPhotosLoaded,
                          "the feed would ignore newly-indexed photos and stay black")
    }

    /// Every subsequent refresh must also be seen — a background re-index that adds photos
    /// has to reach the screen.
    func testEverySubsequentRefreshIsDistinct() {
        var seen = Set<Int>()
        for generation in 0..<50 {
            XCTAssertTrue(seen.insert(version(contentVersion: generation)).inserted,
                          "generation \(generation) collided with an earlier one")
        }
    }

    func testVersionChangesWithFilter() {
        XCTAssertNotEqual(version(filter: .all),
                          version(filter: FilterState(favoritesOnly: true)))
        XCTAssertNotEqual(version(filter: .all),
                          version(filter: FilterState(kinds: [.video])))
    }

    func testVersionChangesWithAxisAndRailSide() {
        // Editing a birthday moves the axis; the rail toggle changes column geometry.
        XCTAssertNotEqual(version(axisMax: 84), version(axisMax: 96))
        XCTAssertNotEqual(version(railOnLeft: true), version(railOnLeft: false))
    }

    /// The guard has to keep doing its original job: identical state must NOT rebuild, or
    /// the mappings get rebuilt at scroll frequency.
    func testIdenticalStateIsStable() {
        XCTAssertEqual(version(), version())
        let filter = FilterState(favoritesOnly: true, kinds: [.photo, .video])
        XCTAssertEqual(version(filter: filter, contentVersion: 7),
                       version(filter: filter, contentVersion: 7))
    }
}

extension FeedVersionTests {
    /// Hiding a photo doesn't change the filter or the indexer generation — it must
    /// still reach the feed, or the "hidden" photo stays visible until the next refresh.
    func testVersionChangesWhenHiddenSetChanges() {
        let before = FeedVersion.compute(filter: .all, contentVersion: 3,
                                         axisMax: 84, railOnLeft: true,
                                         hiddenVersion: Set<String>().hashValue)
        let after = FeedVersion.compute(filter: .all, contentVersion: 3,
                                        axisMax: 84, railOnLeft: true,
                                        hiddenVersion: Set(["asset-1"]).hashValue)
        XCTAssertNotEqual(before, after, "hiding a photo would not reach the screen")
    }
}
