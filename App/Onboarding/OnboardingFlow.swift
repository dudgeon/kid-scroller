import SwiftUI
import Photos
import SameAgeCore

/// First-run setup (rewritten R8).
///
/// The spec assumed the user would pick both kids from the iOS People list. PhotoKit
/// exposes no People API, so instead the user points SameAge at one normal album per kid —
/// which they create once in Photos from that kid's People album. The wording here is
/// deliberately explicit about that step, because it is the one place the app asks the
/// user to do something outside it.
struct OnboardingFlow: View {
    @EnvironmentObject private var state: AppState
    @State private var step: Step = .welcome
    @State private var albums: [PhotoLibraryService.AlbumSummary] = []
    @State private var draft: [KidProfile] = []

    enum Step: Equatable {
        case welcome, permissionDenied, pickAlbum(index: Int), details(index: Int), done
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome:            welcome
                case .permissionDenied:   denied
                case .pickAlbum(let i):   albumPicker(index: i)
                case .details(let i):     details(index: i)
                case .done:               ProgressView()
                }
            }
            .padding()
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SameAge").font(.largeTitle.bold())
            Text("Scroll both kids side by side, lined up by how old each of them was — not by date.")
                .foregroundStyle(.secondary)

            GroupBox("One-time setup, per kid") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Open Photos and find the kid under People", systemImage: "1.circle")
                    Label("Select All, then Add to Album", systemImage: "2.circle")
                    Label("Name it something like “SameAge – Maya”", systemImage: "3.circle")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("iOS doesn't let apps read the People album directly, so this step is what gives SameAge the same grouping Photos already worked out.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
            Button("Choose albums") { Task { await requestAccess() } }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    private var denied: some View {
        VStack(spacing: 16) {
            Text("SameAge needs photo access").font(.title2.bold())
            Text("Grant access in Settings → Privacy → Photos, then come back.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func albumPicker(index: Int) -> some View {
        List(albums) { album in
            Button {
                draft.append(KidProfile(name: "", birthday: defaultBirthday(for: index),
                                        albumLocalIdentifier: album.id))
                step = .details(index: index)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(album.title)
                        Text("\(album.count) photos").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle(index == 0 ? "Album for the older kid" : "Album for the younger kid")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView(
                    "No albums yet",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Create an album in Photos from each kid's People album first.")
                )
            }
        }
    }

    private func details(index: Int) -> some View {
        Form {
            Section("Name") {
                TextField("e.g. Maya", text: Binding(
                    get: { draft[index].name },
                    set: { draft[index].name = $0 }
                ))
            }
            Section {
                DatePicker("Birthday", selection: Binding(
                    get: { draft[index].birthday },
                    set: { draft[index].birthday = $0 }
                ), in: ...Date(), displayedComponents: .date)
            } footer: {
                Text("Every photo's position comes from this date, so it's worth getting right. You can change it later in Settings.")
            }
            Section {
                Button(index == 0 ? "Next kid" : "Start scrolling") { advance(from: index) }
                    .disabled(draft[index].name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(index == 0 ? "Older kid" : "Younger kid")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Flow

    private func requestAccess() async {
        let result = await PhotoLibraryService.requestAuthorization()
        guard result.canRead else {
            step = .permissionDenied
            return
        }
        albums = PhotoLibraryService.userAlbums()
        step = .pickAlbum(index: 0)
    }

    private func advance(from index: Int) {
        if index == 0 {
            // Don't offer the album already taken by the first kid.
            albums.removeAll { $0.id == draft[0].albumLocalIdentifier }
            step = .pickAlbum(index: 1)
        } else {
            state.kids = draft.sorted { $0.birthday < $1.birthday }
            state.save()
            step = .done
        }
    }

    /// Rough starting points so the date picker opens somewhere sensible rather than today.
    private func defaultBirthday(for index: Int) -> Date {
        AgeMath.date(birthday: Date(), ageMonths: index == 0 ? -72 : -42)
    }
}
