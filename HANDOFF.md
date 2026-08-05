# SameAge — session handoff

**Last updated:** 2026-08-05, after the first build shipped to TestFlight.
**Read this first, then [PLAN.md](PLAN.md) for the full architecture.**

**Status: shipping.** Build `0.1 (1)` is live on TestFlight, *Ready to Submit*, distributed to
the `Internal` group. The toolchain, signing chain and upload path are all proven.

---

## 1. Resume in one minute

```bash
cd /Users/geoffreydudgeon/repos/kid-scroller
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # still required — see §2
swift test --package-path Packages/SameAgeCore                    # expect 51 tests, 0 failures
xcodegen generate                                                 # SameAge.xcodeproj is gitignored/generated
```

Ship a new build:

```bash
./scripts/release.sh --upload
```

That regenerates the project, runs the tests, archives, and uploads. Automatic distribution is on
for the `Internal` group, so a processed build reaches the phone with no further clicks. Bump
`CFBundleShortVersionString` in `project.yml` for a new version; App Store Connect manages build
numbers itself (`manageAppVersionAndBuildNumber`), so build collisions are not a concern.

### Live identifiers

| | |
|---|---|
| App Store Connect app | **SameAgeScroller**, id `6798406752` (name "SameAge" was already taken) |
| Bundle ID | `org.dudgeon.sameage` |
| Team | `R39EF29X3Y` — Apple Developer Program, Individual, renews 2027-04-25 |
| ASC API key | `sameage-agent`, Key ID `63X6QKKH2A`, Admin |
| Issuer ID | `69a6de71-3415-47e3-e053-5b8c7c11a4d1` |
| Key file | `~/.appstoreconnect/private_keys/AuthKey_63X6QKKH2A.p8` (chmod 600, **one-time download — cannot be re-fetched**) |
| TestFlight group | `Internal`, automatic distribution enabled, 1 tester (dudgeon@gmail.com) |

---

## 2. Environment facts worth not rediscovering

| Fact | Detail |
|---|---|
| `xcode-select` | Pointed at `/Library/Developer/CommandLineTools`, **not** Xcode. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` overrides it per-process with **no sudo**. |
| XCTest | Ships with Xcode, **not** the Command Line Tools. `swift test` fails with "no such module 'XCTest'" unless `DEVELOPER_DIR` is set. |
| Native simulator MCP tool | Requires the *system-wide* `xcode-select` to point at Xcode; it ignores `DEVELOPER_DIR`. Until that sudo command is run, drive the simulator with `xcrun simctl` and capture with `xcrun simctl io <device> screenshot`. |
| App-control permissions | Chrome = `read` tier (use the claude-in-chrome MCP to interact), Xcode = `click` tier (no typing — use Bash), Simulator = `full`. Xcode's tier is a category cap and cannot be raised by re-requesting. |
| Disk | 26.6 GB of caches were cleared with approval; free space went 29 GB → 55.6 GB. `~/Library/Caches`, `~/.npm`, `~/.cache` will regrow. |
| Simulator | `SameAge-Dev`, udid `6E87EB89-4557-4258-B890-4B04A7AE684A`, iOS 18.4. Bundled with Xcode 16.3 — it was present but unregistered until `xcodebuild -downloadPlatform iOS` ran. |
| Git | Remote `github.com/dudgeon/kid-scroller`, branch `main`, **zero commits so far**. `gh` is authenticated as `dudgeon`. |

### Useful commands

```bash
# Run the feed on generated fixtures, jumped to a specific age (both flags are DEBUG-only)
xcrun simctl launch SameAge-Dev org.dudgeon.sameage -syntheticLibrary -startAge 36
```

```bash
xcodebuild -project SameAge.xcodeproj -scheme SameAge -sdk iphonesimulator -destination 'id=6E87EB89-4557-4258-B890-4B04A7AE684A' -derivedDataPath .build-sim CODE_SIGNING_ALLOWED=NO build
```

---

## 3. Three spec deviations — deliberate, do not "fix" back

### 3.1 R4/R8 rewritten — person identification is album-based

PhotoKit exposes **no** People/faces API: no People `PHAssetCollectionSubtype`, no person predicate on
`PHFetchOptions`, and Apple blocks the data even to private API. Vision offers face *detection* but no public
face-*identity* embedding. Nothing in the iOS 26 era changed this.

**Resolution (user chose this):** the user materialises each kid's People album into a normal Photos album once
(Photos → the kid's People album → Select All → Add to Album), and SameAge reads those **user albums**, which are
fully public API. Zero ML, exact fidelity to Apple's own clustering. Consequence: new photos do not auto-flow into
the ribbons; the user re-adds periodically. Onboarding wording already says this explicitly.

R23–R25 downscope accordingly — indexing is metadata enumeration of two albums, not a 100k-asset ML pass.

### 3.2 The prototype's sparse threshold does not survive the port

The prototype ghosts a column when `pointsPerMonth < 16`. That constant is tuned to its own pixel scale — 136px
columns holding 70–165px photos. A real iPhone ribbon is ~180pt wide with ~240pt photos, so the same 6-month
drought computes to ~34 pt/month and **would never have tripped the threshold** — D3 ghosting would silently never
fire on device.

Replaced with a resolution-independent rule: a column is sparse when the neighbouring photos bracketing the current
age are more than `RibbonMetrics.sparseGapMonths` (4) apart. This also makes R6's solo tail and the missed-newborn
lead-in ghost correctly. `testSparseIsResolutionIndependent` asserts identical verdicts at 90/160/320/640pt.

### 3.3 Exact combined inverse instead of a sampled table

The prototype inverts the combined mapping via a 0.25-month sampled lookup table. `CombinedMapping` instead builds
the exact piecewise-linear inverse over the merged breakpoint set of both ribbons. Both are monotonic; the exact
version round-trips `age → s → age` to 1e-6, where the sampled one accumulates error that would show up as the two
ribbons slowly drifting out of alignment. `testCombinedRoundTripsExactly` pins this.

---

## 4. What exists and is verified

```
Packages/SameAgeCore/          pure Swift, Foundation-only, tests run on macOS — 44 tests, 0 failures
  AgeMapping.swift             RibbonMetrics, PlacedItem, RibbonLayout, RibbonMapping,
                               CombinedMapping (D1), AgeRailScale (R11)
  AgeMath.swift                continuous-months age axis (mean-month constant, monotonic)
  AgeFormatter.swift           "2y 1m" formatting + the R12 input parser
  FeedItem.swift               FeedItem, Kid, MediaKind, FilterState (R21/R22)

