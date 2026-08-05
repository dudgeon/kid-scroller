import UIKit
import Photos
import AVFoundation

/// Feeds thumbnails to the ribbon cells.
///
/// R25 is handled here rather than in the index: enumerating album metadata never touches
/// iCloud, but *displaying* an asset may need to fetch it. `.opportunistic` delivery gives
/// a fast degraded frame first and the full-quality image after — so the degraded frame
/// **is** the placeholder the requirement asks for, with no separate placeholder state to
/// manage.
final class ThumbnailProvider {

    static let shared = ThumbnailProvider()

    private let manager = PHCachingImageManager()
    /// `PHAsset` lookups by local identifier, resolved lazily and kept for the session.
    /// Only ever touched from the main thread (cells are laid out there).
    private var assets: [String: PHAsset] = [:]

    private init() {
        manager.allowsCachingHighQualityImages = false
    }

    func asset(for identifier: String) -> PHAsset? {
        if let cached = assets[identifier] { return cached }
        // Synthetic fixtures have no backing asset; cache nothing and let the caller
        // fall back to its placeholder.
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else { return nil }
        assets[identifier] = asset
        return asset
    }

    private func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic     // degraded frame first, then full (R25)
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true     // allow iCloud fetch on demand
        options.isSynchronous = false
        return options
    }

    /// Requests an image. The handler may be called more than once: a degraded frame
    /// followed by the full-quality one. Returns nil when there is no such asset.
    @discardableResult
    func request(
        identifier: String,
        targetSize: CGSize,
        handler: @escaping (UIImage?, _ isDegraded: Bool) -> Void
    ) -> PHImageRequestID? {
        guard let asset = asset(for: identifier) else { return nil }
        return manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options()
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            handler(image, degraded)
        }
    }

    func cancel(_ requestID: PHImageRequestID) {
        manager.cancelImageRequest(requestID)
    }

    /// Full-quality image for fullscreen and for the share composite (R17/R19).
    /// Uses `.highQualityFormat`, so it resolves once rather than degraded-then-full.
    func requestFull(identifier: String, targetSize: CGSize? = nil) async -> UIImage? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize ?? PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // High-quality delivery can still call back twice if a degraded frame is
                // already cached; resume exactly once or the continuation traps.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Player item for in-feed video autoplay (R15). Streams rather than downloading a
    /// copy, so an iCloud-resident video costs no local storage.
    func requestPlayerItem(identifier: String) async -> AVPlayerItem? {
        guard let asset = asset(for: identifier), asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: item)
            }
        }
    }

    /// Preheats a window of assets either side of the viewport so scrolling finds images
    /// already decoded rather than requesting them mid-frame.
    func startCaching(identifiers: [String], targetSize: CGSize) {
        let assets = identifiers.compactMap { asset(for: $0) }
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize,
                                   contentMode: .aspectFill, options: options())
    }

    func stopCaching(identifiers: [String], targetSize: CGSize) {
        let assets = identifiers.compactMap { asset(for: $0) }
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: targetSize,
                                  contentMode: .aspectFill, options: options())
    }

    func stopAllCaching() {
        manager.stopCachingImagesForAllAssets()
    }
}
