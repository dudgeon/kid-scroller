import Foundation
import SameAgeCore

/// A persisted snapshot of both ribbons (R24).
///
/// Photos is always the source of truth; this is a **disposable cache** whose only job is
/// to put something on screen before re-enumeration finishes. That is why it is a plain
/// Codable file rather than SwiftData or Core Data — there is no relational query, no
/// partial mutation, and a total rebuild costs seconds. Anything heavier would be
/// machinery without a purpose.
struct IndexSnapshot: Codable {
    /// Bump when `FeedItem`'s shape changes; a mismatch discards rather than migrates.
    static let currentVersion = 1

    let version: Int
    let albumA: String
    let albumB: String
    let birthdayA: Date
    let birthdayB: Date
    let itemsA: [FeedItem]
    let itemsB: [FeedItem]
    let capturedAt: Date

    /// A snapshot is only usable for the same albums *and* the same birthdays — editing a
    /// birthday changes every item's position on the age axis, so the cache must be dropped.
    func matches(older: KidProfile, younger: KidProfile) -> Bool {
        version == Self.currentVersion
            && albumA == older.albumLocalIdentifier
            && albumB == younger.albumLocalIdentifier
            && abs(birthdayA.timeIntervalSince(older.birthday)) < 1
            && abs(birthdayB.timeIntervalSince(younger.birthday)) < 1
    }
}

protocol IndexStoring: Sendable {
    func load() -> IndexSnapshot?
    func save(_ snapshot: IndexSnapshot)
    func clear()
}

/// Binary-plist snapshot in Application Support. Roughly 100 bytes per item, so even a
/// 20k-photo pair lands a few megabytes and loads in well under a tenth of a second.
///
/// `IndexStoring` is a protocol so this can be swapped for GRDB/SQLite if per-row
/// incremental writes ever matter — they do not under the album model, where a refresh
/// rewrites everything anyway.
final class FileIndexStore: IndexStoring, @unchecked Sendable {

    private let url: URL

    init(filename: String = "index-v1.plist") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent(filename)
    }

    func load() -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A corrupt or outdated cache must never be fatal — the library can always rebuild it.
        return try? PropertyListDecoder().decode(IndexSnapshot.self, from: data)
    }

    func save(_ snapshot: IndexSnapshot) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
