import SwiftUI
import CoreLocation
import SameAgeCore

/// Fullscreen photo with metadata and the age-matched counterpart (R17–R19, D7).
///
/// Swiping pages through the tapped kid's ribbon in age order, and the inset re-resolves
/// to whatever the *other* kid's nearest photo by age is — so the pair stays age-matched
/// exactly as it does in the feed, rather than the inset freezing on the photo you
/// happened to open.
struct FullscreenView: View {
    let items: [FeedItem]
    let counterpartItems: [FeedItem]
    let startID: String
    let name: (Kid) -> String
    let onToggleFavorite: (FeedItem) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Which photo is on screen, by id. Driven by `scrollPosition`, which pairs with
    /// `LazyHStack` so only the visible pages are ever built — a paged `TabView` would
    /// materialise all of them, which is fine for a fixture and ruinous for a real album.
    @State private var currentID: String?
    /// D7: the inset sits bottom-right; tapping it swaps which photo is large.
    @State private var swapped = false
    @State private var images: [String: UIImage] = [:]
    @State private var fullyLoaded: Set<String> = []
    /// Favourite changes made in this session, keyed by item id — the `items` array is a
    /// snapshot and won't reflect them.
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var placeName: String?
    @State private var shareItems: [Any]?
    @State private var isPreparingShare = false

    init(items: [FeedItem], counterpartItems: [FeedItem], startID: String,
         name: @escaping (Kid) -> String,
         onToggleFavorite: @escaping (FeedItem) -> Void) {
        self.items = items
        self.counterpartItems = counterpartItems
        self.startID = startID
        self.name = name
        self.onToggleFavorite = onToggleFavorite
        _currentID = State(initialValue: startID)
    }

    // MARK: - Derived state

    private var index: Int {
        items.firstIndex { $0.id == currentID } ?? 0
    }

    private var current: FeedItem? {
        items.first { $0.id == currentID } ?? items.first
    }

    private func counterpart(for item: FeedItem) -> FeedItem? {
        CounterpartFinder.nearest(toAge: item.ageMonths, in: counterpartItems)
    }

    private var large: FeedItem? {
        guard let current else { return nil }
        return swapped ? counterpart(for: current) : current
    }

    private var small: FeedItem? {
        guard let current else { return nil }
        return swapped ? current : counterpart(for: current)
    }

