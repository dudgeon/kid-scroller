import Foundation
import SameAgeCore

/// Identity of what the feed is currently displaying.
///
/// `FeedUIView.configure` skips its (expensive) mapping rebuild when this value is
/// unchanged, because SwiftUI calls `updateUIView` on every age tick and rebuilding both
/// ribbons at scroll frequency is visibly janky.
///
/// That guard is only safe if the value moves whenever the *content* moves. An earlier
/// version derived it from the filter alone — which never changes while photos load
/// asynchronously — so the feed configured once with empty arrays and then ignored the
/// real data when it arrived. The result was a permanently black feed with a working age
/// rail, and no error anywhere, because nothing had actually failed.
///
/// Pure and free of UIKit so the invariant can be tested directly.
enum FeedVersion {
    static func compute(
        filter: FilterState,
        contentVersion: Int,
        axisMax: Double,
        railOnLeft: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(filter)
        hasher.combine(contentVersion)
        hasher.combine(axisMax)
        hasher.combine(railOnLeft)
        return hasher.finalize()
    }
}
