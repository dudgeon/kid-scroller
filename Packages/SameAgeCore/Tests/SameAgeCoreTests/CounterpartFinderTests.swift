import XCTest
@testable import SameAgeCore

final class CounterpartFinderTests: XCTestCase {

    private func items(_ ages: [Double]) -> [FeedItem] {
        ages.enumerated().map { index, age in
            FeedItem(assetIdentifier: "c\(index)", kid: .b,
                     captureDate: Date(timeIntervalSinceReferenceDate: age * 2_629_746),
                     ageMonths: age, kind: .photo, aspectRatio: 0.75)
        }
    }

    func testEmptyRibbonHasNoCounterpart() {
        XCTAssertNil(CounterpartFinder.nearest(toAge: 20, in: []))
    }

    func testSingleItem() {
        let one = items([30])
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 2, in: one)?.ageMonths, 30)
    }

    func testPicksTheNearerNeighbour() {
        let ribbon = items([0, 10, 20, 30, 40])
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 21, in: ribbon)?.ageMonths, 20)
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 29, in: ribbon)?.ageMonths, 30)
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 25, in: ribbon)?.ageMonths, 20, "ties go to the earlier photo")
    }

    func testClampsBeyondBothEnds() {
        let ribbon = items([12, 24, 36])
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 0, in: ribbon)?.ageMonths, 12)
        // R6: past the younger kid's last photo we still show their most recent one.
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 200, in: ribbon)?.ageMonths, 36)
    }

    func testExactHit() {
        let ribbon = items([12, 24, 36])
        XCTAssertEqual(CounterpartFinder.nearest(toAge: 24, in: ribbon)?.ageMonths, 24)
    }

    func testAgreesWithBruteForce() {
        let ages = stride(from: 0.7, through: 80.0, by: 1.7).map { $0 }
        let ribbon = items(ages)
        for step in 0...900 {
            let age = Double(step) / 10
            let fast = CounterpartFinder.nearest(toAge: age, in: ribbon)!
            let slow = ribbon.min { abs($0.ageMonths - age) < abs($1.ageMonths - age) }!
            XCTAssertEqual(fast.ageMonths, slow.ageMonths, accuracy: 1e-9, "mismatch at \(age)")
        }
    }

    func testGapReportsDistance() {
        let ribbon = items([12, 24])
        XCTAssertEqual(CounterpartFinder.gap(fromAge: 20, to: CounterpartFinder.nearest(toAge: 20, in: ribbon))!,
                       4, accuracy: 1e-9)
        XCTAssertNil(CounterpartFinder.gap(fromAge: 20, to: nil))
    }
}