    private func isFavorite(_ item: FeedItem) -> Bool {
        favoriteOverrides[item.id] ?? item.isFavorite
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Vertical, matching the feed: the age axis runs downward everywhere in this
            // app, so paging down should mean "older" here too. Horizontal paging would
            // have put the app's one spatial metaphor at right angles to itself.
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        page(for: swapped ? (counterpart(for: item) ?? item) : item,
                             isActive: item.id == currentID)
                            .containerRelativeFrame(.vertical)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                HStack(alignment: .bottom) {
                    metadata
                    Spacer()
                    if let small { inset(for: small) }
                }
                .padding(16)
            }
        }
        .onAppear { loadAroundCurrent() }
        .onChange(of: currentID) { _, _ in
            placeName = nil
            loadAroundCurrent()
            Task { await resolvePlaceName() }
        }
        .task { await resolvePlaceName() }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let shareItems { ShareSheet(items: shareItems) }
        }
        .statusBarHidden()
    }

    // MARK: - Pieces

    @ViewBuilder
    private func page(for item: FeedItem, isActive: Bool) -> some View {
        Group {
            if item.kind == .video {
                // Fullscreen previously only ever requested a still, so opening a video
                // showed its poster frame and never played.
                FullscreenVideoPage(item: item, isActive: isActive, poster: images[item.id])
            } else if let image = images[item.id] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every control here gets a full 44pt hit area — an icon-sized target over a photo
    /// is exactly the "dismiss is harder than it should be" complaint.
    private func chromeButton(_ systemName: String, tint: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
                .contentShape(Circle())
        }
    }

    private var topBar: some View {
        HStack {
            chromeButton("xmark") { dismiss() }
            Spacer()
            if !items.isEmpty {
                Text("\(index + 1) of \(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if let current {
                chromeButton(isFavorite(current) ? "heart.fill" : "heart",
                             tint: isFavorite(current) ? .red : .white) {
                    let next = !isFavorite(current)
                    favoriteOverrides[current.id] = next
                    var updated = current
                    updated.isFavorite = next
                    onToggleFavorite(updated)          // R20 — the only library write
                }
            }
            Group {
                if isPreparingShare {
                    ProgressView().tint(.white).frame(width: 44, height: 44)
                } else {
                    chromeButton("square.and.arrow.up") { Task { await prepareShare() } }
                }
            }
            .disabled(small == nil || isPreparingShare)
            .padding(.leading, 4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var metadata: some View {
        if let large {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(name(large.kid)) · \(AgeFormatter.short(months: large.ageMonths))")
                    .font(.headline)
                Text(large.captureDate.formatted(date: .abbreviated, time: .omitted)
                     + (placeName.map { " · \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .shadow(radius: 6)
        }
    }

    private func inset(for item: FeedItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = images[item.id] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                }
            }
            .frame(width: 96, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: 2))

            Text("\(name(item.kid)) · \(AgeFormatter.short(months: item.ageMonths))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                .padding(5)
        }
        .shadow(radius: 10)
        .onTapGesture { withAnimation(.snappy) { swapped.toggle() } }
        .accessibilityLabel("Show \(name(item.kid)) full screen")
    }

    // MARK: - Loading

    /// Loads the current photo and its immediate neighbours, so a swipe lands on an image
    /// that is already there rather than on a spinner.
    private func loadAroundCurrent() {
        var wanted: [FeedItem] = []
        for offset in (index - 1)...(index + 1) where items.indices.contains(offset) {
            let item = items[offset]
            wanted.append(item)
            if let partner = counterpart(for: item) { wanted.append(partner) }
        }
        for item in wanted where !fullyLoaded.contains(item.id) {
            load(item)
        }
    }

    /// `.opportunistic` delivery calls back first with a fast low-resolution frame — often
    /// already cached by the feed — and again at full quality. Showing the degraded frame
    /// immediately is what removes the black screen while a large or iCloud-resident photo
    /// loads.
    private func load(_ item: FeedItem) {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        ThumbnailProvider.shared.request(
            identifier: item.assetIdentifier,
            targetSize: target,
            contentMode: .aspectFit,      // show the whole photo, don't crop
            quality: .high                // the viewer is looking at this one
        ) { image, isDegraded in
            guard let image else { return }
            // Callbacks can arrive out of order; never let a late low-resolution frame
            // replace one that is already full quality.
            if isDegraded && fullyLoaded.contains(item.id) { return }
            images[item.id] = image
            if !isDegraded { fullyLoaded.insert(item.id) }
        }
    }

    /// R17 — show a place name rather than raw coordinates when one is available.
    private func resolvePlaceName() async {
        guard let location = large?.location else { return }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: location.latitude, longitude: location.longitude)
        )
        placeName = placemarks?.first.flatMap { $0.name ?? $0.locality ?? $0.administrativeArea }
    }

    /// R19 — a side-by-side composite of the matched pair, both ages labelled.
    private func prepareShare() async {
        guard let current, let partner = counterpart(for: current) else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        async let first = ThumbnailProvider.shared.requestFull(identifier: current.assetIdentifier)
        async let second = ThumbnailProvider.shared.requestFull(identifier: partner.assetIdentifier)
        guard let currentImage = await first, let partnerImage = await second else { return }

        let currentSide = ShareComposer.Side(image: currentImage, name: name(current.kid),
                                             ageMonths: current.ageMonths)
        let partnerSide = ShareComposer.Side(image: partnerImage, name: name(partner.kid),
                                             ageMonths: partner.ageMonths)
        // Older kid always on the left, so shared images are consistent.
        let (left, right) = current.kid == .a ? (currentSide, partnerSide) : (partnerSide, currentSide)

        if let composite = ShareComposer.composite(left: left, right: right) {
            shareItems = [composite]
        }
    }
}
