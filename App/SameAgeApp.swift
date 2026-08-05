import SwiftUI
import SameAgeCore

@main
struct SameAgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(nil)   // follow system light/dark
                .onAppear { state.load() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var indexer = LibraryIndexer()

    /// `-syntheticLibrary` runs the feed on generated fixtures, bypassing PhotoKit
    /// entirely. This is how the feed is exercised in a simulator, which has no People
    /// albums and effectively no photo library.
    private static var useSynthetic: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-syntheticLibrary")
        #else
        return false
        #endif
    }

    @State private var synthetic = SyntheticLibrary.makeItems()
    @State private var showingSettings = false

    /// The feed is black by design, so an empty feed is indistinguishable from a broken
    /// one. This makes every non-content state say what it is.
    @ViewBuilder
    private var indexStatus: some View {
        if indexer.isIndexing && !indexer.hasContent {
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("Reading your albums…")
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

        } else if !indexer.isIndexing && !indexer.hasContent {
            VStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                Text("No photos to show")
                    .font(.headline).foregroundStyle(.white)
                Text(indexer.lastError ??
                     "The albums you picked came back empty. Photos need a capture date to be placed on the age axis.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button("Try again") {
                        Task { await indexer.refresh(kids: state.kids) }
                    }
                    Button("Settings") { showingSettings = true }
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

        } else if indexer.isIndexing {
            // Refreshing over content already on screen — stay out of the way.
            VStack {
                Text("Updating…")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                Spacer()
            }
        }
    }

    var body: some View {
        Group {
            if Self.useSynthetic {
                FeedView(
                    itemsA: synthetic.a,
                    itemsB: synthetic.b,
                    axisMax: SyntheticLibrary.olderMaxAgeMonths,
                    railOnLeft: state.railOnLeft,
                    filter: $state.filter
                )
            } else if state.isConfigured {
                FeedView(
                    itemsA: indexer.itemsA,
                    itemsB: indexer.itemsB,
                    axisMax: state.axisMaxMonths,
                    railOnLeft: state.railOnLeft,
                    filter: $state.filter,
                    contentVersion: indexer.generation,
                    kidName: { kid in
                        // Ribbon A is always the older kid; the axis runs to their age.
                        kid == .a ? (state.older?.name ?? "Older") : (state.younger?.name ?? "Younger")
                    },
                    onToggleFavorite: { item in
                        Task {
                            await indexer.setFavorite(item.isFavorite, itemID: item.id,
                                                      assetIdentifier: item.assetIdentifier)
                        }
                    },
                    onOpenSettings: { showingSettings = true }
                )
                .sheet(isPresented: $showingSettings) {
                    SettingsView(indexer: indexer).environmentObject(state)
                }
                .overlay { indexStatus }
                .task(id: state.kids) {
                    // Renders the cached snapshot first, then re-enumerates (R24).
                    await indexer.start(kids: state.kids)
                }
            } else {
                OnboardingFlow()
            }
        }
    }
}
