import Foundation
import SameAgeCore

/// Everything the app needs to know about one kid. Persisted as JSON in `UserDefaults` —
/// it is tiny, and Photos remains the source of truth for the photos themselves.
struct KidProfile: Codable, Identifiable, Equatable {
    var id: UUID
    /// Shown only in onboarding and Settings (D6: no name headers over the columns).
    var name: String
    /// R9 — prefilled from Contacts where possible, always editable.
    var birthday: Date
    /// `PHAssetCollection.localIdentifier` of the album the user picked for this kid.
    var albumLocalIdentifier: String

    init(id: UUID = UUID(), name: String, birthday: Date, albumLocalIdentifier: String) {
        self.id = id
        self.name = name
        self.birthday = birthday
        self.albumLocalIdentifier = albumLocalIdentifier
    }

    func ageMonths(at date: Date) -> Double {
        AgeMath.ageMonths(birthday: birthday, at: date)
    }
}

/// App-wide setup state.
///
/// `kids` is an array rather than a pair struct so N-person support stays open (R7); the
/// UI enforces exactly two for v1.
@MainActor
final class AppState: ObservableObject {
    @Published var kids: [KidProfile] = []
    /// Persisted on every change: relaunching with favourites-only still on is what the
    /// user expects — a filter that silently resets reads as data loss.
    @Published var filter: FilterState = .all {
        didSet { persistFilter() }
    }
    /// R10 — the age rail defaults to the left edge, movable in Settings.
    @Published var railOnLeft: Bool = true

    /// Where the feed last settled, in months. Deliberately NOT @Published: it's written
    /// on every scroll settle and nothing should re-render because of it.
    private(set) var lastAgeMonths: Double?

    var isConfigured: Bool { kids.count == 2 }

    /// The older kid is ribbon A; the axis runs to their age today.
    var older: KidProfile? { kids.min(by: { $0.birthday < $1.birthday }) }
    var younger: KidProfile? { kids.max(by: { $0.birthday < $1.birthday }) }

    var axisMaxMonths: Double {
        guard let older else { return 84 }
        return max(older.ageMonths(at: Date()), 1)
    }

    /// Assets the user hid from the app. Stored as asset identifiers, so hiding removes a
    /// shared photo from *both* ribbons at once. Photos itself is never touched.
    @Published var hiddenAssetIDs: Set<String> = []

    private let defaultsKey = "sameage.kids.v1"
    private let hiddenKey = "sameage.hidden.v1"
    private let filterKey = "sameage.filter.v1"
    private let ageKey = "sameage.lastAge.v1"

    /// Loading must happen in init, not onAppear: SwiftUI evaluates the body — and
    /// UIViewRepresentable.makeUIView, the only place the restored age is applied —
    /// before onAppear fires. Loading late meant restore silently used nil.
    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([KidProfile].self, from: data) {
            kids = decoded
        }
        if let stored = UserDefaults.standard.stringArray(forKey: hiddenKey) {
            hiddenAssetIDs = Set(stored)
        }
        if let data = UserDefaults.standard.data(forKey: filterKey),
           let decoded = try? JSONDecoder().decode(FilterState.self, from: data) {
            filter = decoded
        }
        if UserDefaults.standard.object(forKey: ageKey) != nil {
            lastAgeMonths = UserDefaults.standard.double(forKey: ageKey)
        }
    }

    /// Called from the feed's settle callback — after every scroll stop, so the position
    /// survives a memory purge without writing UserDefaults at 120 Hz mid-scroll.
    func saveAge(_ months: Double) {
        lastAgeMonths = months
        UserDefaults.standard.set(months, forKey: ageKey)
    }

    private func persistFilter() {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: filterKey)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(kids) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func hide(assetIdentifier: String) {
        hiddenAssetIDs.insert(assetIdentifier)
        UserDefaults.standard.set(Array(hiddenAssetIDs), forKey: hiddenKey)
    }

    func unhideAll() {
        hiddenAssetIDs = []
        UserDefaults.standard.set([String](), forKey: hiddenKey)
    }
}
