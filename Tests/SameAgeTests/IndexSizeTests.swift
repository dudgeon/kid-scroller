import XCTest
import SameAgeCore
@testable import SameAge

/// The index is the only thing SameAge writes to disk. This measures it, so a future
/// change that fattens `FeedItem` shows up as a failing test rather than as silent
/// storage growth on someone's phone.
final class IndexSizeTests: XCTestCase {

    /// Realistic identifiers: PhotoKit local identifiers look like
    /// "B84E8479-475C-4727-A4A4-B77AA9980899/L0/001".
    private func items(_ count: Int, kid: Kid) -> [FeedItem] {
        let now = Date()
        var result: [FeedItem] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let suffix = String(format: "%03d", index % 1000)
            let identifier = UUID().uuidString + "/L0/" + suffix
            let kind: MediaKind = (index % 8 == 0) ? .video : .photo
            let aspect: Double = (index % 3 == 0) ? 1.333 : 0.75
            let location: LocationStub? = (index % 4 == 0)
                ? LocationStub(latitude: 38.98, longitude: -77.08)
                : nil
            let captured = now.addingTimeInterval(-Double(index) * 3600)

            result.append(FeedItem(
                assetIdentifier: identifier,
                kid: kid,
                captureDate: captured,
                ageMonths: Double(index) * 0.004,
                kind: kind,
                isFavorite: index % 6 == 0,
                aspectRatio: aspect,
                location: location
            ))
        }
        return result
    }

    private func encodedBytes(itemsA: [FeedItem], itemsB: [FeedItem]) throws -> Int {
        let snapshot = IndexSnapshot(
            version: IndexSnapshot.currentVersion,
            albumA: "alb-a", albumB: "alb-b",
            birthdayA: Date(), birthdayB: Date(),
            itemsA: itemsA, itemsB: itemsB, capturedAt: Date()
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(snapshot).count
    }

    func testIndexStaysSmallForALargePair() throws {
        let bytes = try encodedBytes(itemsA: items(10_000, kid: .a), itemsB: items(10_000, kid: .b))
        let perItem = Double(bytes) / 20_000
        print("INDEX SIZE: 20,000 items = \(bytes) bytes (\(String(format: "%.1f", Double(bytes) / 1_048_576)) MB), \(String(format: "%.0f", perItem)) bytes/item")

        // A 20k-photo pair must stay well under 10 MB — three orders of magnitude below
        // the photos themselves, which are never copied.
        XCTAssertLessThan(bytes, 10 * 1_048_576, "index grew beyond 10 MB for 20k items")
    }

    func testIndexScalesLinearly() throws {
        let small = try encodedBytes(itemsA: items(1_000, kid: .a), itemsB: [])
        let large = try encodedBytes(itemsA: items(10_000, kid: .a), itemsB: [])
        // Guards against anything super-linear sneaking into the encoding.
        XCTAssertLessThan(Double(large), Double(small) * 12)
    }

    func testSnapshotStoresNoImageData() throws {
        // The structural guarantee behind "we never duplicate photos": the encoded index
        // contains identifiers and numbers only. If image bytes ever leaked in, a single
        // item would blow past this bound on its own.
        let bytes = try encodedBytes(itemsA: items(1, kid: .a), itemsB: [])
        XCTAssertLessThan(bytes, 1_024, "a one-item index should be well under 1 KB")
    }
}
