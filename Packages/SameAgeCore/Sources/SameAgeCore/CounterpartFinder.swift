import Foundation

/// Finds the other kid's age-matched photo (R18).
///
/// "Matched" means nearest on the age axis, not nearest in time — that is the whole point
/// of the app. There is deliberately no tolerance window: the spec dropped the tolerance
/// slider (R13), and always showing *something* is better than an empty inset, since the
/// age label on the inset already tells the user how close the match is.
public enum CounterpartFinder {

    /// Nearest item by age in an array already sorted ascending by `ageMonths`.
    /// O(log n). Returns nil only for an empty ribbon.
    public static func nearest(toAge age: Double, in items: [FeedItem]) -> FeedItem? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items[0] }

        // First index whose age is >= the target.
        var lo = 0
        var hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].ageMonths < age { lo = mid + 1 } else { hi = mid }
        }

        if lo == 0 { return items[0] }
        if lo == items.count { return items[items.count - 1] }

        let after = items[lo]
        let before = items[lo - 1]
        return (age - before.ageMonths) <= (after.ageMonths - age) ? before : after
    }

    /// How far off the match is, in months. Lets the UI be honest when the nearest
    /// counterpart is nowhere near — e.g. inside a drought or past the younger kid's
    /// last photo (R6).
    public static func gap(fromAge age: Double, to item: FeedItem?) -> Double? {
        guard let item else { return nil }
        return abs(item.ageMonths - age)
    }
}
