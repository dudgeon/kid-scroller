import XCTest
@testable import SameAgeCore

/// The mapping is the load-bearing part of the app: if `offset` is not strictly
/// increasing, the combined inverse silently returns garbage and the two ribbons drift
/// out of age alignment. These tests pin the invariants rather than specific pixel
/// values, so layout tuning stays free.
final class AgeMappingTests: XCTestCase {

    // MARK: - Fixtures

    static let birthday = Date(timeIntervalSinceReferenceDate: 0)
    static let columnWidth: Double = 160

    func makeItem(
        _ id: String,
        kid: Kid = .a,
        ageMonths: Double,
        aspect: Double = 0.75,
        kind: MediaKind = .photo,
        favorite: Bool = false
    ) -> FeedItem {
        FeedItem(
            assetIdentifier: id,
            kid: kid,
            captureDate: AgeMath.date(birthday: Self.birthday, ageMonths: ageMonths),
            ageMonths: ageMonths,
            kind: kind,
            isFavorite: favorite,
            aspectRatio: aspect
        )
    }

    /// A ribbon with a deliberate sparse window, mirroring the spec prototype's Kid B
    /// (dense early, near-empty from 30–42 months).
    func ribbonWithSparseWindow() -> RibbonMapping {
        var items: [FeedItem] = []
        var age = 0.4
        var n = 0
        while age < 54 {
            items.append(makeItem("s\(n)", ageMonths: age))
            n += 1
            age += (age >= 30 && age <= 42) ? 6.5 : 0.8
        }
        return RibbonMapping(placed: RibbonLayout.build(items: items, columnWidth: Self.columnWidth))
    }

    func denseRibbon(count: Int, upTo maxAge: Double, kid: Kid = .a) -> RibbonMapping {
        let items = (0..<count).map { i -> FeedItem in
            let t = Double(i) / Double(max(count - 1, 1))
            // Non-uniform on purpose: bursts early, sparser later.
            return makeItem("d\(i)", kid: kid, ageMonths: 0.5 + maxAge * t * t, aspect: 0.6 + 0.5 * Double(i % 3))
        }
        return RibbonMapping(placed: RibbonLayout.build(items: items, columnWidth: Self.columnWidth))
    }

    // MARK: - Layout

    func testLayoutSortsAndAccumulates() {
        let items = [makeItem("c", ageMonths: 30), makeItem("a", ageMonths: 5), makeItem("b", ageMonths: 12)]
        let placed = RibbonLayout.build(items: items, columnWidth: Self.columnWidth)

        XCTAssertEqual(placed.map(\.item.assetIdentifier), ["a", "b", "c"])
        for (prev, next) in zip(placed, placed.dropFirst()) {
            XCTAssertEqual(next.top, prev.bottom + RibbonMetrics.gap, accuracy: 1e-9)
        }
    }

    func testLayoutUsesNativeAspectRatio() {
        // R14: no cropping — height is derived from the asset's own aspect.
        let placed = RibbonLayout.build(
            items: [makeItem("wide", ageMonths: 1, aspect: 2.0), makeItem("tall", ageMonths: 2, aspect: 0.5)],
            columnWidth: 200
        )
        XCTAssertEqual(placed[0].height, 100, accuracy: 1e-9)
        XCTAssertEqual(placed[1].height, 400, accuracy: 1e-9)
    }

    func testDuplicateAgesAreSeparated() {
        // Burst shots share a capture instant; without nudging, interpolation divides by zero.
        let items = (0..<5).map { makeItem("burst\($0)", ageMonths: 18) }
        let placed = RibbonLayout.build(items: items, columnWidth: Self.columnWidth)
        for (prev, next) in zip(placed, placed.dropFirst()) {
            XCTAssertGreaterThan(next.anchorAge, prev.anchorAge)
        }
        let mapping = RibbonMapping(placed: placed)
        XCTAssertTrue(mapping.offset(atAge: 18).isFinite)
    }

    func testCorruptAspectRatioFallsBack() {
        let bad = FeedItem(
            assetIdentifier: "x", kid: .a, captureDate: Self.birthday,
            ageMonths: 1, kind: .photo, aspectRatio: 0
        )
        XCTAssertEqual(bad.aspectRatio, 0.75, accuracy: 1e-9)
        XCTAssertTrue(RibbonLayout.build(items: [bad], columnWidth: 100)[0].height.isFinite)
    }

