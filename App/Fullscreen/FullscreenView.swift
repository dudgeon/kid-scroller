import SwiftUI
import CoreLocation
import SameAgeCore

/// Fullscreen photo with metadata and the age-matched counterpart (R17–R19, D7).
struct FullscreenView: View {
    let tapped: FeedItem
    let counterpart: FeedItem?
    let name: (Kid) -> String
    let onToggleFavorite: (FeedItem) -> Void

    @Environment(\.dismiss) private var dismiss

    /// D7: the inset sits bottom-right and tapping it swaps which photo is large.
    @State private var swapped = false
    @State private var images: [String: UIImage] = [:]
    /// Items whose full-quality image has landed, so a late degraded frame can't undo it.
    @State private var fullyLoaded: Set<String> = []
    @State private var placeName: String?
    @State private var isFavorite: Bool
    @State private var shareItems: [Any]?
    @State private var isPreparingShare = false

    init(tapped: FeedItem, counterpart: FeedItem?,
         name: @escaping (Kid) -> String,
         onToggleFavorite: @escaping (FeedItem) -> Void) {
        self.tapped = tapped
        self.counterpart = counterpart
        self.name = name
        self.onToggleFavorite = onToggleFavorite
        _isFavorite = State(initialValue: tapped.isFavorite)
    }

    /// Which item is currently large. Swapping is presentation-only — `tapped` stays the
    /// one whose favourite state the toolbar edits, so the control never silently retargets.
    private var large: FeedItem { swapped ? (counterpart ?? tapped) : tapped }
    private var small: FeedItem? { swapped ? tapped : counterpart }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = images[large.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

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
        .onAppear { startProgressiveLoad() }
        .task { await resolvePlaceName() }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let shareItems { ShareSheet(items: shareItems) }
        }
        .statusBarHidden()
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3.weight(.semibold))
            }
            Spacer()
            Button {
                isFavorite.toggle()
                var updated = tapped
                updated.isFavorite = isFavorite
                onToggleFavorite(updated)          // R20 — the only library write
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? .red : .white)
            }
            Button {
                Task { await prepareShare() }
            } label: {
                if isPreparingShare {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.title3)
                }
            }
            .disabled(counterpart == nil || isPreparingShare)
            .padding(.leading, 8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var metadata: some View {
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

    /// Progressive load: PhotoKit's `.opportunistic` delivery calls back first with a fast
    /// low-resolution frame — often already cached from the feed — and again with full
    /// quality. Showing the degraded frame immediately is what removes the black screen
    /// while a large or iCloud-resident photo loads.
    private func startProgressiveLoad() {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        for item in [tapped, counterpart].compactMap({ $0 }) {
            ThumbnailProvider.shared.request(
                identifier: item.assetIdentifier,
                targetSize: target,
                contentMode: .aspectFit          // show the whole photo, don't crop
            ) { image, isDegraded in
                guard let image else { return }
                // Callbacks can arrive out of order; never let a late low-resolution
                // frame replace one that is already full quality.
                if isDegraded && fullyLoaded.contains(item.id) { return }
                images[item.id] = image
                if !isDegraded { fullyLoaded.insert(item.id) }
            }
        }
    }

    /// R17 — show a place name rather than raw coordinates when one is available.
    private func resolvePlaceName() async {
        guard let location = large.location else { return }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: location.latitude, longitude: location.longitude)
        )
        placeName = placemarks?.first.flatMap { $0.name ?? $0.locality ?? $0.administrativeArea }
    }

    /// R19 — a side-by-side composite of the matched pair, both ages labelled.
    private func prepareShare() async {
        guard let counterpart else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        async let first = ThumbnailProvider.shared.requestFull(identifier: tapped.assetIdentifier)
        async let second = ThumbnailProvider.shared.requestFull(identifier: counterpart.assetIdentifier)
        guard let tappedImage = await first, let counterpartImage = await second else { return }

        // Always order older kid on the left, so shared images are consistent.
        let tappedSide = ShareComposer.Side(image: tappedImage, name: name(tapped.kid),
                                            ageMonths: tapped.ageMonths)
        let otherSide = ShareComposer.Side(image: counterpartImage, name: name(counterpart.kid),
                                           ageMonths: counterpart.ageMonths)
        let (left, right) = tapped.kid == .a ? (tappedSide, otherSide) : (otherSide, tappedSide)

        if let composite = ShareComposer.composite(left: left, right: right) {
            shareItems = [composite]
        }
    }
}
