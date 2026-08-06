import SwiftUI
import SameAgeCore

/// Bridges the UIKit feed to SwiftUI and carries the current age back out to the rail.
@MainActor
final class FeedController: ObservableObject {
    @Published var age: Double = 0
    weak var view: FeedUIView?

    func setAge(_ age: Double, animated: Bool = false) {
        view?.setAge(age, animated: animated)
    }
}

/// Deliberately holds `controller` as a plain reference, not `@ObservedObject`: the feed
/// publishes age *outward*, and observing it here would re-render on every scroll frame.
struct FeedRepresentable: UIViewRepresentable {
    let itemsA: [FeedItem]
    let itemsB: [FeedItem]
    let axisMax: Double
    let railOnLeft: Bool
    /// Changes only when the content itself changes (filters, kids, rail side).
    let version: Int
    let controller: FeedController
    /// Debug only: `-startAge <months>` jumps the feed on launch, so a given point in the
    /// timeline can be screenshotted deterministically without simulating gestures.
    let initialAge: Double?
    let onSelect: (FeedItem) -> Void
    let onLongPress: (FeedItem) -> Void
    let onChromeChange: (Bool) -> Void

    func makeUIView(context: Context) -> FeedUIView {
        let view = FeedUIView(frame: .zero)
        view.onAgeChange = { [weak controller] age in
            guard let controller, abs(controller.age - age) > 0.0001 else { return }
            controller.age = age
        }
        view.onSelect = onSelect
        view.onLongPress = onLongPress
        view.onChromeVisibilityChange = onChromeChange
        controller.view = view
        view.configure(itemsA: itemsA, itemsB: itemsB, axisMax: axisMax,
                       railOnLeft: railOnLeft, version: version)
        if let initialAge { view.setAge(initialAge, animated: false) }
        return view
    }

    func updateUIView(_ view: FeedUIView, context: Context) {
        view.configure(itemsA: itemsA, itemsB: itemsB, axisMax: axisMax,
                       railOnLeft: railOnLeft, version: version)
    }
}

/// The age rail. Scrubs **linearly in age** regardless of the feed's content-speed
/// mapping (R11), and carries the only age readout in the UI (D5).
struct AgeRailView: View {
    let axisMax: Double
    @ObservedObject var controller: FeedController
    @Binding var showingAgeInput: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = AgeRailScale(axisMax: axisMax, height: Double(geo.size.height))

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 2)
                    .padding(.vertical, CGFloat(AgeRailScale.padding) - 6)
                    .frame(maxWidth: .infinity)

                // D5: year ticks only — the pill carries the detail.
                ForEach(scale.yearTicks, id: \.self) { tick in
                    Text(AgeFormatter.yearTick(months: tick))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .position(x: geo.size.width / 2, y: CGFloat(scale.y(forAge: tick)))
                }

                Text(AgeFormatter.short(months: controller.age))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white).shadow(radius: 4))
                    .fixedSize()
                    .position(x: geo.size.width / 2, y: CGFloat(scale.y(forAge: controller.age)))
                    .onTapGesture { showingAgeInput = true }      // R12
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.setAge(scale.age(forY: Double(value.location.y)), animated: false)
                    }
            )
        }
        .frame(width: CGFloat(FeedUIView.Metrics.railWidth))
    }
}

/// R12 — type or pick an exact age and jump to it.
struct AgeInputSheet: View {
    let axisMax: Double
    @ObservedObject var controller: FeedController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("e.g. 15mo or 2.5y", text: $text)
                    .font(.system(.title3, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(go)
                Text("months (15) · years (2.5y) · both (2y 6m)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if invalid {
                    Text("Couldn't read that as an age.")
                        .font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Jump to age")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go", action: go)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private func go() {
        guard let months = AgeFormatter.parse(text) else {
            invalid = true
            return
        }
        controller.setAge(min(months, axisMax), animated: true)
        dismiss()
    }
}

/// D8 — filters live in a swipe-up sheet, keeping the feed itself chrome-free.
struct FilterSheet: View {
    @Binding var filter: FilterState
    var onOpenSettings: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Favorites only", isOn: $filter.favoritesOnly)
                }
                Section {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        Toggle(label(for: kind), isOn: binding(for: kind))
                    }
                } header: {
                    Text("Media")
                } footer: {
                    Text("Filters narrow each ribbon on its own. Density scaling keeps the two sides age-aligned.")
                }

