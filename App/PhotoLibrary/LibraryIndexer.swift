import Foundation
import Photos
import SameAgeCore

/// Builds and refreshes the who-appears-when index.
///
/// Under the album-based person model (Decision 1a) this collapses to enumerating two
/// user albums' *metadata* — no image I/O, no ML — so even a large album indexes in
/// seconds. R24's "usable immediately, refines as it completes" therefore falls out
/// naturally: the first pass is fast enough that there is no long partial state.
@MainActor
final class LibraryIndexer: ObservableObject {

    @Published private(set) var itemsA: [FeedItem] = []
    @Published private(set) var itemsB: [FeedItem] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var lastError: String?
    /// True once real data has landed, whether from cache or a fresh enumeration.
    @Published private(set) var hasContent = false
    /// Increments every time the item arrays are replaced.
    ///
    /// The feed's UIKit bridge skips reconfiguration when its version is unchanged, so
    /// that version has to move whenever the *content* moves. Deriving it from the filter
    /// alone silently strands the feed on the empty arrays it was first rendered with.
    @Published private(set) var generation = 0

    private var observer: ChangeObserver?
    private let store: IndexStoring

    init(store: IndexStoring = FileIndexStore()) {
        self.store = store
    }

    /// Launch path (R24): show the cached snapshot immediately, then re-enumerate in the
    /// background and swap. The user never waits on PhotoKit to see their feed.
    func start(kids: [KidProfile]) async {
        guard kids.count == 2 else { return }
        let older = kids.min(by: { $0.birthday < $1.birthday })!
        let younger = kids.max(by: { $0.birthday < $1.birthday })!

        if let snapshot = store.load(), snapshot.matches(older: older, younger: younger) {
            itemsA = snapshot.itemsA
            itemsB = snapshot.itemsB
            hasContent = !(snapshot.itemsA.isEmpty && snapshot.itemsB.isEmpty)
            generation += 1
        }
        await refresh(kids: kids)
        startObserving(kids: kids)
    }

    /// Discards the cache. Called when albums or birthdays change, since either invalidates
    /// every item's position on the age axis.
    func invalidateCache() {
        store.clear()
    }

    /// Re-reads both albums. Cheap enough to call on every foreground.
    func refresh(kids: [KidProfile]) async {
        guard kids.count == 2 else { return }
        let older = kids.min(by: { $0.birthday < $1.birthday })!
        let younger = kids.max(by: { $0.birthday < $1.birthday })!

        isIndexing = true
        defer { isIndexing = false }

        // Enumeration touches PhotoKit but loads no images; keep it off the main actor
        // so a large album cannot stutter the feed.
        let a = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.items(inAlbum: older.albumLocalIdentifier, kid: .a, birthday: older.birthday)
        }.value
        let b = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.items(inAlbum: younger.albumLocalIdentifier, kid: .b, birthday: younger.birthday)
        }.value

        itemsA = a
        itemsB = b
        hasContent = !(a.isEmpty && b.isEmpty)
        generation += 1

        if a.isEmpty && b.isEmpty {
            lastError = "Neither album has photos with capture dates. Check the albums in Settings."
            // Don't cache an empty result — a transient permission or fetch failure would
            // otherwise persist as an apparently-empty library across launches.
            store.clear()
        } else {
            lastError = nil
            store.save(IndexSnapshot(
                version: IndexSnapshot.currentVersion,
                albumA: older.albumLocalIdentifier,
                albumB: younger.albumLocalIdentifier,
                birthdayA: older.birthday,
                birthdayB: younger.birthday,
                itemsA: a, itemsB: b,
                capturedAt: Date()
            ))
        }
    }

    /// Watches the library so photos added to either album show up without a relaunch.
    func startObserving(kids: [KidProfile]) {
        guard observer == nil else { return }
        let observer = ChangeObserver { [weak self] in
            Task { @MainActor in await self?.refresh(kids: kids) }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    /// Applies a favourite toggle locally first so the UI responds immediately, then
    /// writes it back to the library (R20 — the only write the app performs).
    func setFavorite(_ isFavorite: Bool, itemID: String, assetIdentifier: String) async {
        func apply(_ items: inout [FeedItem]) {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[index].isFavorite = isFavorite
        }
        apply(&itemsA)
        apply(&itemsB)

        do {
            try await PhotoLibraryService.setFavorite(isFavorite, assetIdentifier: assetIdentifier)
        } catch {
            // Roll back so the UI never claims a write that did not land.
            apply(&itemsA)
            apply(&itemsB)
            lastError = "Couldn't update the favourite in Photos."
        }
    }

    /// `PHPhotoLibraryChangeObserver` must be an NSObject; this keeps that requirement
    /// out of the indexer's own type.
    private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
        private let onChange: () -> Void
        init(onChange: @escaping () -> Void) { self.onChange = onChange }
        func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
    }
}