    // MARK: - Ribbon mapping

    func testOffsetIsStrictlyIncreasing() {
        let mapping = denseRibbon(count: 240, upTo: 84)
        var previous = -Double.infinity
        for step in 0...8400 {
            let value = mapping.offset(atAge: Double(step) / 100)
            XCTAssertGreaterThan(value, previous, "offset regressed at age \(Double(step) / 100)")
            previous = value
        }
    }

    func testLeadInPlacesAgeZeroAboveFirstPhoto() {
        // offset(0) should equal half the first photo's height: the ribbon starts with
        // the first photo's centre one lead-in away from the reading line.
        let first = makeItem("f", ageMonths: 9, aspect: 0.75)
        let placed = RibbonLayout.build(items: [first, makeItem("g", ageMonths: 20)], columnWidth: Self.columnWidth)
        let mapping = RibbonMapping(placed: placed)
        XCTAssertEqual(mapping.offset(atAge: 0), placed[0].height / 2, accuracy: 1e-9)
    }

    func testTailCrawlsAtConstantRate() {
        // R6: past the younger kid's last photo the ribbon keeps creeping, never jumps.
        let mapping = denseRibbon(count: 40, upTo: 54)
        guard let last = mapping.lastAge else { return XCTFail("expected anchors") }
        let atLast = mapping.offset(atAge: last)
        XCTAssertEqual(mapping.offset(atAge: last + 10) - atLast, 10 * RibbonMetrics.tail, accuracy: 1e-9)
        XCTAssertEqual(mapping.offset(atAge: last + 20) - atLast, 20 * RibbonMetrics.tail, accuracy: 1e-9)
    }

