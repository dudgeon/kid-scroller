import Foundation
import Photos
import SameAgeCore

/// Reads the photo library through PhotoKit.
///
/// **Why albums and not People:** the spec's R4/R8 assumed the app could read iOS's People
/// detection directly. PhotoKit exposes no such API — there is no People
/// `PHAssetCollectionSubtype`, no person predicate on `PHFetchOptions`, and Apple blocks
/// the data even to private API. So the user materialises each kid's People album into a
/// normal Photos album once (Photos → the kid's People album → Select All → Add to Album),
/// and SameAge reads those user albums, which *are* fully public API. This keeps exact
/// fidelity to Apple's own face clustering with no bundled ML model.
@MainActor
final class PhotoLibraryService {

    enum AuthorizationState {
        case notDetermined, denied, limited, authorized

        var canRead: Bool { self == .authorized || self == .limited }
    }

    // MARK: - Authorization

    static var authorizationState: AuthorizationState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    /// Requests read/write access. Write is needed for exactly one thing: favouriting (R20).
    static func requestAuthorization() async -> AuthorizationState {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                Task { @MainActor in continuation.resume(returning: authorizationState) }
            }
        }
    }

    // MARK: - Albums

    struct AlbumSummary: Identifiable, Equatable {
        let id: String              // PHAssetCollection.localIdentifier
        let title: String
        let count: Int
        /// Folder path for nested albums ("Family › Kids"), nil at top level.
        let folderPath: String?
    }

    struct AlbumSection: Identifiable, Equatable {
        let title: String
        let albums: [AlbumSummary]
        var id: String { title }
    }

    /// Everything a kid's photos might live in, sectioned for the picker.
    ///
    /// Covers what PhotoKit exposes: user albums (including inside folders, walked
    /// recursively), iCloud Shared Albums, and smart albums with content. The Photos
    /// app's newer "Collections" surface (trips, pinned collections) has no public API —
    /// same story as People — so folders/shared/smart is the whole reachable set.
    static func collections() -> [AlbumSection] {
        func summary(_ album: PHAssetCollection, path: String?) -> AlbumSummary? {
            let count = PHAsset.fetchAssets(in: album, options: nil).count
            guard count > 0 else { return nil }
            return AlbumSummary(id: album.localIdentifier,
                                title: album.localizedTitle ?? "Untitled",
                                count: count,
                                folderPath: path)
        }

        // Legacy iPhoto/iTunes-synced collections. These migrate into modern libraries as
        // read-only "iPhoto Events" style albums — decades-old one-off groupings that
        // only clutter a picker meant for "which set of photos is this kid".
        let legacySynced: Set<PHAssetCollectionSubtype> = [
            .albumSyncedEvent, .albumSyncedFaces, .albumSyncedAlbum, .albumImported
        ]

        // User albums, walking folders depth-first so nested albums are reachable.
        var userAlbums: [AlbumSummary] = []
        func walk(_ collections: PHFetchResult<PHCollection>, path: String?) {
            collections.enumerateObjects { collection, _, _ in
                if let album = collection as? PHAssetCollection {
                    guard !legacySynced.contains(album.assetCollectionSubtype) else { return }
                    if let entry = summary(album, path: path) { userAlbums.append(entry) }
                } else if let folder = collection as? PHCollectionList {
                    // Smart folders are the containers Photos wraps synced events/faces
                    // in; skipping them prunes the whole legacy subtree at once.
                    guard folder.collectionListType == .folder else { return }
                    let name = folder.localizedTitle ?? "Folder"
                    walk(PHCollection.fetchCollections(in: folder, options: nil),
                         path: path.map { "\($0) › \(name)" } ?? name)
                }
            }
        }
        walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), path: nil)
        userAlbums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // iCloud Shared Albums — a common place for one-kid photo streams.
        var shared: [AlbumSummary] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            .enumerateObjects { album, _, _ in
                if let entry = summary(album, path: nil) { shared.append(entry) }
            }

        // Smart albums that make sense as a source. Library-wide and utility ones are
        // excluded: "Recents" is the entire library, which defeats the two-album model.
        let excluded: Set<PHAssetCollectionSubtype> = [
            .smartAlbumUserLibrary, .smartAlbumAllHidden, .smartAlbumRecentlyAdded
        ]
        var smart: [AlbumSummary] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            .enumerateObjects { album, _, _ in
                guard !excluded.contains(album.assetCollectionSubtype) else { return }
                if let entry = summary(album, path: nil) { smart.append(entry) }
            }

        return [
            AlbumSection(title: "My Albums", albums: userAlbums),
            AlbumSection(title: "Shared Albums", albums: shared),
            AlbumSection(title: "Smart Albums", albums: smart),
        ].filter { !$0.albums.isEmpty }
    }

    private static func collection(withIdentifier id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject
    }

    // MARK: - Indexing

    /// Enumerates one album into feed items for `kid`.
    ///
    /// Metadata only — every field read here lives on `PHAsset` itself, so this triggers no
    /// image loading and no iCloud downloads (R25 is handled in the image pipeline instead).
    /// `PHFetchResult` is lazy, so this stays cheap even against a very large album.
    nonisolated static func items(
        inAlbum albumIdentifier: String,
        kid: Kid,
        birthday: Date
    ) -> [FeedItem] {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumIdentifier], options: nil
        ).firstObject else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: collection, options: options)

        var items: [FeedItem] = []
        items.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            // No capture date means we cannot place it on the age axis at all.
            guard let created = asset.creationDate else { return }
            let age = AgeMath.ageMonths(birthday: birthday, at: created)
            // Photos taken before this kid was born are not theirs to show.
            guard age >= 0 else { return }

            let kind: MediaKind
            if asset.mediaType == .video {
                kind = .video
            } else if asset.mediaSubtypes.contains(.photoLive) {
                kind = .livePhoto      // R16: still in the feed, motion only in fullscreen
            } else {
                kind = .photo
            }

            let aspect = asset.pixelHeight > 0
                ? Double(asset.pixelWidth) / Double(asset.pixelHeight)
                : 0.75

            items.append(FeedItem(
                assetIdentifier: asset.localIdentifier,
                kid: kid,
                captureDate: created,
                ageMonths: age,
                kind: kind,
                isFavorite: asset.isFavorite,
                aspectRatio: aspect,
                location: asset.location.map {
                    LocationStub(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                }
            ))
        }
        return items
    }

    // MARK: - Write-back (R20)

    /// The only library mutation the app performs. Everything else is read-only.
    static func setFavorite(_ isFavorite: Bool, assetIdentifier: String) async throws {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else { return }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = isFavorite
        }
    }
}
