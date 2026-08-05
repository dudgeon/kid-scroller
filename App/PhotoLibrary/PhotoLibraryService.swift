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
    }

    /// Every user-created album, for the onboarding picker. Smart albums are excluded:
    /// they are system-generated and never what the user made for a kid.
    static func userAlbums() -> [AlbumSummary] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)

        var summaries: [AlbumSummary] = []
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            guard assets.count > 0 else { return }
            summaries.append(AlbumSummary(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled album",
                count: assets.count
            ))
        }
        return summaries
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
