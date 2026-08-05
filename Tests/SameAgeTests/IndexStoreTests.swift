import XCTest
import SameAgeCore
@testable import SameAge

/// A stale index is worse than no index: it renders confidently wrong ages. These pin the
/// invalidation rules.
final class IndexStoreTests: XCTestCase {

    private func kid(name: String, birthdayMonthsAgo: Double, album: String) -> KidProfile {
        KidProfile(name: name,
                   birthday: AgeMath.date(birthday: Date(), ageMonths: -birthdayMonthsAgo),
                   albumLocalIdentifier: album)
    }

    private func snapshot(older: KidProfile, younger: KidProfile,
                          items: [FeedItem] = []) -> IndexSnapshot {
        IndexSnapshot(version: IndexSnapshot.currentVersion,
                      albumA: older.albumLocalIdentifier, albumB: younger.albumLocalIdentifier,
                      birthdayA: older.birthday, birthdayB: younger.birthday,
                      itemsA: items, itemsB: [], capturedAt: Date())
    }

    func testMatchesWhenUnchanged() {
        let older = kid(name: "A", birthdayMonthsAgo: 84, album: "alb-a")
        let younger = kid(name: "B", birthdayMonthsAgo: 54, album: "alb-b")
        XCTAssertTrue(snapshot(older: older, younger: younger).matches(older: older, younger: younger))
    }

    func testRejectsChangedAlbum() {
        let older = kid(name: "A", birthdayMonthsAgo: 84, album: "alb-a")
        let younger = kid(name: "B", birthdayMonthsAgo: 54, album: "alb-b")
        let snap = snapshot(older: older, younger: younger)

        var repicked = younger
        repicked.albumLocalIdentifier = "alb-different"
        XCTAssertFalse(snap.matches(older: older, younger: repicked))
    }

    func testRejectsChangedBirthday() {
        // Every item's position on the age axis derives from the birthday, so editing it
        // must discard the cache rather than silently shift the whole ribbon.
        let older = kid(name: "A", birthdayMonthsAgo: 84, album: "alb-a")
        let younger = kid(name: "B", birthdayMonthsAgo: 54, album: "alb-b")
        let snap = snapshot(older: older, younger: younger)

        var corrected = younger
        corrected.birthday = younger.birthday.addingTimeInterval(60 * 60 * 24 * 30)
        XCTAssertFalse(snap.matches(older: older, younger: corrected))
    }

    func testRejectsOldSchemaVersion() {
        let older = kid(name: "A", birthdayMonthsAgo: 84, album: "alb-a")
        let younger = kid(name: "B", birthdayMonthsAgo: 54, album: "alb-b")
        let stale = IndexSnapshot(version: IndexSnapshot.currentVersion - 1,
                                  albumA: older.albumLocalIdentifier, albumB: younger.albumLocalIdentifier,
                                  birthdayA: older.birthday, birthdayB: younger.birthday,
                                  itemsA: [], itemsB: [], capturedAt: Date())
        XCTAssertFalse(stale.matches(older: older, younger: younger))
    }

    func testToleratesSubSecondBirthdayJitter() {
        // Round-tripping a Date through plist loses sub-second precision; that must not
        // invalidate an otherwise-good cache.
        let older = kid(name: "A", birthdayMonthsAgo: 84, album: "alb-a")
        let younger = kid(name: "B", birthdayMonthsAgo: 54, album: "alb-b")
        let snap = snapshot(older: older, younger: younger)

        var jittered = younger
        jittered.birthday = younger.birthday.addingTimeInterval(0.4)
        XCTAssertTrue(snap.matches(older: older, younger: jittered))
    }

    func testFileStoreRoundTrips() {
        let store = FileIndexStore(filename: "index-test-\(UUID().uuidString).plist")
        defer { store.clear() }

        let older = kid(name: "A", birthdayMonthsAgo: 84, album: "alb-a")
        let younger = kid(name: "B", birthdayMonthsAgo: 54, album: "alb-b")
        let item = FeedItem(assetIdentifier: "asset-1", kid: .a, captureDate: Date(),
                            ageMonths: 12.5, kind: .video, isFavorite: true, aspectRatio: 1.5)

        XCTAssertNil(store.load())
        store.save(snapshot(older: older, younger: younger, items: [item]))

        let loaded = store.load()
        XCTAssertEqual(loaded?.itemsA.count, 1)
        XCTAssertEqual(loaded?.itemsA.first?.assetIdentifier, "asset-1")
        XCTAssertEqual(loaded?.itemsA.first?.ageMonths ?? 0, 12.5, accuracy: 1e-6)
        XCTAssertEqual(loaded?.itemsA.first?.kind, .video)
        XCTAssertEqual(loaded?.itemsA.first?.isFavorite, true)
        XCTAssertTrue(loaded?.matches(older: older, younger: younger) ?? false)

        store.clear()
        XCTAssertNil(store.load())
    }
}
