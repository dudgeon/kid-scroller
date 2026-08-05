import Foundation

/// Layout constants, carried over from the spec prototype (px → points).
public enum RibbonMetrics {
    /// Vertical gap between consecutive photos in a ribbon.
    public static let gap: Double = 6
    /// Points per month in the lead-in before a ribbon's first photo and the tail after
    /// its last. This is what makes R3's slow crawl and R6's solo tail fall out for free.
    public static let tail: Double = 5
    /// Reading line as a fraction of viewport height (prototype's `cy`).
    public static let readingLineFraction: Double = 0.42
    /// A gap this long (months) between neighbouring photos makes a column "sparse":
    /// it holds its last photo, ghosted, and crawls (D3 / R3).
    ///
    /// The prototype used a pixel threshold (`pointsPerMonth < 16`), which does **not**
    /// survive the port: it was tuned to 136px columns holding 70–165px photos, whereas
    /// a real iPhone ribbon is ~180pt wide with ~240pt photos. The same 6-month drought
    /// that ghosts in the prototype yields ~34 pt/month on device and never trips a fixed
    /// pixel threshold. Expressing the rule in months makes it resolution-independent and
    /// says what the requirement actually means: "no new photos near this age."
    public static let sparseGapMonths: Double = 4
    /// Culling margin either side of the viewport.
    public static let cullMargin: Double = 40
}

/// A feed item with its resolved position in a ribbon's coordinate space.
public struct PlacedItem: Sendable, Equatable {
    public let item: FeedItem
    /// Age used for mapping. Equals `item.ageMonths` except where duplicate ages were
    /// nudged apart to keep the axis strictly increasing.
    public let anchorAge: Double
    public let top: Double
    public let height: Double

    public var center: Double { top + height / 2 }
    public var bottom: Double { top + height }
}

/// Builds a ribbon's cumulative layout. Port of the prototype's `layout()`.
public enum RibbonLayout {
    /// Smallest age separation we allow between consecutive anchors, in months.
    /// Prevents a divide-by-zero in the piecewise-linear interpolation when two photos
    /// share a capture instant (burst shots, or a shared photo counted twice).
    static let minimumAgeSeparation: Double = 1e-6

    /// - Parameters:
    ///   - items: any order; sorted by age internally.
    ///   - columnWidth: ribbon width in points. Heights come from native aspect (R14).
    public static func build(items: [FeedItem], columnWidth: Double) -> [PlacedItem] {
        guard !items.isEmpty, columnWidth > 0 else { return [] }

        let sorted = items.sorted { lhs, rhs in
            lhs.ageMonths == rhs.ageMonths ? lhs.id < rhs.id : lhs.ageMonths < rhs.ageMonths
        }

        var placed: [PlacedItem] = []
        placed.reserveCapacity(sorted.count)

        // Lead-in so that offset(at: 0) lands just above the first photo's centre.
        var offset = RibbonMetrics.tail * sorted[0].ageMonths
        var previousAnchor = -Double.infinity

        for item in sorted {
            // Keep anchors strictly increasing so interpolation never divides by zero.
            let anchor = max(item.ageMonths, previousAnchor + Self.minimumAgeSeparation)
            previousAnchor = anchor

            let height = columnWidth / item.aspectRatio
            placed.append(PlacedItem(item: item, anchorAge: anchor, top: offset, height: height))
            offset += height + RibbonMetrics.gap
        }
        return placed
    }
}

/// Monotonic age ↔ pixel-offset mapping for one ribbon.
///
/// Port of the prototype's `offsetAt()`. The mapping is piecewise-linear through photo
/// centres, with slope ``RibbonMetrics/tail`` outside the first and last anchors. It is
/// strictly increasing, which is what lets ``CombinedMapping`` invert the sum exactly.
public struct RibbonMapping: Sendable {
    public let placed: [PlacedItem]
    private let anchors: [Double]   // strictly increasing
    private let centers: [Double]   // strictly increasing

    public init(placed: [PlacedItem]) {
        self.placed = placed
        self.anchors = placed.map(\.anchorAge)
        self.centers = placed.map(\.center)
    }

    public static let empty = RibbonMapping(placed: [])

