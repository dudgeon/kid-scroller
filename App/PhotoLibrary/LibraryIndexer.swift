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

    private var observer: ChangeObserver?

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

        if a.isEmpty && b.isEmpty {
            lastError = "Neither album has photos with capture dates. Check the albums in Settings."
        } else {
            lastError = nil
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
