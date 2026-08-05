import SwiftUI
import SameAgeCore

/// Birthdays, album choices, and the rail side (R9, R10).
///
/// Editing either a birthday or an album invalidates the cached index, because both change
/// where every photo sits on the age axis.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var indexer: LibraryIndexer
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [PhotoLibraryService.AlbumSummary] = []
    @State private var repickingKid: KidProfile.ID?
    @State private var showingContactPicker: KidProfile.ID?

    var body: some View {
        NavigationStack {
            Form {
                ForEach($state.kids) { $kid in
                    Section {
                        TextField("Name", text: $kid.name)

                        DatePicker("Birthday", selection: $kid.birthday,
                                   in: ...Date(), displayedComponents: .date)

                        Button("Fill birthday from Contacts") {
                            showingContactPicker = kid.id
                        }
                        .font(.callout)

                        Button {
                            repickingKid = kid.id
                        } label: {
                            HStack {
                                Text("Album")
                                Spacer()
                                Text(albumTitle(for: kid.albumLocalIdentifier))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    } header: {
                        Text(kid.name.isEmpty ? "Kid" : kid.name)
                    }
                }

                Section("Feed") {
                    Picker("Age rail", selection: $state.railOnLeft) {
                        Text("Left").tag(true)
                        Text("Right").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        Text("Photos indexed")
                        Spacer()
                        Text("\(indexer.itemsA.count + indexer.itemsB.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Refresh from Photos") {
                        Task { await indexer.refresh(kids: state.kids) }
                    }
                    .disabled(indexer.isIndexing)
                } header: {
                    Text("Index")
                } footer: {
                    Text("New photos don't flow in on their own — add them to each kid's album in Photos, then refresh. SameAge stores only dates and sizes, never copies of your photos.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                }
            }
            .sheet(item: $repickingKid) { id in
                albumPicker(for: id)
            }
            .sheet(item: $showingContactPicker) { id in
                ContactBirthdayPicker { birthday in
                    if let index = state.kids.firstIndex(where: { $0.id == id }) {
                        state.kids[index].birthday = birthday
                    }
                    showingContactPicker = nil
                }
            }
            .task { albums = PhotoLibraryService.userAlbums() }
        }
    }

    private func albumPicker(for id: KidProfile.ID) -> some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    if let index = state.kids.firstIndex(where: { $0.id == id }) {
                        state.kids[index].albumLocalIdentifier = album.id
                    }
                    repickingKid = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(album.title)
                            Text("\(album.count) photos").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.kids.first(where: { $0.id == id })?.albumLocalIdentifier == album.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Choose album")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func albumTitle(for identifier: String) -> String {
        albums.first { $0.id == identifier }?.title ?? "—"
    }

    /// Persist, drop the now-stale cache, and re-index.
    private func commit() {
        state.kids.sort { $0.birthday < $1.birthday }
        state.save()
        indexer.invalidateCache()
        Task { await indexer.refresh(kids: state.kids) }
        dismiss()
    }
}

/// `sheet(item:)` needs an Identifiable; UUID is not one by default.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
