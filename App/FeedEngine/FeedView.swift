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

    func makeUIView(context: Context) -> FeedUIView {
        let view = FeedUIView(frame: .zero)
        view.onAgeChange = { [weak controller] age in
            guard let controller, abs(controller.age - age) > 0.0001 else { return }
            controller.age = age
        }
        view.onSelect = onSelect
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
    var kidName: (Kid) -> String = { $0 == .a ? "Older" : "Younger" }
    var onToggleFavorite: (FeedItem) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    @State private var selected: FeedItem?

    /// `@State`, not `@StateObject`, on purpose: this view must NOT re-render when the age
    /// changes, or every scroll frame would re-filter both ribbons. Only `AgeRailView`
    /// observes the controller, so only the rail redraws as you scroll.
    @State private var controller = FeedController()
    @State private var showingAgeInput = false
    @State private var showingFilters = false

    private var filteredA: [FeedItem] { itemsA.filter(filter.admits) }
    private var filteredB: [FeedItem] { itemsB.filter(filter.admits) }

    private var isFiltered: Bool {
        filter.favoritesOnly || filter.kinds.count < MediaKind.allCases.count
    }

    private var filterHandle: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
            if isFiltered {
                HStack(spacing: 4) {
                    if filter.favoritesOnly {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                    }
                    if filter.kinds.count < MediaKind.allCases.count {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
                .font(.system(size: 9, weight: .semibold))
            }
            Capsule().frame(width: 34, height: 4)
        }
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(.bottom, 4)
        .contentShape(Capsule())
        .onTapGesture { showingFilters = true }
        .gesture(
            // A swipe on the handle itself, which the scroll view never sees.
            DragGesture(minimumDistance: 10)
                .onEnded { if $0.translation.height < -15 { showingFilters = true } }
        )
        .accessibilityLabel(isFiltered ? "Filters active. Open filters and settings"
                                       : "Open filters and settings")
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
                                             axisMax: axisMax, railOnLeft: railOnLeft),
                controller: controller,
                initialAge: Self.debugStartAge,
                onSelect: { selected = $0 }
            )
            .ignoresSafeArea(edges: .bottom)

            AgeRailView(axisMax: axisMax, controller: controller, showingAgeInput: $showingAgeInput)
        }
        .background(.black)
        // D8 wanted a bare swipe-up anywhere in the feed, which cannot work: the feed is
        // driven by a UIScrollView that consumes every vertical pan, so the gesture never
        // fired and the filters — and Settings, which lives in the same sheet — were
        // simply unreachable. This keeps D8's swipe-up sheet and its chrome-free feed, but
        // gives it a grab handle that is both tappable and swipe-able, and that shows when
        // a filter is narrowing what you're seeing.
        .overlay(alignment: .bottom) { filterHandle }
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