    public var isEmpty: Bool { placed.isEmpty }
    public var firstAge: Double? { anchors.first }
    public var lastAge: Double? { anchors.last }

    /// Pixel offset of the reading position at `age`.
    public func offset(atAge age: Double) -> Double {
        guard let firstAnchor = anchors.first, let lastAnchor = anchors.last else {
            // No photos at all: pure linear crawl, so an empty ribbon still scrolls in
            // lockstep with its sibling rather than pinning the combined mapping.
            return RibbonMetrics.tail * age
        }
        if age <= firstAnchor {
            return centers[0] - (firstAnchor - age) * RibbonMetrics.tail
        }
        if age >= lastAnchor {
            return centers[centers.count - 1] + (age - lastAnchor) * RibbonMetrics.tail
        }
        let lo = Self.bracket(anchors, age)
        let hi = lo + 1
        let t = (age - anchors[lo]) / (anchors[hi] - anchors[lo])
        return centers[lo] + (centers[hi] - centers[lo]) * t
    }

    /// Local density in points per month, smoothed over roughly ±1 month.
    ///
    /// Deviates from the prototype in one place: the prototype always divides by 2 even
    /// when clamping shortens the window, which under-reports slope at the axis ends and
    /// spuriously marks them sparse. Dividing by the true window width is identical
    /// mid-timeline and correct at the edges.
    public func pointsPerMonth(atAge age: Double, axisMax: Double) -> Double {
        let hi = min(age + 1, axisMax)
        let lo = max(age - 1, 0)
        let width = hi - lo
        guard width > 0 else { return RibbonMetrics.tail }
        return (offset(atAge: hi) - offset(atAge: lo)) / width
    }

    /// Whether this column should ghost its held photo at `age` (D3 / R3).
    ///
    /// True when the nearest photos on either side of `age` are more than
    /// `gapMonths` apart — including the lead-in before the first photo and the tail
    /// after the last, which is what produces R6's solo-tail ghosting for the younger kid.
    /// An empty ribbon is never sparse: it has no held photo to ghost.
    public func isSparse(atAge age: Double, gapMonths: Double = RibbonMetrics.sparseGapMonths) -> Bool {
        guard let firstAnchor = anchors.first, let lastAnchor = anchors.last else { return false }
        if age <= firstAnchor { return (firstAnchor - age) > gapMonths }
        if age >= lastAnchor { return (age - lastAnchor) > gapMonths }
        let lo = Self.bracket(anchors, age)
        return (anchors[lo + 1] - anchors[lo]) > gapMonths
    }

    /// Index range of items intersecting the viewport at `age`, plus the column offset to
    /// position them against. D2 is locked to newborn-at-top, so y grows downward with age.
    ///
    /// `y(item) = readingLine + (item.top - columnOffset)`
    public func visibleRange(atAge age: Double, viewportHeight: Double) -> (range: Range<Int>, columnOffset: Double) {
        let columnOffset = offset(atAge: age)
        guard !placed.isEmpty else { return (0..<0, columnOffset) }

        let readingLine = viewportHeight * RibbonMetrics.readingLineFraction
        // Visible when: y + height >= -margin  and  y <= viewportHeight + margin
        let minTop = columnOffset - readingLine - RibbonMetrics.cullMargin
        let maxTop = columnOffset - readingLine + viewportHeight + RibbonMetrics.cullMargin

        var start = 0
        var end = placed.count
        // First item whose bottom clears the top edge.
        var lo = 0, hi = placed.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if placed[mid].bottom < minTop { lo = mid + 1 } else { hi = mid }
        }
        start = lo
        // First item that starts past the bottom edge.
        lo = start; hi = placed.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if placed[mid].top <= maxTop { lo = mid + 1 } else { hi = mid }
        }
        end = lo
        return (start..<max(start, end), columnOffset)
    }

    /// Largest index `i` with `values[i] <= x`, assuming `values` is strictly increasing
    /// and `values.first < x < values.last`. Returns an index in `0..<count-1`.
    static func bracket(_ values: [Double], _ x: Double) -> Int {
        var lo = 0
        var hi = values.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if values[mid] <= x { lo = mid } else { hi = mid }
        }
        return lo
    }
}

