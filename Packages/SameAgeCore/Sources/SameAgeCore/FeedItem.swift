import Foundation

/// Which kid a feed item belongs to. Backed by `Int` so the pair can widen to N people
/// later (R7) without changing persisted data.
public enum Kid: Int, Codable, Sendable, CaseIterable {
    case a = 0
    case b = 1
}

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo
    case livePhoto
    case video
}

/// A location stub. PhotoKit hands back a `CLLocation`; the core stays Foundation-only
/// so it can be tested on macOS without linking CoreLocation.
public struct LocationStub: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One photo or video in one kid's ribbon.
///
/// A single asset containing both kids yields *two* `FeedItem`s — one per kid, each at
/// that kid's own age (R5). They share `assetIdentifier` but differ in `id`.
public struct FeedItem: Codable, Identifiable, Sendable, Equatable {
    /// Unique within a ribbon: `"\(assetIdentifier)#\(kid.rawValue)"`.
    public let id: String
    /// `PHAsset.localIdentifier` — the same value for both halves of a shared photo.
    public let assetIdentifier: String
    public let kid: Kid
    public let captureDate: Date
    /// Age of `kid` at `captureDate`, in months. Derived via ``AgeMath``.
    public let ageMonths: Double
    public let kind: MediaKind
    /// Mutable: favorite/unfavorite is the only library write-back (R20).
    public var isFavorite: Bool
    /// `pixelWidth / pixelHeight`. Drives native-aspect layout with no cropping (R14).
    public let aspectRatio: Double
    public let location: LocationStub?

    public init(
        assetIdentifier: String,
        kid: Kid,
        captureDate: Date,
        ageMonths: Double,
        kind: MediaKind,
        isFavorite: Bool = false,
        aspectRatio: Double,
        location: LocationStub? = nil
    ) {
        self.id = "\(assetIdentifier)#\(kid.rawValue)"
        self.assetIdentifier = assetIdentifier
        self.kid = kid
        self.captureDate = captureDate
        self.ageMonths = ageMonths
        self.kind = kind
        self.isFavorite = isFavorite
        // Guard against a zero/NaN aspect from a corrupt asset: fall back to 4:3 portrait.
        self.aspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 0.75
        self.location = location
    }
}

/// v1 filters: favorites and media type (R21). A filter only narrows each ribbon's pool;
/// density scaling absorbs the rest, so there is no pair-level logic (R22).
public struct FilterState: Codable, Sendable, Equatable, Hashable {
    public var favoritesOnly: Bool
    public var kinds: Set<MediaKind>

    public static let all = FilterState(favoritesOnly: false, kinds: Set(MediaKind.allCases))

    public init(favoritesOnly: Bool = false, kinds: Set<MediaKind> = Set(MediaKind.allCases)) {
        self.favoritesOnly = favoritesOnly
        self.kinds = kinds
    }

    public func admits(_ item: FeedItem) -> Bool {
        if favoritesOnly && !item.isFavorite { return false }
        return kinds.contains(item.kind)
    }
}
