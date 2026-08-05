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
                .overlay(alignment: .top) {
                    if indexer.isIndexing {
                        Text("Indexing…")
                            .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                }
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
