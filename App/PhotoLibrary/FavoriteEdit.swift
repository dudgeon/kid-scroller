import Foundation
import SameAgeCore

/// Applying a favourite change to the in-memory ribbons (R20).
///
/// Pure and separate from `LibraryIndexer` because the interesting part is the *rollback*,
/// and rollback is exactly the path that never runs in normal use — so it has to be
/// testable directly. The first version of this silently did nothing: it "rolled back" by
/// re-applying the value it had just written, leaving the UI claiming a write that had in
/// fact failed.
enum FavoriteEdit {

    /// The favourite state currently recorded for `itemID`, or nil if it isn't present.
    /// Captured *before* an optimistic write so a failure can restore it.
    static func currentValue(itemID: String, in items: [FeedItem]) -> Bool? {
        items.first { $0.id == itemID }?.isFavorite
    }

    /// Returns `items` with `itemID`'s favourite state set to `isFavorite`.
    /// Unchanged if the item isn't in this ribbon — a photo of both kids lives in both,
    /// under different ids, so callers apply to each ribbon independently.
    static func applying(_ isFavorite: Bool, itemID: String, to items: [FeedItem]) -> [FeedItem] {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return items }
        var updated = items
        updated[index].isFavorite = isFavorite
        return updated
    }

    /// Both halves of a shared asset, so favouriting from either ribbon updates the other.
    /// PhotoKit favourites the *asset*, so the two ribbon entries must not disagree.
    static func applyingToAsset(
        _ isFavorite: Bool, assetIdentifier: String, to items: [FeedItem]
    ) -> [FeedItem] {
        items.map { item in
            guard item.assetIdentifier == assetIdentifier else { return item }
            var updated = item
            updated.isFavorite = isFavorite
            return updated
        }
    }
}
