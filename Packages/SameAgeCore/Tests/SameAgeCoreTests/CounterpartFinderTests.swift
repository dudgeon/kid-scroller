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

/// Invariants for paging through fullscreen: advancing the primary photo must advance the
/// age-matched counterpart with it, never backwards.
final class CounterpartPagingTests: XCTestCase {

    private func ribbon(_ ages: [Double], kid: Kid) -> [FeedItem] {
        ages.enumerated().map { index, age in
            FeedItem(assetIdentifier: "\(kid.rawValue)-\(index)", kid: kid,
                     captureDate: Date(timeIntervalSinceReferenceDate: age * 2_629_746),
                     ageMonths: age, kind: .photo, aspectRatio: 0.75)
        }
    }

    /// Paging forward through one kid must never move the other kid backwards in age —
    /// that would read as the sibling ribbon jumping around at random.
    func testCounterpartNeverGoesBackwardsWhilePagingForward() {
        let primary = ribbon(stride(from: 0.5, through: 90, by: 0.8).map { $0 }, kid: .a)
        let other = ribbon(stride(from: 1.2, through: 60, by: 2.3).map { $0 }, kid: .b)

        var previousAge = -Double.infinity
        for item in primary {
            guard let match = CounterpartFinder.nearest(toAge: item.ageMonths, in: other) else {
                return XCTFail("expected a counterpart for every page")
            }
            XCTAssertGreaterThanOrEqual(match.ageMonths, previousAge,
                                        "counterpart jumped backwards at \(item.ageMonths)mo")
            previousAge = match.ageMonths
        }
    }

    /// Past the younger kid's last photo, every further page holds on their most recent
    /// one rather than showing nothing (R6).
    func testCounterpartHoldsPastTheYoungerKidsLastPhoto() {
        let primary = ribbon([40, 60, 80, 100], kid: .a)
        let other = ribbon([10, 20, 30], kid: .b)

        let matches = primary.compactMap { CounterpartFinder.nearest(toAge: $0.ageMonths, in: other) }
        XCTAssertEqual(matches.count, primary.count)
        XCTAssertTrue(matches.allSatisfy { $0.ageMonths == 30 },
                      "should hold the younger kid's last photo")
    }

    /// Every page must resolve to something; an empty inset would be a dead end.
    func testEveryPageResolvesACounterpart() {
        let primary = ribbon([1, 5, 9], kid: .a)
        XCTAssertTrue(primary.allSatisfy {
            CounterpartFinder.nearest(toAge: $0.ageMonths, in: ribbon([7], kid: .b)) != nil
        })
    }
}
