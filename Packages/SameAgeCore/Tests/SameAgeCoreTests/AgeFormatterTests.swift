import XCTest
@testable import SameAgeCore

final class AgeFormatterTests: XCTestCase {

    func testShortFormatting() {
        XCTAssertEqual(AgeFormatter.short(months: 0), "0m")
        XCTAssertEqual(AgeFormatter.short(months: 9), "9m")
        XCTAssertEqual(AgeFormatter.short(months: 11.4), "11m")
        XCTAssertEqual(AgeFormatter.short(months: 12), "1y 0m")
        XCTAssertEqual(AgeFormatter.short(months: 25), "2y 1m")
        XCTAssertEqual(AgeFormatter.short(months: 84), "7y 0m")
    }

    func testShortFormattingCarriesRoundedMonths() {
        // 23.6 rounds to 12 months within year 1; must carry to "2y 0m", not "1y 12m".
        XCTAssertEqual(AgeFormatter.short(months: 23.6), "2y 0m")
        XCTAssertEqual(AgeFormatter.short(months: 11.7), "1y 0m")
    }

    func testShortFormattingClampsNegative() {
        // Before birth can occur transiently while scrubbing the rail.
        XCTAssertEqual(AgeFormatter.short(months: -3), "0m")
    }

    func testYearTicks() {
        XCTAssertEqual(AgeFormatter.yearTick(months: 0), "0")
        XCTAssertEqual(AgeFormatter.yearTick(months: 12), "1y")
        XCTAssertEqual(AgeFormatter.yearTick(months: 84), "7y")
    }

    func testParseMonths() {
        XCTAssertEqual(AgeFormatter.parse("15"), 15)
        XCTAssertEqual(AgeFormatter.parse("15m"), 15)
        XCTAssertEqual(AgeFormatter.parse("15mo"), 15)
        XCTAssertEqual(AgeFormatter.parse("15 months"), 15)
        XCTAssertEqual(AgeFormatter.parse(" 7 "), 7)
    }

    func testParseYears() {
        XCTAssertEqual(AgeFormatter.parse("2.5y"), 30)
        XCTAssertEqual(AgeFormatter.parse("2.5 y"), 30)
        XCTAssertEqual(AgeFormatter.parse("3years"), 36)
        XCTAssertEqual(AgeFormatter.parse("3 yr"), 36)
        XCTAssertEqual(AgeFormatter.parse("1Y"), 12)
    }

    func testParseCombined() {
        XCTAssertEqual(AgeFormatter.parse("2y 6m"), 30)
        XCTAssertEqual(AgeFormatter.parse("2y6m"), 30)
        XCTAssertEqual(AgeFormatter.parse("1y 0m"), 12)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(AgeFormatter.parse(""))
        XCTAssertNil(AgeFormatter.parse("   "))
        XCTAssertNil(AgeFormatter.parse("abc"))
        XCTAssertNil(AgeFormatter.parse("y"))
        XCTAssertNil(AgeFormatter.parse("2y 6"))   // ambiguous, no unit on the tail
        XCTAssertNil(AgeFormatter.parse("12/4"))
    }

    func testParseRoundTripsWithShort() {
        for months in stride(from: 0.0, through: 84.0, by: 1.0) {
            guard let parsed = AgeFormatter.parse(AgeFormatter.short(months: months)) else {
                return XCTFail("could not re-parse \(AgeFormatter.short(months: months))")
            }
            XCTAssertEqual(parsed, months, accuracy: 0.5)
        }
    }
}

final class AgeMathTests: XCTestCase {

    func testAgeMonthsIsMonotonicAndInvertible() {
        let birthday = Date(timeIntervalSinceReferenceDate: 0)
        var previous = -Double.infinity
        for days in stride(from: 0, through: 3650, by: 7) {
            let date = birthday.addingTimeInterval(Double(days) * 86_400)
            let age = AgeMath.ageMonths(birthday: birthday, at: date)
            XCTAssertGreaterThan(age, previous)
            previous = age
            XCTAssertEqual(
                AgeMath.date(birthday: birthday, ageMonths: age).timeIntervalSinceReferenceDate,
                date.timeIntervalSinceReferenceDate,
                accuracy: 1e-6
            )
        }
    }

    func testAgeIsNegativeBeforeBirth() {
        let birthday = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let before = birthday.addingTimeInterval(-86_400 * 30)
        XCTAssertLessThan(AgeMath.ageMonths(birthday: birthday, at: before), 0)
    }

    func testTwelveMonthsIsAboutOneYear() {
        let birthday = Date(timeIntervalSinceReferenceDate: 0)
        let oneYear = AgeMath.date(birthday: birthday, ageMonths: 12)
        let days = oneYear.timeIntervalSince(birthday) / 86_400
        XCTAssertEqual(days, 365.2425, accuracy: 0.01)
    }
}

final class FilterStateTests: XCTestCase {

    private func item(kind: MediaKind, favorite: Bool) -> FeedItem {
        FeedItem(
            assetIdentifier: "x", kid: .a, captureDate: Date(timeIntervalSinceReferenceDate: 0),
            ageMonths: 10, kind: kind, isFavorite: favorite, aspectRatio: 0.75
        )
    }

    func testAllAdmitsEverything() {
        for kind in MediaKind.allCases {
            XCTAssertTrue(FilterState.all.admits(item(kind: kind, favorite: false)))
        }
    }

    func testFavoritesOnly() {
        let filter = FilterState(favoritesOnly: true)
        XCTAssertTrue(filter.admits(item(kind: .photo, favorite: true)))
        XCTAssertFalse(filter.admits(item(kind: .photo, favorite: false)))
    }

    func testMediaKind() {
        let filter = FilterState(kinds: [.video])
        XCTAssertTrue(filter.admits(item(kind: .video, favorite: false)))
        XCTAssertFalse(filter.admits(item(kind: .photo, favorite: false)))
        XCTAssertFalse(filter.admits(item(kind: .livePhoto, favorite: false)))
    }

    func testFiltersCompose() {
        let filter = FilterState(favoritesOnly: true, kinds: [.video])
        XCTAssertTrue(filter.admits(item(kind: .video, favorite: true)))
        XCTAssertFalse(filter.admits(item(kind: .video, favorite: false)))
        XCTAssertFalse(filter.admits(item(kind: .photo, favorite: true)))
    }
}