/// The combined mapping that drives D1 "constant content speed".
///
/// `s(age) = ribbonA.offset(age) + ribbonB.offset(age)` — the total content traversed by
/// both ribbons. Scroll distance tracks `s`, not age, so photos flow at an even rate and
/// age varies. Because both ribbons are strictly increasing piecewise-linear functions of
/// age, so is `s`, and it can be inverted exactly.
///
/// This replaces the prototype's 0.25-month sampled lookup table with an exact inverse
/// over the merged breakpoint set — same shape, no sampling error, so round-trip
/// `age → s → age` is stable to floating-point precision.
public struct CombinedMapping: Sendable {
    public let a: RibbonMapping
    public let b: RibbonMapping
    public let axisMax: Double

    /// Merged, strictly increasing age breakpoints spanning `[0, axisMax]`.
    private let breakpoints: [Double]
    /// `s` evaluated at each breakpoint; strictly increasing in lockstep.
    private let sValues: [Double]

    /// - Parameter axisMax: the older kid's age today, in months. The axis never exceeds it.
    public init(a: RibbonMapping, b: RibbonMapping, axisMax: Double) {
        self.a = a
        self.b = b
        let safeMax = max(axisMax, 0)
        self.axisMax = safeMax

        var ages: [Double] = [0, safeMax]
        for anchor in a.placed.map(\.anchorAge) where anchor > 0 && anchor < safeMax { ages.append(anchor) }
        for anchor in b.placed.map(\.anchorAge) where anchor > 0 && anchor < safeMax { ages.append(anchor) }
        ages.sort()

        // Deduplicate; ties would flatten a segment and break the inverse.
        var merged: [Double] = []
        merged.reserveCapacity(ages.count)
        for age in ages where merged.last.map({ age - $0 > RibbonLayout.minimumAgeSeparation / 2 }) ?? true {
            merged.append(age)
        }
        self.breakpoints = merged
        self.sValues = merged.map { a.offset(atAge: $0) + b.offset(atAge: $0) }
    }

    /// Combined content offset at `age`. Monotonically increasing.
    public func offset(atAge age: Double) -> Double {
        let clamped = min(max(age, 0), axisMax)
        return a.offset(atAge: clamped) + b.offset(atAge: clamped)
    }

    /// Total scrollable content extent — becomes the driver scroll view's `contentSize`.
    public var sMax: Double { sValues.last ?? 0 }
    public var sMin: Double { sValues.first ?? 0 }

    /// Exact inverse of ``offset(atAge:)``, clamped to `[0, axisMax]`.
    public func age(atCombinedOffset s: Double) -> Double {
        guard breakpoints.count > 1 else { return 0 }
        if s <= sValues[0] { return breakpoints[0] }
        if s >= sValues[sValues.count - 1] { return breakpoints[breakpoints.count - 1] }
        let lo = RibbonMapping.bracket(sValues, s)
        let hi = lo + 1
        let span = sValues[hi] - sValues[lo]
        guard span > 0 else { return breakpoints[lo] }
        let t = (s - sValues[lo]) / span
        return breakpoints[lo] + (breakpoints[hi] - breakpoints[lo]) * t
    }
}

/// The age rail scrubs **linearly in age**, independent of D1's feed mapping (R11).
public struct AgeRailScale: Sendable {
    public static let padding: Double = 14

    public let axisMax: Double
    public let height: Double

    public init(axisMax: Double, height: Double) {
        self.axisMax = max(axisMax, 0)
        self.height = height
    }

    private var track: Double { max(height - 2 * Self.padding, 1) }

    /// y position for an age. D2 locked: newborn at top, growing downward.
    public func y(forAge age: Double) -> Double {
        guard axisMax > 0 else { return Self.padding }
        let t = min(max(age / axisMax, 0), 1)
        return Self.padding + t * track
    }

    public func age(forY y: Double) -> Double {
        guard axisMax > 0 else { return 0 }
        let t = (y - Self.padding) / track
        return min(max(t, 0), 1) * axisMax
    }

    /// Whole-year tick ages from 0 up to and including the last full year (D5).
    public var yearTicks: [Double] {
        guard axisMax > 0 else { return [0] }
        return stride(from: 0.0, through: axisMax, by: 12.0).map { $0 }
    }
}