    func testEmptyRibbonStillCrawls() {
        // A filter can empty a ribbon entirely; it must keep advancing so the combined
        // mapping stays invertible instead of flat-lining.
        let mapping = RibbonMapping.empty
        XCTAssertEqual(mapping.offset(atAge: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(mapping.offset(atAge: 12), 12 * RibbonMetrics.tail, accuracy: 1e-9)
        XCTAssertFalse(mapping.isSparse(atAge: 12), "empty ribbon has nothing to ghost")
    }

    func testOffsetPassesThroughPhotoCentres() {
        let placed = RibbonLayout.build(
            items: (0..<6).map { makeItem("p\($0)", ageMonths: Double($0) * 7 + 3) },
            columnWidth: Self.columnWidth
        )
        let mapping = RibbonMapping(placed: placed)
        for entry in placed {
            XCTAssertEqual(mapping.offset(atAge: entry.anchorAge), entry.center, accuracy: 1e-7)
        }
    }

    // MARK: - Sparse detection (D3 / R3)

    func testSparseWindowIsDetected() {
        let mapping = ribbonWithSparseWindow()
        XCTAssertTrue(mapping.isSparse(atAge: 36), "36mo sits inside the sparse window")
        XCTAssertFalse(mapping.isSparse(atAge: 12), "12mo is dense")
        XCTAssertFalse(mapping.isSparse(atAge: 50), "50mo is dense again")
    }

    func testSoloTailIsSparse() {
        // R6: past the younger kid's last photo the column holds and ghosts, rather than
        // going blank, while the older kid keeps flowing.
        let mapping = ribbonWithSparseWindow()   // last photo just under 54mo
        XCTAssertFalse(mapping.isSparse(atAge: 53), "still inside the photo run")
        XCTAssertTrue(mapping.isSparse(atAge: 62), "well past the last photo")
    }

    func testLeadInBeforeFirstPhotoIsSparse() {
        // Infant detection often misses the newborn stretch (R4), so a ribbon can start
        // late. That opening gap should ghost too, not present as a normal dense run.
        let mapping = RibbonMapping(placed: RibbonLayout.build(
            items: (0..<10).map { makeItem("late\($0)", ageMonths: 14 + Double($0)) },
            columnWidth: Self.columnWidth
        ))
        XCTAssertTrue(mapping.isSparse(atAge: 2), "no photos anywhere near 2mo")
        XCTAssertFalse(mapping.isSparse(atAge: 16), "inside the run")
    }

    func testSparseIsResolutionIndependent() {
        // The regression that killed the prototype's pixel threshold: the same photo
        // cadence must classify identically at any column width.
        let items = (0..<8).map { makeItem("g\($0)", ageMonths: Double($0) * 9) }  // 9-month gaps
        for width in [90.0, 160.0, 320.0, 640.0] {
            let mapping = RibbonMapping(placed: RibbonLayout.build(items: items, columnWidth: width))
            XCTAssertTrue(mapping.isSparse(atAge: 13), "width \(width) should not change the verdict")
        }
    }

    func testDensityIsPositiveEverywhereIncludingEdges() {
        // The prototype divides by a fixed 2 even when clamping shortens the window,
        // which under-reports slope at the axis ends. We divide by the true width.
        let mapping = denseRibbon(count: 100, upTo: 84)
        for age in stride(from: 0.0, through: 84.0, by: 0.5) {
            XCTAssertGreaterThan(mapping.pointsPerMonth(atAge: age, axisMax: 84), 0)
        }
    }

    // MARK: - Combined mapping (D1)

    func testCombinedRoundTripsExactly() {
        // The core D1 guarantee: scrolling to a content offset and reading back the age
        // must land where you started, or the two ribbons desynchronise.
        let a = denseRibbon(count: 180, upTo: 84, kid: .a)
        let b = ribbonWithSparseWindow()
        let combined = CombinedMapping(a: a, b: b, axisMax: 84)

        for step in 0...840 {
            let age = Double(step) / 10
            let s = combined.offset(atAge: age)
            XCTAssertEqual(combined.age(atCombinedOffset: s), age, accuracy: 1e-6,
                           "round trip failed at age \(age)")
        }
    }

    func testCombinedOffsetIsStrictlyIncreasing() {
        let combined = CombinedMapping(
            a: denseRibbon(count: 120, upTo: 84),
            b: ribbonWithSparseWindow(),
            axisMax: 84
        )
        var previous = -Double.infinity
        for step in 0...8400 {
            let value = combined.offset(atAge: Double(step) / 100)
            XCTAssertGreaterThan(value, previous)
            previous = value
        }
    }

    func testCombinedClampsOutsideAxis() {
        let combined = CombinedMapping(
            a: denseRibbon(count: 30, upTo: 60),
            b: denseRibbon(count: 30, upTo: 30, kid: .b),
            axisMax: 60
        )
        XCTAssertEqual(combined.age(atCombinedOffset: combined.sMin - 5_000), 0, accuracy: 1e-9)
        XCTAssertEqual(combined.age(atCombinedOffset: combined.sMax + 5_000), 60, accuracy: 1e-9)
        XCTAssertGreaterThan(combined.sMax, combined.sMin)
    }

    func testCombinedHandlesOneEmptyRibbon() {
        // Favorites-only filter can leave one kid with nothing.
        let combined = CombinedMapping(a: denseRibbon(count: 50, upTo: 60), b: .empty, axisMax: 60)
        for step in 0...600 {
            let age = Double(step) / 10
            XCTAssertEqual(combined.age(atCombinedOffset: combined.offset(atAge: age)), age, accuracy: 1e-6)
        }
    }

    func testConstantContentSpeedSpendsScrollWhereThePhotosAre() {
        // The point of D1: a fixed slice of scroll distance covers more *age* in a sparse
        // stretch than in a dense one. Equivalently, months-per-point is higher when sparse.
        let sparse = ribbonWithSparseWindow()
        let combined = CombinedMapping(a: sparse, b: .empty, axisMax: 84)

        let denseAge: Double = 12
        let sparseAge: Double = 36
        let delta: Double = 400  // points of scroll

        let denseSpan = combined.age(atCombinedOffset: combined.offset(atAge: denseAge) + delta) - denseAge
        let sparseSpan = combined.age(atCombinedOffset: combined.offset(atAge: sparseAge) + delta) - sparseAge

        XCTAssertGreaterThan(sparseSpan, denseSpan * 2,
                             "the same scroll should cross far more age in a sparse stretch")
    }

    // MARK: - Viewport

    func testVisibleRangeCoversReadingLineAndCulls() {
        let mapping = denseRibbon(count: 300, upTo: 84)
        let viewportHeight: Double = 800
        let age: Double = 30
        let (range, columnOffset) = mapping.visibleRange(atAge: age, viewportHeight: viewportHeight)

        XCTAssertFalse(range.isEmpty)
        XCTAssertLessThan(range.count, 60, "should cull to a small window, not the whole ribbon")

        let readingLine = viewportHeight * RibbonMetrics.readingLineFraction
        for index in range {
            let entry = mapping.placed[index]
            let y = readingLine + (entry.top - columnOffset)
            XCTAssertGreaterThan(y + entry.height, -RibbonMetrics.cullMargin - 1)
            XCTAssertLessThan(y, viewportHeight + RibbonMetrics.cullMargin + 1)
        }
        // Everything outside the range really is off-screen.
        for index in mapping.placed.indices where !range.contains(index) {
            let entry = mapping.placed[index]
            let y = readingLine + (entry.top - columnOffset)
            let onScreen = (y + entry.height) > -RibbonMetrics.cullMargin && y < (viewportHeight + RibbonMetrics.cullMargin)
            XCTAssertFalse(onScreen, "item \(index) was culled but is visible")
        }
    }

    func testVisibleRangeEmptyRibbon() {
        let (range, _) = RibbonMapping.empty.visibleRange(atAge: 10, viewportHeight: 800)
        XCTAssertTrue(range.isEmpty)
    }

    // MARK: - Rail (R11)

    func testRailIsLinearInAgeRegardlessOfDensity() {
        let scale = AgeRailScale(axisMax: 84, height: 800)
        XCTAssertEqual(scale.y(forAge: 0), AgeRailScale.padding, accuracy: 1e-9)
        XCTAssertEqual(scale.y(forAge: 84), 800 - AgeRailScale.padding, accuracy: 1e-9)
        // Equal age steps map to equal pixel steps — the rail ignores D1 entirely.
        let step1 = scale.y(forAge: 24) - scale.y(forAge: 12)
        let step2 = scale.y(forAge: 60) - scale.y(forAge: 48)
        XCTAssertEqual(step1, step2, accuracy: 1e-9)
    }

    func testRailRoundTrips() {
        let scale = AgeRailScale(axisMax: 84, height: 800)
        for age in stride(from: 0.0, through: 84.0, by: 1.0) {
            XCTAssertEqual(scale.age(forY: scale.y(forAge: age)), age, accuracy: 1e-9)
        }
    }

    func testRailYearTicks() {
        let scale = AgeRailScale(axisMax: 84, height: 800)
        XCTAssertEqual(scale.yearTicks, [0, 12, 24, 36, 48, 60, 72, 84])
    }

    // MARK: - Shared photos (R5)

    func testSharedPhotoAppearsInBothRibbonsAtEachKidsAge() {
        let capture = AgeMath.date(birthday: Self.birthday, ageMonths: 36)
        let gapMonths: Double = 30
        let olderBirthday = Self.birthday
        let youngerBirthday = AgeMath.date(birthday: Self.birthday, ageMonths: gapMonths)

        let forOlder = FeedItem(
            assetIdentifier: "shared-1", kid: .a, captureDate: capture,
            ageMonths: AgeMath.ageMonths(birthday: olderBirthday, at: capture),
            kind: .photo, aspectRatio: 0.75
        )
        let forYounger = FeedItem(
            assetIdentifier: "shared-1", kid: .b, captureDate: capture,
            ageMonths: AgeMath.ageMonths(birthday: youngerBirthday, at: capture),
            kind: .photo, aspectRatio: 0.75
        )

        XCTAssertEqual(forOlder.assetIdentifier, forYounger.assetIdentifier)
        XCTAssertNotEqual(forOlder.id, forYounger.id, "same asset, distinct ribbon identities")
        XCTAssertEqual(forOlder.ageMonths, 36, accuracy: 1e-6)
        XCTAssertEqual(forYounger.ageMonths, 6, accuracy: 1e-6)
    }
}

/// The promise R1/R2 make to the user: at any scroll position, whatever photo sits at the
/// reading line in each column shows each kid at (approximately) the same age. These tests
/// verify that at realistic iPhone dimensions rather than prototype pixel scale.
final class AgeAlignmentTests: XCTestCase {

    private let columnWidth: Double = 178      // iPhone 16 Pro, two columns beside the rail
    private let viewportHeight: Double = 874

    private func ribbon(seed: Int, count: Int, maxAge: Double, kid: Kid) -> RibbonMapping {
        var value = UInt64(seed)
        func rand() -> Double {
            value ^= value << 13; value ^= value >> 7; value ^= value << 17
            return Double(value % 1_000_000) / 1_000_000
        }
        var items: [FeedItem] = []
        var age = 0.4
        while age < maxAge && items.count < count {
            items.append(FeedItem(
                assetIdentifier: "k\(kid.rawValue)-\(items.count)", kid: kid,
                captureDate: Date(timeIntervalSinceReferenceDate: age * 2_629_746),
                ageMonths: age, kind: .photo,
                aspectRatio: rand() < 0.7 ? 0.75 : 1.333
            ))
            age += 0.4 + rand() * 2.2
        }
        return RibbonMapping(placed: RibbonLayout.build(items: items, columnWidth: columnWidth))
    }

    /// The photo occupying the reading line must be one of the two anchors bracketing the
    /// current age — never some unrelated photo further up or down the ribbon.
    func testPhotoAtReadingLineMatchesCurrentAge() {
        for (seed, kid) in [(12_345, Kid.a), (98_765, Kid.b)] {
            let mapping = ribbon(seed: seed, count: 400, maxAge: 84, kid: kid)
            let anchors = mapping.placed.map(\.anchorAge)

            for step in 10...830 {
                let age = Double(step) / 10
                let readingPosition = mapping.offset(atAge: age)

                guard let hit = mapping.placed.first(where: {
                    readingPosition >= $0.top && readingPosition < $0.bottom
                }) else { continue }   // in a gap between photos, which is legitimate

                // Which anchors bracket this age?
                let below = anchors.last { $0 <= age } ?? anchors[0]
                let above = anchors.first { $0 >= age } ?? anchors[anchors.count - 1]

                XCTAssertTrue(
                    hit.anchorAge == below || hit.anchorAge == above,
                    "at age \(age) the reading line landed on a photo aged \(hit.anchorAge), " +
                    "outside the bracketing anchors \(below)…\(above)"
                )
            }
        }
    }

    /// Both ribbons are driven by one age, so the photos at their reading lines must be
    /// close in age to each other — this is what "aligned by how old each kid was" means.
    func testBothColumnsAgreeOnAge() {
        let a = ribbon(seed: 4_242, count: 400, maxAge: 84, kid: .a)
        let b = ribbon(seed: 7_777, count: 300, maxAge: 54, kid: .b)
        let combined = CombinedMapping(a: a, b: b, axisMax: 84)

        var checked = 0
        for step in 0...500 {
            let s = combined.sMin + (combined.sMax - combined.sMin) * Double(step) / 500
            let age = combined.age(atCombinedOffset: s)

            let hitA = a.placed.first { a.offset(atAge: age) >= $0.top && a.offset(atAge: age) < $0.bottom }
            let hitB = b.placed.first { b.offset(atAge: age) >= $0.top && b.offset(atAge: age) < $0.bottom }
            guard let hitA, let hitB else { continue }
            checked += 1

            // Both are within their own bracketing gap of `age`, so they agree with each
            // other to within the larger of the two local photo spacings.
            XCTAssertEqual(hitA.anchorAge, hitB.anchorAge, accuracy: 14,
                           "columns disagreed at age \(age): A=\(hitA.anchorAge) B=\(hitB.anchorAge)")
        }
        XCTAssertGreaterThan(checked, 100, "expected most sample points to land on photos")
    }

    /// Scrolling must never move the feed backwards in age.
    func testScrollingForwardAlwaysIncreasesAge() {
        let combined = CombinedMapping(
            a: ribbon(seed: 555, count: 300, maxAge: 84, kid: .a),
            b: ribbon(seed: 666, count: 200, maxAge: 54, kid: .b),
            axisMax: 84
        )
        var previous = -Double.infinity
        for step in 0...2000 {
            let s = combined.sMin + (combined.sMax - combined.sMin) * Double(step) / 2000
            let age = combined.age(atCombinedOffset: s)
            XCTAssertGreaterThanOrEqual(age, previous - 1e-9)
            previous = age
        }
    }
}