App/
  SameAgeApp.swift             @main; routes onboarding vs feed vs synthetic
  KidProfile.swift             KidProfile + AppState (UserDefaults persistence)
  FeedEngine/FeedUIView.swift  UIScrollView physics driver + 2 recycling columns
  FeedEngine/FeedView.swift    SwiftUI shell, AgeRailView, AgeInputSheet (R12), FilterSheet (D8)
  PhotoLibrary/PhotoLibraryService.swift   auth, user albums, album→[FeedItem], favourite write-back (R20)
  PhotoLibrary/LibraryIndexer.swift        async refresh, PHPhotoLibraryChangeObserver, optimistic favourite
  Onboarding/OnboardingFlow.swift          permission → album per kid → name + birthday
  DebugSeed/SyntheticLibrary.swift         deterministic fixtures incl. a 30–42mo drought and shared photos
```

**Verified working on iOS 18.4** (screenshot taken at `-startAge 36`): both ribbons age-aligned on one axis
(left 2y9m→3y6m, right 2y5m→3y5m), the younger column correctly ghosted inside its drought, rail year ticks,
age pill, favourites and video glyphs all rendering.

### Why the feed uses a UIScrollView rather than SwiftUI ScrollView

Under D1 (constant content speed) the combined offset `s` is **linear in finger travel**, so a single scroll view
with `contentSize.height = sMax - sMin + viewportHeight` yields native momentum, deceleration and rubber-banding on
`s` for free, with `age = combined.age(atCombinedOffset:)` a pure function of the offset. Two stock scroll views
cannot do this — they would have to share one gesture while advancing at different, nonlinearly-related rates.

Two traps already hit and fixed here; don't reintroduce them:
- `FeedRepresentable` holds `controller` as a **plain reference, not `@ObservedObject`**, and `FeedView` uses
  `@State`, not `@StateObject`. Otherwise every age tick re-renders the view tree and re-filters both ribbons.
- `FeedUIView.configure(...)` takes a `version:` and **no-ops when unchanged**. SwiftUI calls `updateUIView` on
  every age tick; without the guard the mappings rebuild at scroll frequency.

---

## 5. What is NOT done

Everything in the spec is now built and shipped except the following. **None of it is blocked** —
the toolchain, signing and upload path are all working.

| Work | Notes |
|---|---|
| Live Photo motion in fullscreen (R16) | Live Photos currently render as stills everywhere. `PHLivePhotoView` in `FullscreenView` is the remaining piece. |
| Thumbnail preheating | `ThumbnailProvider.startCaching` exists but nothing calls it. Wire it to the visible window ± a screen for smoother fast scrolls. |
| Onboarding polish | No way to go *back* a step, and no empty-state guidance if the user has no albums yet. |
| Real-library validation | Everything so far has run against synthetic fixtures or a simulator with no photos. The album model and scroll performance need a real 100k-asset library to be trusted. |

### Things that bit, so they don't bite again

- **App Store Connect requires Xcode 26+ since 2026-04-28.** `release.sh` fail-stops on an older
  Xcode rather than discovering it at upload time.
- **An app icon is mandatory to upload.** The first upload was rejected for a missing
  `CFBundleIconName` and 120×120 asset after passing every other check. `scripts/make_app_icon.swift`
  regenerates it; the icon must be **opaque** (no alpha) or the App Store rejects it.
- **The app record cannot be created via API** — browser only, one time. Already done.
- **`set -o pipefail` plus `| head`/`| tail`** gave `xcodebuild` a SIGPIPE and aborted `release.sh`
  with exit 141 and an empty log. Don't reintroduce pipefail there.
- **Native `<select>` menus can't be driven** by the browser automation available here (clicks,
  `form_input` and synthetic keys all fail silently). Setting `value` through the native setter plus
  a dispatched `change` event is what works on App Store Connect's React forms.

---

## 6. Open questions for the user

1. **App name.** The record is `SameAgeScroller` because "SameAge" was already taken on the App
   Store. Renaming is one field in App Store Connect any time before public release; the bundle ID
   is unaffected.
2. **Deployment target** is iOS 17.0; the phone runs iOS 18.x, so this is safe but could be raised.
3. **The album model needs a real trial.** Materialise each kid's People album into
   `SameAge – <Kid>` in Photos and see whether the one-time setup and the manual refresh actually
   feel acceptable in practice. That judgement can't be made from fixtures.
