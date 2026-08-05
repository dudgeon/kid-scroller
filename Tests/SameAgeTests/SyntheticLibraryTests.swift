import XCTest
import SameAgeCore
@testable import SameAge

/// App-layer tests. The mapping maths lives in `SameAgeCore` and is tested there against
/// macOS, with no simulator needed; this target covers the app's own wiring.
final class SyntheticLibraryTests: XCTestCase {

    func testFixtureIsDeterministic() {
        let first = SyntheticLibrary.makeItems()
        let second = SyntheticLibrary.makeItems()
        XCTAssertEqual(first.a.map(\.id), second.a.map(\.id))
        XCTAssertEqual(first.b.map(\.id), second.b.map(\.id))
    }

    func testBothRibbonsHaveContent() {
        let (a, b) = SyntheticLibrary.makeItems()
        XCTAssertGreaterThan(a.count, 50)
        XCTAssertGreaterThan(b.count, 20)
    }

    func testYoungerRibbonStopsEarlier() {
        // R6: past the younger kid's current age the feed keeps going, older kid solo.
        let (a, b) = SyntheticLibrary.makeItems()
        guard let lastA = a.map(\.ageMonths).max(), let lastB = b.map(\.ageMonths).max() else {
            return XCTFail("expected items in both ribbons")
        }
        XCTAssertGreaterThan(lastA, lastB)
    }

    func testSharedPhotosAppearInBothRibbons() {
        // R5: one asset, two ribbon entries, each at that kid's own age.
        let (a, b) = SyntheticLibrary.makeItems()
        let sharedInA = Set(a.filter { $0.assetIdentifier.hasPrefix("shared-") }.map(\.assetIdentifier))
        let sharedInB = Set(b.filter { $0.assetIdentifier.hasPrefix("shared-") }.map(\.assetIdentifier))
        XCTAssertFalse(sharedInA.isEmpty)
        XCTAssertEqual(sharedInA, sharedInB)

        for asset in sharedInA {
            let ageA = a.first { $0.assetIdentifier == asset }!.ageMonths
            let ageB = b.first { $0.assetIdentifier == asset }!.ageMonths
            XCTAssertEqual(ageA - ageB, SyntheticLibrary.siblingGapMonths, accuracy: 1e-6)
        }
    }

    func testYoungerRibbonHasADetectableSparseStretch() {
        // The fixture must actually exercise D3 ghosting, or the feed can't be verified.
        let (_, b) = SyntheticLibrary.makeItems()
        let mapping = RibbonMapping(placed: RibbonLayout.build(items: b, columnWidth: 180))
        XCTAssertTrue(mapping.isSparse(atAge: 36), "expected the seeded 30-42mo drought")
        XCTAssertFalse(mapping.isSparse(atAge: 10), "infancy should be dense")
    }
}
