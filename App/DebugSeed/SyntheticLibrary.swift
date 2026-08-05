import Foundation
import SameAgeCore

/// Deterministic stand-in for a real photo library.
///
/// Lets the feed engine be built and exercised before PhotoKit is wired up, and keeps the
/// simulator useful (a simulator has no People albums and effectively no photos). Densities
/// mirror the spec prototype: bursts in infancy, tapering with age, and a deliberate sparse
/// stretch for the younger kid so D3 ghosting and R3's crawl are visible.
enum SyntheticLibrary {

    /// Small deterministic PRNG so the same fixture appears on every launch.
    private struct Seeded {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
    }

    /// Sibling gap in months, matching the prototype's 2.5-year spread.
    static let siblingGapMonths: Double = 30
    /// Older kid's age today; the axis maximum.
    static let olderMaxAgeMonths: Double = 84

    static func makeKids() -> (older: KidProfile, younger: KidProfile) {
        let now = Date()
        let older = KidProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!,
            name: "Older",
            birthday: AgeMath.date(birthday: now, ageMonths: -olderMaxAgeMonths),
            albumLocalIdentifier: "synthetic-a"
        )
        let younger = KidProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!,
            name: "Younger",
            birthday: AgeMath.date(birthday: now, ageMonths: -(olderMaxAgeMonths - siblingGapMonths)),
            albumLocalIdentifier: "synthetic-b"
        )
        return (older, younger)
    }

    /// Builds both ribbons, including a handful of shared photos that appear in each
    /// ribbon at that kid's own age (R5).
    static func makeItems() -> (a: [FeedItem], b: [FeedItem]) {
        let (older, younger) = makeKids()
        var a = ribbon(kid: .a, birthday: older.birthday, maxAge: olderMaxAgeMonths, sparse: nil, seed: 20_260_804)
        var b = ribbon(kid: .b, birthday: younger.birthday,
                       maxAge: olderMaxAgeMonths - siblingGapMonths,
                       sparse: 30...42, seed: 99_001_177)

        // Both-kids photos: one calendar moment, two different ages (R5).
        for olderAge in [36.0, 44.0, 58.0, 70.0, 79.0] {
            let youngerAge = olderAge - siblingGapMonths
            guard youngerAge > 0, youngerAge <= olderMaxAgeMonths - siblingGapMonths else { continue }
            let moment = AgeMath.date(birthday: older.birthday, ageMonths: olderAge)
            let id = "shared-\(Int(olderAge))"
            a.append(FeedItem(assetIdentifier: id, kid: .a, captureDate: moment,
                              ageMonths: olderAge, kind: .photo, isFavorite: true, aspectRatio: 0.75))
            b.append(FeedItem(assetIdentifier: id, kid: .b, captureDate: moment,
                              ageMonths: youngerAge, kind: .photo, isFavorite: true, aspectRatio: 0.75))
        }
        return (a.sorted { $0.ageMonths < $1.ageMonths }, b.sorted { $0.ageMonths < $1.ageMonths })
    }

    private static func ribbon(
        kid: Kid, birthday: Date, maxAge: Double, sparse: ClosedRange<Double>?, seed: UInt64
    ) -> [FeedItem] {
        var rng = Seeded(seed: seed)
        var items: [FeedItem] = []
        var age = 0.4
        var index = 0

        while age < maxAge {
            let inSparse = sparse?.contains(age) ?? false
            let step: Double
            if inSparse {
                step = 6 + rng.next() * 7          // a months-long drought
            } else {
                let base = age < 12 ? 0.55 : (age < 30 ? 0.8 : 1.5)
                var s = base * (0.5 + rng.next() * 1.4)
                if rng.next() < 0.12 { s *= 3 }    // occasional lull
                step = s
            }
            age += step
            guard age < maxAge else { break }

            // Mostly portrait, some landscape and the occasional square.
            let roll = rng.next()
            let aspect: Double = roll < 0.7 ? 0.75 : (roll < 0.92 ? 1.333 : 1.0)
            let kindRoll = rng.next()
            let kind: MediaKind = kindRoll < 0.12 ? .video : (kindRoll < 0.22 ? .livePhoto : .photo)

            items.append(FeedItem(
                assetIdentifier: "syn-\(kid.rawValue)-\(index)",
                kid: kid,
                captureDate: AgeMath.date(birthday: birthday, ageMonths: age),
                ageMonths: age,
                kind: kind,
                isFavorite: rng.next() < 0.16,
                aspectRatio: aspect
            ))
            index += 1
        }
        return items
    }
}