                Section {
                    Button {
                        dismiss()
                        onOpenSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func label(for kind: MediaKind) -> String {
        switch kind {
        case .photo: return "Photos"
        case .livePhoto: return "Live Photos"
        case .video: return "Videos"
        }
    }

    private func binding(for kind: MediaKind) -> Binding<Bool> {
        Binding(
            get: { filter.kinds.contains(kind) },
            set: { isOn in
                if isOn { filter.kinds.insert(kind) }
                // Never let the user filter everything away — the feed would go blank.
                else if filter.kinds.count > 1 { filter.kinds.remove(kind) }
            }
        )
    }
}

struct FeedView: View {
    let itemsA: [FeedItem]
    let itemsB: [FeedItem]
    let axisMax: Double
    let railOnLeft: Bool
    @Binding var filter: FilterState
    /// Bumped by whatever supplies the items whenever they are replaced. Without it the
    /// feed cannot tell "same filter, new photos" from "nothing changed".
    var contentVersion: Int = 0
    /// Assets the user has hidden from the app; excluded from both ribbons and fullscreen.
    var hidden: Set<String> = []
    var kidName: (Kid) -> String = { $0 == .a ? "Older" : "Younger" }
    var onToggleFavorite: (FeedItem) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onHide: (FeedItem) -> Void = { _ in }

    @State private var selected: FeedItem?
    @State private var pendingHide: FeedItem?
    /// The names/filters bar. Starts visible so it's discoverable, then follows scroll
    /// direction like browser chrome.
    @State private var showChrome = true

    /// `@State`, not `@StateObject`, on purpose: this view must NOT re-render when the age
    /// changes, or every scroll frame would re-filter both ribbons. Only `AgeRailView`
    /// observes the controller, so only the rail redraws as you scroll.
    @State private var controller = FeedController()
    @State private var showingAgeInput = false
    @State private var showingFilters = false

    private var filteredA: [FeedItem] {
        itemsA.filter { filter.admits($0) && !hidden.contains($0.assetIdentifier) }
    }
    private var filteredB: [FeedItem] {
        itemsB.filter { filter.admits($0) && !hidden.contains($0.assetIdentifier) }
    }

    private var isFiltered: Bool {
        filter.favoritesOnly || filter.kinds.count < MediaKind.allCases.count
    }

    /// The top ribbon: who you're looking at, and what's narrowing the view. Tapping the
    /// names manages people, albums and birthdays; the trailing button opens filters.
    private var chromeBar: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill").font(.caption)
                    Text("\(kidName(.a)) · \(kidName(.b))")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .accessibilityLabel("Manage people and albums")

            Spacer()

            Button { showingFilters = true } label: {
                HStack(spacing: 5) {
                    if filter.favoritesOnly {
                        Image(systemName: "heart.fill").foregroundStyle(.red).font(.caption)
                    }
                    Image(systemName: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .font(.title3)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .accessibilityLabel(isFiltered ? "Filters active. Open filters" : "Open filters")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    /// `-startAge <months>` on the launch command line, DEBUG builds only.
    static var debugStartAge: Double? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-startAge"), index + 1 < args.count else { return nil }
        return Double(args[index + 1])
        #else
        return nil
        #endif
    }

    var body: some View {
        ZStack(alignment: railOnLeft ? .topLeading : .topTrailing) {
            FeedRepresentable(
                itemsA: filteredA, itemsB: filteredB,
                axisMax: axisMax, railOnLeft: railOnLeft,
                version: FeedVersion.compute(filter: filter, contentVersion: contentVersion,
                                             axisMax: axisMax, railOnLeft: railOnLeft,
                                             hiddenVersion: hidden.hashValue),
                controller: controller,
                initialAge: Self.debugStartAge,
                onSelect: { selected = $0 },
                onLongPress: { pendingHide = $0 },
                onChromeChange: { visible in
                    withAnimation(.easeInOut(duration: 0.2)) { showChrome = visible }
                }
            )
            .ignoresSafeArea(edges: .bottom)

            AgeRailView(axisMax: axisMax, controller: controller, showingAgeInput: $showingAgeInput)
        }
        .background(.black)
        // Filters and people management live in a top ribbon that follows scroll
        // direction like browser chrome: swipe back towards newborn and it appears, dig
        // deeper and it slides away. This supersedes D8's bottom handle (and D6's
        // no-names rule) at the user's request — the feed stays chrome-free while moving.
        .overlay(alignment: .top) {
            if showChrome {
                chromeBar.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "Hide this photo?",
            isPresented: Binding(get: { pendingHide != nil },
                                 set: { if !$0 { pendingHide = nil } }),
            titleVisibility: .visible
        ) {
            Button("Hide from SameAge", role: .destructive) {
                if let item = pendingHide { onHide(item) }
                pendingHide = nil
            }
            Button("Cancel", role: .cancel) { pendingHide = nil }
        } message: {
            Text("It won't appear in the feed or fullscreen. Your Photos library is untouched, and you can unhide everything in Settings.")
        }
        .sheet(isPresented: $showingAgeInput) {
            AgeInputSheet(axisMax: axisMax, controller: controller)
        }
        .sheet(isPresented: $showingFilters) {
            FilterSheet(filter: $filter, onOpenSettings: onOpenSettings)
        }
        .fullScreenCover(item: $selected) { item in
            // Hand over the whole ribbon so fullscreen can page through it, with the other
            // kid's ribbon for age-matching (R18). Both come from the filtered pools, so
            // paging honours the current filters exactly as the feed does.
            FullscreenView(
                items: item.kid == .a ? filteredA : filteredB,
                counterpartItems: item.kid == .a ? filteredB : filteredA,
                startID: item.id,
                name: kidName,
                onToggleFavorite: onToggleFavorite
            )
        }
        .statusBarHidden()
    }
}
