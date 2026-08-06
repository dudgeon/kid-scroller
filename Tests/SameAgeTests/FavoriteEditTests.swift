import XCTest
import SameAgeCore
@testable import SameAge

/// R20 is the only write SameAge makes to the photo library, so it has to be exactly
/// right — and the rollback path is the one that never runs during normal use.
final class FavoriteEditTests: XCTestCase {

    private func item(_ asset: String, kid: Kid, favorite: Bool, age: Double = 10) -> FeedItem {
        FeedItem(assetIdentifier: asset, kid: kid,
                 captureDate: Date(timeIntervalSinceReferenceDate: age * 2_629_746),
                 ageMonths: age, kind: .photo, isFavorite: favorite, aspectRatio: 0.75)
    }

    func testCurrentValueReadsExistingState() {
        let items = [item("a1", kid: .a, favorite: true), item("a2", kid: .a, favorite: false)]
        XCTAssertEqual(FavoriteEdit.currentValue(itemID: items[0].id, in: items), true)
        XCTAssertEqual(FavoriteEdit.currentValue(itemID: items[1].id, in: items), false)
        XCTAssertNil(FavoriteEdit.currentValue(itemID: "nope", in: items))
    }

    func testApplyingSetsOnlyTheTargetItem() {
        let items = [item("a1", kid: .a, favorite: false), item("a2", kid: .a, favorite: false)]
        let updated = FavoriteEdit.applying(true, itemID: items[0].id, to: items)
        XCTAssertTrue(updated[0].isFavorite)
        XCTAssertFalse(updated[1].isFavorite, "an unrelated photo must not change")
    }

    func testApplyingIsANoOpForAnAbsentItem() {
        let items = [item("a1", kid: .a, favorite: false)]
        XCTAssertEqual(FavoriteEdit.applying(true, itemID: "missing", to: items), items)
    }

    /// The rollback contract: capture, write, restore. The original version re-applied the
    /// value it had just written, so a failed Photos write left the UI showing a favourite
    /// that was never saved.
    func testCaptureThenRollbackRestoresTheOriginalValue() {
        let original = [item("a1", kid: .a, favorite: false)]
        let id = original[0].id

        let captured = FavoriteEdit.currentValue(itemID: id, in: original)
        XCTAssertEqual(captured, false)

        let optimistic = FavoriteEdit.applying(true, itemID: id, to: original)
        XCTAssertTrue(optimistic[0].isFavorite, "optimistic write should show immediately")

        // …the Photos write fails…
        let rolledBack = FavoriteEdit.applying(captured!, itemID: id, to: optimistic)
        XCTAssertFalse(rolledBack[0].isFavorite, "rollback must restore the captured value")
        XCTAssertEqual(rolledBack, original)
    }

    /// R5: a photo of both kids appears in both ribbons under different ids. PhotoKit
    /// favourites the underlying *asset*, so the two entries must never disagree.
    func testSharedAssetUpdatesBothRibbonEntries() {
        let ribbonA = [item("shared", kid: .a, favorite: false), item("onlyA", kid: .a, favorite: false)]
        let ribbonB = [item("shared", kid: .b, favorite: false)]

        let updatedA = FavoriteEdit.applyingToAsset(true, assetIdentifier: "shared", to: ribbonA)
        let updatedB = FavoriteEdit.applyingToAsset(true, assetIdentifier: "shared", to: ribbonB)

        XCTAssertTrue(updatedA[0].isFavorite)
        XCTAssertTrue(updatedB[0].isFavorite, "the other kid's copy must follow the asset")
        XCTAssertFalse(updatedA[1].isFavorite, "unrelated photos untouched")
    }

    /// Favouriting has to actually change what a favourites-only filter admits, otherwise
    /// the feature is cosmetic.
    func testFavoritingChangesWhatTheFilterAdmits() {
        let favoritesOnly = FilterState(favoritesOnly: true)
        let items = [item("a1", kid: .a, favorite: false)]

        XCTAssertTrue(items.filter(favoritesOnly.admits).isEmpty)

        let updated = FavoriteEdit.applyingToAsset(true, assetIdentifier: "a1", to: items)
        XCTAssertEqual(updated.filter(favoritesOnly.admits).count, 1)

        let unfavorited = FavoriteEdit.applyingToAsset(false, assetIdentifier: "a1", to: updated)
        XCTAssertTrue(unfavorited.filter(favoritesOnly.admits).isEmpty,
                      "unfavouriting must remove it from a favourites-only feed")
    }
}
