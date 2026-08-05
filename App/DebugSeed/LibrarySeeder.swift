#if DEBUG
import UIKit
import Photos
import SameAgeCore

/// Seeds the **simulator's** photo library with two albums so the real PhotoKit path can
/// be exercised locally. DEBUG-only; never present in a TestFlight or App Store build.
///
/// This exists because the thing most likely to break is the part synthetic fixtures
/// cannot reach: assets arriving asynchronously from PhotoKit *after* the feed has already
/// rendered. That is precisely the gap that let a permanently black feed ship in 0.1 (1).
///
/// Assets are created with an explicit `creationDate` via `PHAssetCreationRequest` rather
/// than relying on EXIF written into a file — the date is then exactly what the app reads
/// back, with no dependency on how `simctl addmedia` handles metadata.
enum LibrarySeeder {

    /// Real birthdays, so the age axis under test matches the real one.
    static let birthdays: [(name: String, birthday: DateComponents, count: Int)] = [
        ("Owen",  DateComponents(year: 2013, month: 10, day: 17), 140),
        ("Alina", DateComponents(year: 2016, month: 5,  day: 27), 120)
    ]

    static func seedIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedTestLibrary") else { return }
        do {
            try await seed()
            print("[seeder] done")
        } catch {
            print("[seeder] FAILED: \(error)")
        }
    }

    private static func seed() async throws {
        let status = await PhotoLibraryService.requestAuthorization()
        guard status.canRead else { throw SeedError.notAuthorized }

        for spec in birthdays {
            if let existing = album(named: spec.name) {
                print("[seeder] reusing album \(spec.name)")
                try await deleteAssets(in: existing)
            }
            let dates = captureDates(birthday: spec.birthday, count: spec.count)
            print("[seeder] creating \(dates.count) assets for \(spec.name)")
            try await createAlbum(named: spec.name, dates: dates, tint: spec.name == "Owen" ? 0.09 : 0.58)
        }
    }

    // MARK: - Date distribution

    /// Photo cadence that looks like a real family album: a burst around birth, tapering
    /// with age, plus a deliberate multi-month drought so D3 ghosting has something to do.
    private static func captureDates(birthday: DateComponents, count: Int) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        guard let birth = calendar.date(from: birthday) else { return [] }

        let maxAge = AgeMath.ageMonths(birthday: birth, at: Date())
        var seed: UInt64 = 0x5EED_1234
        func rand() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 1_000_000) / 1_000_000
        }

        var dates: [Date] = []
        var age = 0.2
        // One drought per kid, placed differently so the two ribbons don't align.
        let droughtStart = 34.0 + rand() * 10
        let droughtEnd = droughtStart + 9

        while age < maxAge && dates.count < count {
            let inDrought = age >= droughtStart && age <= droughtEnd
            let step: Double
            if inDrought {
                step = 3.0 + rand() * 4
            } else {
                let base = age < 12 ? 0.5 : (age < 36 ? 0.9 : 1.6)
                step = base * (0.5 + rand() * 1.5)
            }
            age += step
            guard age < maxAge else { break }
            dates.append(AgeMath.date(birthday: birth, ageMonths: age))
        }
        return dates
    }

    // MARK: - PhotoKit writes (simulator library only)

    /// Kid profiles pointing at the seeded albums, with the real birthdays. Lets a test
    /// run jump straight to the feed instead of tapping through onboarding.
    static func seededKidProfiles() -> [KidProfile] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return birthdays.compactMap { spec in
            guard let collection = album(named: spec.name),
                  let birth = calendar.date(from: spec.birthday) else { return nil }
            return KidProfile(name: spec.name, birthday: birth,
                              albumLocalIdentifier: collection.localIdentifier)
        }
        .sorted { $0.birthday < $1.birthday }
    }

    static func album(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
    }

    private static func deleteAssets(in collection: PHAssetCollection) async throws {
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    private static func createAlbum(named name: String, dates: [Date], tint: CGFloat) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let albumRequest: PHAssetCollectionChangeRequest
            if let existing = album(named: name) {
                guard let request = PHAssetCollectionChangeRequest(for: existing) else { return }
                albumRequest = request
            } else {
                albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            }

            for (index, date) in dates.enumerated() {
                // Vary aspect so native-aspect layout (R14) is genuinely exercised.
                let portrait = index % 4 != 0
                let size = portrait ? CGSize(width: 300, height: 400) : CGSize(width: 400, height: 300)
                guard let data = image(size: size, tint: tint, index: index).jpegData(compressionQuality: 0.6)
                else { continue }

                let assetRequest = PHAssetCreationRequest.forAsset()
                assetRequest.addResource(with: .photo, data: data, options: nil)
                assetRequest.creationDate = date          // what the app reads back
                assetRequest.isFavorite = index % 7 == 0
                if let placeholder = assetRequest.placeholderForCreatedAsset {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            }
        }
    }

    private static func image(size: CGSize, tint: CGFloat, index: Int) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let hue = (tint + CGFloat(index % 17) * 0.012).truncatingRemainder(dividingBy: 1)
            UIColor(hue: hue, saturation: 0.55, brightness: 0.78, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let label = "\(index)" as NSString
            label.draw(at: CGPoint(x: 12, y: 12), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 40),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85)
            ])
        }
    }

    enum SeedError: Error { case notAuthorized }
}
#endif
