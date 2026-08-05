# SameAge — Implementation & Delivery Plan

**Repo:** `/Users/geoffreydudgeon/repos/kid-scroller` · **App name (working):** SameAge · **Spec:** `/Users/geoffreydudgeon/Downloads/sameage-spec.html` (v0.1, R1–R25, decisions D1–D8 locked)
**Plan date:** 2026-08-04 · **Audience:** executing agents (Sonnet/Opus) + the user. This document is the source of truth; do not re-litigate locked decisions (§1.3).

---

## 1. Executive summary

### 1.1 What gets built

A portrait-only SwiftUI iPhone app that shows two vertical photo ribbons — one per kid — sharing a single vertical **age axis**. Scrolling moves through content at constant speed (D1); each ribbon advances at whatever rate keeps it aligned to the current age; sparse periods hold the last photo ghosted (D3) and crawl. An age rail on the left (D5/R10) scrubs linearly; tapping the age pill jumps to a typed age (R12). Tap a photo → fullscreen with metadata and an age-matched counterpart inset, bottom-right, tap-to-swap (D7). Share exports a side-by-side composite with both ages labeled (R19). Filters (favorites, media type) live in a swipe-up sheet (D8). Distribution: TestFlight internal testing on the user's iPhone first, family/friends after.

The feed physics are a direct port of the working JS prototype in the spec (`layout()`, `offsetAt()`, `ageFromS()`, `nudge()`), implemented as a pure-Swift package (`SameAgeCore`) that is unit-tested on macOS with **zero** Apple-toolchain-GUI or simulator dependencies — so real work starts before the toolchain blockers below are cleared.

### 1.2 The two hard findings (both change the plan)

**Finding 1 — R4/R8 as written cannot be built (confirmed).** PhotoKit has **no public API for People/faces**: no `PHAssetCollectionSubtype` for People, no person predicate on `PHFetchOptions`, no way to enumerate People albums. Vision offers face *detection* (`VNDetectFaceRectanglesRequest`) but no public face-*identity* embedding (no public faceprint). This is still true in the iOS 26 era — WWDC 2025/2026 added a PhotoKit background-upload extension (iOS 26.1) and Photos-app features (Groups in People & Pets), but no People read API. Sources: [Apple Dev Forums — "Access face tags"](https://forums.developer.apple.com/forums/thread/126711), [Apple Dev Forums — "Does PhotoKit provide access to People…"](https://developer.apple.com/forums/thread/688345), [Kyle Howells — Querying the iOS Photo Library (2025)](https://ikyle.me/blog/2025/querying-the-ios-photo-library), [9to5Mac — iOS 26.1 background photo backup](https://9to5mac.com/2025/10/24/ios-26-1-third-party-photos-backup-background/). Resolution options and the recommendation are in **Decision 1** below; R4/R8/R23–R25 rewrites are in §4.

**Finding 2 — the installed toolchain cannot ship to TestFlight at all.** Since **April 28, 2026**, App Store Connect rejects uploads not built with **Xcode 26 / iOS 26 SDK** ([Apple — Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)). The Mac has Xcode 16.3 (iOS 18.4 SDK). Worse, every Xcode 26.x requires at least **macOS 15.6** (26.0–26.3) or **macOS 26.2 Tahoe** (26.4+) ([version table](https://mungomash.com/software/xcode/versions/)), and the Mac runs macOS **15.5**. So shipping requires: a macOS point update → Xcode 26.3 → iOS 26 simulator runtime — against only **19 GB free disk**. The exact sequence, disk math, and verification steps are in §2. This also incidentally fixes the "Xcode 16.3 can't debug an iOS 26 iPhone" problem.

### 1.3 Locked decisions (do not reopen)

D1 constant content speed · D2 newborn at top · D3 ghosted held photo · D4 gap-only divider · D5 year ticks only + detail pill · D6 no name headers · D7 inset bottom-right, tap to swap · D8 swipe-up filter sheet.

### 1.4 Decisions the user must make before coding starts

Reply compactly, e.g. **"1a, 2a, 3 yes, 4: 40 GB ok, 5a"**.

**Decision 1 — Person identification strategy (replaces R4/R8 as written).**
- **(a) Album-based (RECOMMENDED):** One-time manual step per kid in Photos.app — open the kid's People album → select all → *Add to Album* → new album `SameAge – <Kid>`. SameAge reads those two **user albums** via PhotoKit (`PHAssetCollection`, fully public API). Zero ML, exact fidelity to Apple's own People clustering, works in the simulator (albums can be seeded programmatically), ~1 week less work than (b). Cost: a 5-minute setup step per kid, and **new photos don't auto-flow** — the user must occasionally re-add recent photos to the albums (Settings will show "album last refreshed" guidance).
- **(b) Bundled Core ML face recognition:** ship an embedding model, scan 100k assets, cluster, have the user label clusters. Contradicts R4's "no custom face recognition", adds ~2–4 weeks, uncertain infant accuracy, battery/thermal cost, untestable against simulator People data. Not recommended for v1.
- **(c) Hybrid:** (a) as the seed + `VNGenerateImageFeaturePrintRequest` similarity on face crops to *suggest* new photos into each ribbon ("review queue"). Good v2; the v1 architecture under (a) will not preclude it.
- **(d) Optional power assist to (a):** if the user's Mac (any Mac) holds the synced Photos library, the open-source `osxphotos` tool can read Photos' private database, extract person→asset lists, and create the two albums automatically via AppleScript, which then sync to the iPhone via iCloud. Fragile (private DB schema), one-time, run by the user. Only relevant if a Mac has the full library locally — with 19 GB free on this Mac, probably not this Mac.
**Recommendation: 1a** (optionally + 1d if a Mac has the library).

**Decision 2 — Toolchain path (see §2 for full detail).**
- **(a) RECOMMENDED:** update macOS 15.5 → latest 15.7.x (Software Update, restart), delete Xcode 16.3, install **Xcode 26.3** (last version that runs on Sequoia), download iOS 26 simulator runtime.
- **(b)** Full upgrade to macOS Tahoe 26.x + Xcode 26.6. More disk, more risk, no v1 benefit.
- **(c)** Keep Xcode 16.3 locally and build/upload via **Xcode Cloud** (cloud Xcode 26, 25 free compute-hrs/mo). Avoids the macOS update but adds GitHub/workflow moving parts and still needs a local simulator runtime for dev. Fallback only.
**Recommendation: 2a.**

**Decision 3 — Identifiers.** Bundle ID `org.dudgeon.sameage` (matches the existing `org.dudgeon.*` convention), App Store Connect app name "SameAge" (fallbacks if taken: "SameAge — Two Kids, One Age", "KidScroller"). SKU `sameage-001`. Confirm or override.

**Decision 4 — Disk.** §2 needs **≥ 35 GB free** at the peak (currently 19 GB). Confirm you can free ~16+ GB (agent can help find candidates), or choose Decision 2c.

**Decision 5 — Deployment target.**
- **(a) iOS 17.0 (RECOMMENDED):** maximally safe since the iPhone's iOS version is unknown; costs nothing because the feed engine uses a UIKit scroll driver (§3.4) rather than iOS-18-only SwiftUI scroll APIs.
- **(b) iOS 18.0:** only if the user confirms the phone runs iOS 18+.
**Recommendation: 5a.**

Also required from the user before Phase 0 (not decisions, just actions — §2): verify paid membership, create an App Store Connect API key, create the app record, run the sudo/password steps.

---

## 2. Blockers & prerequisites

Ordered. Each item: **who acts**, exact command / URL + click path, and verification. Agents must fail-stop if a verification fails, and re-check free disk (`df -h /`) before every download step.

### B0. Free disk space — [USER, agent-assisted] — BLOCKS EVERYTHING

- Target: **≥ 35 GB free** before B3 (peak usage during Xcode expansion), settling to ~6–10 GB free after everything installs. Current: 19 GB.
- Agent may assist: `du -x -d 2 -g ~ 2>/dev/null | sort -rn | head -30` to find candidates; user decides what to delete (agent must never delete user data without explicit per-item approval).
- Known reclaim available in this plan itself: deleting Xcode 16.3 in B3 recovers ~12 GB — but that alone is not enough.
- **Verify:** `df -h /` shows ≥ 35 GB available before starting B3.

### B1. Verify paid Apple Developer Program membership — [USER, 2 min] — BLOCKS ALL TESTFLIGHT WORK

- URL: `https://developer.apple.com/account` → sign in → **Membership details**.
- Confirm: "Apple Developer Program" (not "Apple Developer" free tier), team **R39EF29X3Y**, expiration date in the future. (Strong prior it's active: a Developer ID cert was issued to this team 2026-04-26, and those are paid-members-only. Xcode's cached "Personal Team" flag is stale 2023 data — ignore it.)
- While signed in, also open `https://appstoreconnect.apple.com` and accept any pending **license agreement banners** (Account Holder task; pending agreements silently block uploads).
- **Verify:** membership page shows active paid program. If NOT paid → stop; user must enroll ($99/yr, ~24–48 h approval) before any TestFlight phase (simulator phases 1–5 can proceed meanwhile).

### B2. macOS 15.5 → 15.7.x — [USER, ~30 min incl. restart]

- System Settings → General → Software Update → install the latest **macOS Sequoia 15.7.x** point update (do **not** accept a Tahoe 26 upgrade unless Decision 2b). Requires password + restart.
- Why: every Xcode 26.x requires ≥ macOS 15.6; the machine has 15.5.
- **Verify:** `sw_vers -productVersion` → `15.6` or `15.7.x`.

### B3. Replace Xcode 16.3 with Xcode 26.3 — [USER downloads & password steps; AGENT can drive the rest]

1. **[USER]** Delete Xcode 16.3 (recovers ~12 GB): `sudo rm -rf /Applications/Xcode.app` — user runs or explicitly approves. Keep Command Line Tools installed (currently the selected toolchain; nothing else breaks).
2. **[USER]** Download **Xcode 26.3** (`Xcode_26.3.xip`, ~3.5–4 GB): `https://developer.apple.com/download/all/` → sign in → search "Xcode 26.3" → download. (26.4+ requires macOS Tahoe — do not grab "latest".) Save to `~/Downloads`.
3. **[AGENT]** Expand (peak ~22 GB transient): `xip --expand ~/Downloads/Xcode_26.3.xip` run inside `/Applications` (or expand elsewhere and `mv`), then delete the xip: `rm ~/Downloads/Xcode_26.3.xip`.
4. **[USER]** License + first-run (password): `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`.
   - If the user is unavailable, agents can use full Xcode **without** the xcode-select switch by prefixing every `xcodebuild`/`xcrun` call with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` — but license acceptance is sudo-only and must happen once first.
- **Verify:** `xcodebuild -version` → `Xcode 26.3`; `xcrun --sdk iphoneos --show-sdk-version` → `26.x`.

### B4. iOS 26 simulator runtime (~8–9 GB) — [AGENT]

- `xcodebuild -downloadPlatform iOS` (with `DEVELOPER_DIR` set if B3.4 skipped). Check `df -h /` first; require ≥ 12 GB free.
- Create a work device: `xcrun simctl list runtimes` → note the iOS 26.x runtime id → `xcrun simctl create "SameAge-Dev" "iPhone 16 Pro" <runtime-id>`.
- **Verify:** `xcrun simctl list devices | grep SameAge-Dev` shows the device; `xcrun simctl boot "SameAge-Dev"` boots it.
- Not needed for Phase 0 (archive builds don't need a runtime) or Phase 1 (macOS tests) — can run in parallel with those.

### B5. App Store Connect API key — [USER, 3 min] — unlocks headless signing + upload

- URL: `https://appstoreconnect.apple.com/access/integrations/api` (Users and Access → Integrations → App Store Connect API → **Team Keys** tab) → **+** / Generate API Key → Name: `sameage-agent` → Access/Role: **Admin** (own single-person team; Admin avoids cloud-signing permission edge cases that App Manager keys occasionally hit) → Generate → **Download the `.p8` (one-time download!)** → note the **Key ID** and the page's **Issuer ID**.
- **[USER or AGENT]** Install it:
  ```bash
  mkdir -p ~/.appstoreconnect/private_keys
  mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
  ```
- **[AGENT]** Create `/Users/geoffreydudgeon/repos/kid-scroller/.env` (gitignored):
  ```
  ASC_KEY_ID=<KEYID>
  ASC_ISSUER_ID=<issuer-uuid>
  ASC_KEY_PATH=/Users/geoffreydudgeon/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
  TEAM_ID=R39EF29X3Y
  ```
- This enables `xcodebuild … -allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`: automatic **cloud-managed Apple Distribution certificate** creation, provisioning profile management, bundle-ID registration, and uploads — all headless. (The existing Developer ID cert is Mac-only; irrelevant to iOS. Do not try to use it.)
- **Verify:** Phase 0's archive/upload succeeds; or earlier via a JWT-authenticated `GET https://api.appstoreconnect.apple.com/v1/apps` (script in §7.4).

### B6. App Store Connect app record — [USER, 2 min; cannot be automated]

- The official ASC API has **no create-app endpoint** (fastlane `produce` still uses Apple-ID session auth — impractical headless with 2FA; [fastlane API support table](https://docs.fastlane.tools/app-store-connect-api/)). Browser it is.
- First, bundle-ID registration — **[AGENT]** via ASC API (`POST /v1/bundleIds`, script in §7.4) or automatically during the first `-allowProvisioningUpdates` archive; **or [USER]** at `https://developer.apple.com/account/resources/identifiers/list` → + → App IDs → App → Description `SameAge`, Bundle ID explicit `org.dudgeon.sameage`, no extra capabilities → Register.
- Then: `https://appstoreconnect.apple.com` → **My Apps** → **+** → **New App** → Platform: iOS · Name: `SameAge` (fallbacks per Decision 3 if taken) · Primary language: English (U.S.) · Bundle ID: select `org.dudgeon.sameage` · SKU: `sameage-001` → Create.
- **Verify:** app appears in My Apps with the right bundle ID.

### B7. iPhone-side setup — [USER, 5 min, needs the phone]

- Install **TestFlight** from the App Store; sign in with the same Apple ID (`dudgeon@gmail.com`-associated developer account).
- Report the phone's iOS version (Settings → General → About) — decides Decision 5 confirmation.
- No cable pairing / Developer Mode needed for the TestFlight path. (Direct Xcode debugging becomes possible with Xcode 26.3 + cable + Developer Mode toggle later, if ever wanted; not on the critical path.)
- **Verify:** TestFlight app opens and shows the signed-in account.

### Prerequisite tooling — [AGENT]

- `which xcodegen || brew install xcodegen` (project generation, §3.1). If Homebrew is absent, fall back to hand-authoring `project.pbxproj` (agents can; xcodegen is just cleaner).
- Git: repo exists with zero commits; remote `https://github.com/dudgeon/kid-scroller.git`. First commit lands in Phase 0. Check `gh auth status` before pushing.

---

## 3. Architecture

### 3.1 Project layout

Single app target + one local pure-Swift package. Project generated by **XcodeGen** from a checked-in `project.yml` (reproducible, diff-able, agent-friendly; no GUI needed).

```
kid-scroller/
├── PLAN.md
├── project.yml                     # XcodeGen manifest → SameAge.xcodeproj (generated, gitignored)
├── .env                            # ASC creds (gitignored)
├── .gitignore                      # DerivedData/, build/, *.xcodeproj, .env, xcuserdata
├── ExportOptions.plist             # §7.2
├── Packages/
│   └── SameAgeCore/                # PURE Swift (Foundation only) — tests run on macOS via `swift test`
│       ├── Package.swift
│       ├── Sources/SameAgeCore/
│       │   ├── AgeMapping.swift        # RibbonLayout, RibbonMapping, CombinedMapping (§3.3)
│       │   ├── FeedItem.swift          # models: FeedItem, Kid, MediaKind, FilterState
│       │   ├── AgeFormatter.swift      # fmtAge port ("2y 1m"), age-input parser ("15mo", "2.5y")
│       │   └── AgeMath.swift           # birthday+date → ageMonths (Double)
│       └── Tests/SameAgeCoreTests/     # property + golden tests (§6.1)
├── App/
│   ├── SameAgeApp.swift            # @main, AppState (KidProfile store)
│   ├── Info.plist                  # NSPhotoLibraryUsageDescription, ITSAppUsesNonExemptEncryption=NO,
│   │                               # UISupportedInterfaceOrientations = portrait only
│   ├── Assets.xcassets/            # AppIcon (single-size 1024 placeholder in Phase 0)
│   ├── PhotoLibrary/
│   │   ├── PhotoLibraryService.swift   # auth, user-album discovery, album→[FeedItem]
│   │   ├── LibraryIndexer.swift        # background build/refresh, progress publisher (R24)
│   │   ├── IndexStore.swift            # snapshot cache, protocol + Codable file impl (§3.5)
│   │   └── ChangeMonitor.swift         # PHPhotoLibraryChangeObserver → incremental diffs
│   ├── ImagePipeline/
│   │   └── ThumbnailProvider.swift     # PHCachingImageManager wrapper, preheat window (§3.6)
│   ├── FeedEngine/
│   │   ├── FeedViewModel.swift         # curAge, s, filters, visible windows, sparse flags
│   │   ├── FeedView.swift              # SwiftUI shell: feed + rail overlay + sheets
│   │   ├── FeedUIView.swift            # UIKit core: scroll driver + 2 recycling columns (§3.4)
│   │   ├── AgeRailView.swift           # SwiftUI rail: ticks, pill, scrub gesture (R10/R11, D5)
│   │   ├── AgeInputSheet.swift         # R12, reuses AgeFormatter parser
│   │   └── FilterSheet.swift           # D8 swipe-up sheet (R21/R22)
│   ├── Fullscreen/
│   │   ├── FullscreenView.swift        # pager, metadata overlay (R17), Live Photo (R16)
│   │   ├── CounterpartFinder.swift     # nearest-age item in other ribbon (R18, D7)
│   │   └── ShareComposer.swift         # side-by-side composite via ImageRenderer (R19)
│   ├── Onboarding/
│   │   ├── OnboardingFlow.swift        # welcome → permission → per-kid setup ×2 (R8-rewritten)
│   │   ├── AlbumPickerView.swift       # lists user albums (title, key photo, count)
│   │   └── BirthdayEntryView.swift     # manual date picker + CNContactPickerViewController prefill (R9)
│   ├── Settings/
│   │   └── SettingsView.swift          # birthdays, re-pick albums, rail side (R10), index status
│   └── DebugSeed/                      # DEBUG builds only
│       └── LibrarySeeder.swift         # deterministic simulator library generator (§6.2)
└── scripts/
    ├── asc_api.sh                  # JWT + curl helpers (§7.4)
    └── make_fixture_images.swift   # EXIF-stamped JPEG generator for simctl addmedia (§6.2)
```

`project.yml` essentials: one iOS app target `SameAge`, bundle id `org.dudgeon.sameage`, deployment target iOS 17.0 (Decision 5a), `DEVELOPMENT_TEAM: R39EF29X3Y`, `CODE_SIGN_STYLE: Automatic`, Swift 6 language mode (strict concurrency; PhotoKit callbacks handled with `@MainActor` view models + `Sendable` value types), local package dependency on `SameAgeCore`, unit-test target `SameAgeTests`, UI-test target `SameAgeUITests`.

### 3.2 Data model

```swift
// Persisted in UserDefaults as Codable JSON (tiny), source of truth for setup:
struct KidProfile: Codable, Identifiable {
    var id: UUID
    var name: String                 // onboarding/settings only (D6)
    var birthday: Date               // R9; editable
    var albumLocalIdentifier: String // the chosen PHAssetCollection (Decision 1a)
}
// AppState.kids: [KidProfile] — array, not a pair struct (R7: N-person later); UI enforces count == 2.

// SameAgeCore (pure, Sendable):
enum Kid: Int, Codable { case a = 0, b = 1 }
enum MediaKind: Codable { case photo, livePhoto, video }
struct FeedItem: Codable, Identifiable, Sendable {
    let id: String                   // PHAsset.localIdentifier
    let kid: Kid
    let captureDate: Date
    let ageMonths: Double            // derived: captureDate vs kid birthday (AgeMath)
    let kind: MediaKind
    var isFavorite: Bool             // mutable: R20 write-back
    let aspectRatio: Double          // pixelWidth / pixelHeight (R14 native aspect)
    let location: LocationStub?      // lat/lon if PHAsset.location present (R17)
}
struct FilterState: Codable { var favoritesOnly: Bool; var kinds: Set<MediaKind> } // R21/R22
```

Age measure: `ageMonths = captureDate.timeIntervalSince(birthday) / 2_629_746` (mean-month seconds). Monotonic, timezone-stable, matches the prototype's continuous-months axis. Display formatting goes through `AgeFormatter` (calendar-aware for the "2y 1m" strings).

### 3.3 The mapping core (port of the prototype — SameAgeCore)

Direct ports, JS → Swift, same semantics, exact constants preserved (converted px → points):

| JS reference | Swift | Notes |
|---|---|---|
| `layout(photos)` | `RibbonLayout.build(items:[FeedItem], columnWidth:Double) -> [PlacedItem]` | height = columnWidth / aspectRatio (R14); `top`, `center` cumulative with `GAP = 6`pt; lead-in offset `TAIL * firstAge`. Epsilon-bump duplicate ages so ages are strictly increasing (the JS divides by `q.age - p.age`). |
| `offsetAt(photos, a)` | `RibbonMapping.offset(atAge:) -> Double` | piecewise-linear age→offset through photo centers; `TAIL = 5` pt/month before first & after last anchor. Binary search, O(log n). |
| combined `combS`/`combAges` | `CombinedMapping` | `s(a) = mapA.offset(a) + mapB.offset(a)`. **Improvement over JS:** exact piecewise-linear inverse over the merged breakpoint set (union of both ribbons' anchor ages) instead of the JS's 0.25-month sampled table. Both are monotonic; exactness makes round-trip tests clean. Keep a sampled-table implementation in tests as the reference oracle. |
| `ageFromS(s)` | `CombinedMapping.age(atCombinedOffset:)` | inverse of the above; clamps to `[0, axisMax]`. |
| `nudge(dPx)` D1 branch | *(absorbed into the scroll driver)* | with D1 constant-content-speed, **s is linear in drag distance** — so s IS the scroll offset (§3.4); no per-event math beyond `age(atCombinedOffset:)`. |
| `render()` place | `RibbonMapping.viewportPlacements(age:viewportHeight:) ` | reading line at `0.42 × viewportHeight` (prototype's `cy`); D2 down-direction only (newborn at top). Returns visible index range via binary search + y-positions. |
| sparse detect (`ppm < 16`) | `RibbonMapping.pointsPerMonth(atAge:) < 16` → `isSparse` | drives D3 ghosting per column (R3). |
| `railY/railAge` | `AgeRailScale` | linear age↔y with `PAD = 14`pt (R11 — rail is linear in age regardless of D1). |
| `fmtAge` + input parse | `AgeFormatter` | "2y 1m"/"9m"; parser accepts `15`, `15mo`, `2.5y` (R12). |

Axis: `axisMax = older kid's age today` (months). Younger ribbon simply ends earlier; the `TAIL` extrapolation past its last photo gives the R6 solo-tail behavior for free, and the lead-in handles both-kids-before-first-photo.

R5 (both-kids photo): the same asset appears as two `FeedItem`s (one per kid, different `ageMonths`); natural under the album model since Apple's People albums each include shared photos.

### 3.4 Feed engine — rendering & input (the D1 inversion, concretely)

**Chosen approach: a hidden native `UIScrollView` as the physics driver + two UIKit recycling columns, wrapped once in `UIViewRepresentable`. Not a stock SwiftUI `ScrollView`, not `UICollectionView`.**

Why: (1) D1's key property — combined content offset `s` is *linear* in finger travel — means a single scroll view with `contentSize.height = CombinedMapping.sMax + viewportHeight` gives pixel-perfect native pan, momentum, deceleration, and rubber-banding on `s` for free; reimplementing iOS scroll feel in a gesture canvas is a fool's errand, and two stock scroll/collection views can't share one gesture while moving at different, nonlinearly-related rates. (2) `scrollViewDidScroll` fires per frame (120 Hz): compute `age = combined.age(atCombinedOffset: s)` (O(log n)), then set `frame`/`transform` on ~15–25 pooled `UIImageView`s per column — deterministic, no SwiftUI diffing in the hot path. (3) Programmatic navigation (rail scrub R11, typed jump R12) is just `scrollView.setContentOffset(CGPoint(x:0, y: combined.offset(atAge: a)), animated:)` — rail drags unanimated per-frame, typed jumps animated. (4) Works on iOS 17 (Decision 5a); the pure-SwiftUI equivalent (`ScrollView` + clear spacer + `onScrollGeometryChange`) needs iOS 18 and gives less control — documented as a rejected alternative, revisit only if the bridge fights back.

`FeedUIView` (UIKit) owns: the driver scroll view (transparent, `showsVerticalScrollIndicator = false`, content is one empty sizing view), two `RibbonColumnView`s (view pools keyed by `FeedItem.id`, culling at ±40 pt like the prototype), the D4 gap layout (two columns, no divider line), and the D3 ghost state (column-level `alpha 0.38` + desaturation via `UIImageView` overlay tint when `isSparse`, animated 150 ms). Everything else is SwiftUI: `AgeRailView` overlays the left edge (ticks year-only per D5, pill shows "2y 1m", drag gesture → `feed.setAge(_:animated:false)`), sheets, chrome.

Filters (R22): applying a `FilterState` rebuilds both `RibbonLayout`s + `CombinedMapping` off-main (<10 ms for 20k items), then atomically swaps mappings while preserving `curAge` (recompute `s' = combined'.offset(atAge: curAge)`, set contentOffset without delegate feedback).

Video autoplay (R15): driver reports idle — `scrollViewDidEndDecelerating`/`DidEndDragging(willDecelerate:false)` + no active touch → 1.0 s timer → topmost fully-visible video cell gets an `AVPlayerLayer` (muted, `PHImageManager.requestPlayerItem(forVideo:)`); any scroll/touch tears it down. Live Photos render as stills in feed (R16).

### 3.5 Indexing pipeline (R23–R25, rewritten scale)

Under Decision 1a the "who-appears-when index" collapses to: **enumerate two user albums' asset metadata** — no image I/O, no ML. For albums of even 20k assets this is seconds, not hours; the 100k-asset library matters only to PhotoKit internals and the image pipeline.

- **Fetch:** `PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)` for the picker; per kid, `PHAsset.fetchAssets(in: collection, options: opts)` with `opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]`. `PHFetchResult` is lazy; enumerate once on a background queue mapping to `[FeedItem]` (all fields — `creationDate`, `mediaType`, `mediaSubtypes`, `isFavorite`, `pixelWidth/Height`, `location` — are on `PHAsset`, no asset-resource loading).
- **Persist (IndexStore):** versioned Codable **binary plist/`PropertyListEncoder` snapshot** at `Application Support/index-v1.plist` (~100 B/item → a few MB at 20k items; loads < 100 ms). **Recommendation rationale:** this store is a *disposable cache* — Photos is always the source of truth and a rebuild costs seconds — so SwiftData (iOS-17 maturity issues, background-actor friction, opaque migrations) and Core Data (boilerplate) are over-engineering, and GRDB/SQLite earns its dependency only if per-row incremental writes ever matter. `IndexStore` is a protocol; a GRDB implementation is the documented escape hatch (and becomes the real recommendation if the user picks Decision 1b/1c, where embeddings need a real DB).
- **Launch path (R24):** load snapshot → feed renders immediately → `LibraryIndexer.refresh()` re-enumerates in background → diff by `localIdentifier` → atomic mapping swap preserving `curAge`. First-ever launch shows a determinate progress state ("Indexing Maya's album — 3,412 photos") streamed via `AsyncStream`.
- **Change tracking:** `ChangeMonitor` registers `PHPhotoLibraryChangeObserver`; `changeDetails(for:)` on each album's cached `PHFetchResult` yields inserts/removals/moves + `hasIncrementalChanges`; map to index updates, re-snapshot, swap. Favorite toggles from within the app (R20) round-trip through this same path.
- **iCloud (R25):** handled in the image pipeline (§3.6), not the index — metadata enumeration never triggers downloads.

### 3.6 Image pipeline

- One `PHCachingImageManager`. Feed thumbnails: `deliveryMode = .opportunistic` (degraded-then-full — the degraded frame IS the R25 placeholder), `resizeMode = .fast`, `isNetworkAccessAllowed = true`, target size = column width × aspect × screen scale.
- **Preheat window:** on age change, compute each ribbon's visible range ± 1.5 viewports via the mapping's binary search; `startCachingImages` for entering assets, `stopCachingImages` for leaving; full `stopCachingImagesForAllAssets()` on filter swap or > 3-viewport jump (rail scrubs/typed jumps).
- Fullscreen: `.highQualityFormat` + `progressHandler` driving a download-progress ring for iCloud assets; `PHLivePhotoView` for Live Photos (R16); `requestPlayerItem` for videos.
- Memory: pooled image views hold only visible thumbs; `NSCache` byte-capped (~64 MB) for decoded fulls.

### 3.7 Fullscreen, counterpart, share (R17–R19, D7)

- `CounterpartFinder.counterpart(for item: FeedItem, in otherRibbon:) -> FeedItem?` — binary search nearest `ageMonths` (ties → earlier). Nil past the younger kid's range → no inset (R6 tail).
- Fullscreen: horizontal pager across the tapped ribbon (age order), metadata footer (date via `DateFormatter.long`, age via `AgeFormatter`, place via one-shot `CLGeocoder` reverse geocode, cached by asset id, silent-fail). Inset bottom-right 96×128 pt, tap swaps roles (D7) — swap = swap which ribbon the pager drives, inset shows the other.
- Share (R19): `ShareComposer` renders `SharePairView` (SwiftUI: two images side-by-side at native aspect, equal heights, age captions — ages only, per D6 no names) via `ImageRenderer` at 2048 px wide → `UIActivityViewController`.
- R20: the only write: `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).isFavorite = newValue }` — which is why authorization requests `.readWrite` (§3.8).

### 3.8 Onboarding & settings (R8-rewritten, R9, R10)

Flow: Welcome (concept, one screen) → `PHPhotoLibrary.requestAuthorization(for: .readWrite)` → **per kid ×2:** "Create the album" instruction screen (illustrated steps: Photos → search/People → the kid → select all → Add to Album → `SameAge – <name>`; with an "I already have an album" skip) → `AlbumPickerView` (user albums, key-photo thumbnail + count) → name + birthday (`BirthdayEntryView`: date picker; "Prefill from Contacts" uses `CNContactPickerViewController` — out-of-process, **no Contacts permission needed**, reads `birthday` from the picked card, always editable per R9) → done → index build → feed.
Degraded states: `.limited` authorization → explainer + "Open Settings" deep link (`UIApplication.openSettingsURLString`) — limited mode can't see full albums, app requires full access; `.denied` similarly. Album later deleted/emptied → Settings badge + re-pick flow.
Settings: edit names/birthdays, re-pick albums, **rail side toggle** (R10: default left; toggle flips `AgeRailView` + column insets), index status + manual refresh + "last refreshed" staleness hint (Decision 1a maintenance), About.

---

## 4. Requirement traceability

| Req | Status | Where satisfied / disposition |
|---|---|---|
| R1 | Build | Shared age axis = `CombinedMapping` over both `RibbonMapping`s (§3.3); no pair objects anywhere. |
| R2 | Build | Density-proportional per-ribbon rate is inherent to the piecewise age↔offset mapping (§3.3). |
| R3 | Build | `TAIL`/interpolation makes sparse spans crawl; never blank mid-timeline (§3.3); ghost per D3 (§3.4). |
| R4 | **REWRITTEN** (Decision 1) | No public People API — confirmed (§1.2). New text: *"Person identification relies on Apple's People detection indirectly: the user materializes each kid's People album into a standard Photos album via Photos.app; SameAge reads those user albums via PhotoKit. No custom face recognition. Gaps from missed infant detection are accepted."* |
| R5 | Build | Shared asset → one `FeedItem` per kid at each kid's own age (§3.3); People albums both contain shared photos. |
| R6 | Build | `axisMax` = older kid's current age; tail extrapolation → older-solo scrolling (§3.3). |
| R7 | Build | `AppState.kids: [KidProfile]`, `FeedItem.kid`, mappings per-ribbon — N-safe core; UI hardcodes 2 (§3.2). |
| R8 | **REWRITTEN** (Decision 1) | "Pick from the iOS People list" impossible. New: permission → instruction screen → pick each kid's **user album** (§3.8). |
| R9 | Build | Manual birthday entry + `CNContactPickerViewController` prefill (permissionless); always editable (§3.8). Spec's own note stands: PhotoKit exposes no birthdays. |
| R10 | Build | Rail defaults left; Settings toggle (§3.8). |
| R11 | Build | `AgeRailScale` linear scrub → `setAge(animated:false)` (§3.3/§3.4) — independent of D1, as required. |
| R12 | Build | `AgeInputSheet` + `AgeFormatter` parser (`15`, `15mo`, `2.5y`) → animated jump (§3.4). |
| R13 | Honored | No zoom / tolerance / freeze anywhere in v1. |
| R14 | Build | Height = columnWidth / aspectRatio, no cropping (§3.3). |
| R15 | Build | Idle-detect (end-decel + touch-up) → 1.0 s timer → muted autoplay of visible video (§3.4). |
| R16 | Build | Stills in feed; `PHLivePhotoView` motion only fullscreen (§3.6/§3.7). |
| R17 | Build | Fullscreen metadata: date, age-at-capture, reverse-geocoded place when `PHAsset.location` present (§3.7). |
| R18 | Build | `CounterpartFinder` nearest-age inset, D7 bottom-right tap-to-swap (§3.7). |
| R19 | Build | `ShareComposer` composite, ages labeled, system share sheet (§3.7). |
| R20 | Build | Only write = `isFavorite` via `PHAssetChangeRequest`; `.readWrite` auth (§3.7/§3.8). |
| R21 | Build | Favorites + media-type filters in D8 sheet (§3.4). |
| R22 | Build | Filter = pool narrowing + full mapping rebuild; zero pair logic (§3.4). |
| R23 | **DOWNSCOPED** (consequence of R4 rewrite) | The heavyweight who-appears-when index is moot under 1a; remaining first-class piece = album snapshot + change tracking (§3.5). 100k-library target still honored where it bites: lazy fetches, no full-library enumeration, caching image manager. |
| R24 | Build (reduced) | Snapshot-first launch, background refresh, progress UI (§3.5) — "usable immediately, refines" preserved even though full builds now take seconds. |
| R25 | Build | `isNetworkAccessAllowed`, opportunistic degraded placeholders, fullscreen progress ring (§3.6). |
| OOS list (§09 of spec) | Honored | Location filter, N-person, iPad/landscape, tolerance, freeze, infant-fallback tagging, semantic filters — all absent from v1; architecture notes for N-person (R7) and hybrid ML (Decision 1c) only. |

---

## 5. Phased build plan

Rules: every phase ends with its **exit criteria demonstrably true** (command output and/or screenshot via the iOS Simulator MCP `control{action:"screenshot"}`), a green build, and a git commit + push. Phases 1 and 0 are intentionally parallelizable with the B-blockers: Phase 1 needs no Xcode at all.

### Phase 0 — Delivery-chain de-risk: "hello world" on TestFlight FIRST
- **Entry:** B1, B2, B3, B5, B6 complete (B4 *not* required — archives don't need a simulator runtime). Decisions 3 & 5 answered.
- Work: `.gitignore` + first commit; `project.yml` + XcodeGen; minimal SwiftUI app (title screen "SameAge"); portrait-only + `NSPhotoLibraryUsageDescription` + `ITSAppUsesNonExemptEncryption=NO` in Info.plist; placeholder 1024 px single-size AppIcon (scripted solid-color PNG — upload validation requires an icon); version 0.1.0; archive + upload per §7 runbook steps 7–9; create internal group "Family" with **automatic distribution enabled** (every future build lands on testers with zero clicks); user installs on iPhone.
- **Exit:** the app launches from TestFlight on the physical iPhone (user confirms with a screenshot/photo); `main` pushed to GitHub.
- De-risks: membership, cloud signing, cert creation, upload pipeline, ASC processing, TestFlight install — before any feature work exists to be blocked by them.

### Phase 1 — SameAgeCore: the mapping math (no Xcode, no simulator — can start TODAY)
- **Entry:** none (Command Line Tools' `swift` suffices; package is macOS-testable pure Swift).
- Work: `Package.swift`; port per §3.3 table; `AgeFormatter` + parser; `AgeMath`; test suite per §6.1 including the JS-oracle golden tests and the deterministic demo dataset generator (GAP 30 mo, Kid B sparse window 30–42 mo, shared photos at A-ages 36/44/58/70/79 — mirrors the prototype's seeds).
- **Exit:** `cd Packages/SameAgeCore && swift test` fully green on macOS; property tests (monotonicity, inverse round-trip ≤ 1e-9, R3 crawl bound, R6 tail) pass.

### Phase 2 — Simulator bootstrap: seeded library → first real feed
- **Entry:** Phase 0 + 1 done; B4 done (runtime + `SameAge-Dev` device).
- Work: `LibrarySeeder` (DEBUG-only, §6.2) creating deterministic assets + the two `SameAge – Kid` albums; `PhotoLibraryService` + `IndexStore` + `LibraryIndexer`; minimal `FeedUIView` (driver + columns, thumbnails via `ThumbnailProvider`, no rail yet); temporary hardcoded `KidProfile`s.
- **Exit:** app builds & runs on `SameAge-Dev`; after seeding, both ribbons render age-aligned thumbnails and scroll with momentum; screenshots at ages 12 mo / 36 mo (Kid B ghosting visible in its sparse window) captured via simulator MCP and eyeballed against the prototype's behavior.

### Phase 3 — Full feed engine
- **Entry:** Phase 2.
- Work: age rail (D5 ticks, pill, scrub R11, side toggle R10), typed-age jump (R12), D3 ghost animation, filter sheet (D8, R21/R22 rebuild-and-swap), R6 tail behavior, preheat window tuning, change observer wiring, snapshot-first launch (R24).
- **Exit:** scripted walkthrough on simulator: scrub to 3y → Kid B ghosted; favorites filter → both ribbons re-align; typed "2.5y" → animated jump; kill + relaunch → feed restores in < 1 s from snapshot at last age. Screenshots committed under `docs/checkpoints/phase3/` — they are small and they are the verification record.

### Phase 4 — Fullscreen, counterpart, share, media
- **Entry:** Phase 3.
- Work: fullscreen pager + metadata (R17), counterpart inset + swap (R18/D7), share composite (R19), favorite toggle + write-back + observer round-trip (R20), video idle autoplay (R15), Live Photo fullscreen (R16), iCloud progress ring (R25 — simulatable only partially; flagged for Phase 6 device validation).
- **Exit:** simulator demo: tap photo → fullscreen with correct age; tap inset → swap; share sheet shows composite (save to Files, inspect image); favorite in-app → visible in simulator Photos app and vice versa.

### Phase 5 — Onboarding, settings, polish
- **Entry:** Phase 4.
- Work: onboarding flow (§3.8) incl. limited/denied states; Contacts prefill; settings; dark mode pass; basic Dynamic Type on chrome text; real app icon; empty/error states (album deleted, zero-photo album).
- **Exit:** delete app → reinstall → complete onboarding cold using only seeded albums → feed works; `.limited` grant path shows the guidance screen (toggle via `xcrun simctl privacy SameAge-Dev revoke photos org.dudgeon.sameage` + re-grant limited in-app).

### Phase 6 — Real-library hardening on the user's iPhone
- **Entry:** Phase 5; user has performed the Decision 1a album setup in Photos.app on the phone (5 min/kid).
- Work: TestFlight build → user runs onboarding against real albums; measure: cold index time, scroll frame pacing (dropped-frame feel), iCloud fetch behavior on cellular/Wi-Fi, memory. Fix what the numbers say (likely: preheat window size, snapshot decode, geocode throttling).
- **Exit:** user sign-off on the phone: smooth scroll through both kids' full ranges, sparse stretch behaves, share composite exports. v0.1.0 tagged. Optional: add family as testers (§7 runbook step 12).

Estimated effort (agent-days, rough): P0 0.5–1 · P1 1–1.5 · P2 1–2 · P3 2–3 · P4 2–3 · P5 1.5–2 · P6 1–2 + user time. Calendar time dominated by B0–B6 user actions and ASC processing waits.

---

## 6. Testing strategy

### 6.1 Unit tests without any photos (SameAgeCore, runs on macOS)
- **Property tests:** `offset(atAge:)` strictly increasing; `CombinedMapping` round-trip `age(offset(a)) == a` within 1e-9 across random fixtures; filter subsets preserve monotonicity; R3: inside a sparse window `pointsPerMonth == TAIL·(something ≤ threshold)` bound; R6: ages past younger max map at exactly `TAIL` pt/month.
- **Golden oracle vs the JS prototype:** one-time, an agent runs the spec's `<script>` functions in `node` (extract `layout/offsetAt/ageFromS` verbatim, feed the deterministic seed `20260804` dataset, dump `(age → offA, offB, s)` at 0.25-mo steps to JSON) → commit as `Tests/.../Fixtures/js_oracle.json`; Swift tests assert parity within float tolerance. This pins the port to the reference implementation the user already approved by feel.
- Parser/formatter table tests (`"15" → 15 mo`, `"2.5y" → 30 mo`, `"9m" → "9m"`, `"25mo" → "2y 1m"`).

### 6.2 Simulator with a controlled photo library
- **Primary: in-app `LibrarySeeder` (DEBUG only)** — bulletproof and deterministic. Generates gradient JPEGs in-process and inserts via `PHPhotoLibrary.performChanges` using `PHAssetCreationRequest` with **`creationRequest.creationDate = <computed>`** (exact control, no EXIF trust), sets `isFavorite` on ~16%, marks ~12% as videos (tiny generated `AVAssetWriter` clips), then creates albums `SameAge – Kid A/B` via `PHAssetCollectionChangeRequest` and inserts memberships — including the 5 shared assets in both albums. Profile mirrors Phase 1's demo dataset, so simulator behavior is comparable to the JS prototype. Trigger: launch argument `-seedLibrary`, i.e. `xcrun simctl launch SameAge-Dev org.dudgeon.sameage -seedLibrary 1`.
- **Permissions without UI:** `xcrun simctl privacy SameAge-Dev grant photos org.dudgeon.sameage` before launch (UI tests also carry an interruption monitor as fallback).
- **Secondary: `simctl addmedia` bulk path** — `scripts/make_fixture_images.swift` (ImageIO, sets `kCGImagePropertyExifDictionary.DateTimeOriginal`) → `xcrun simctl addmedia SameAge-Dev fixtures/out/*.jpg`. **Unverified assumption to check when first used:** simulator Photos honors EXIF DateTimeOriginal as `PHAsset.creationDate` (believed true; if false, the in-app seeder remains the only path — acceptable).
- **Reset between runs:** `xcrun simctl erase SameAge-Dev` (nukes library + permissions) — cheap and total.
- **Simulator caveat (why Decision 1a is also the testability decision):** the simulator's Photos does **not** run People face clustering — options 1b/1c would be untestable in-simulator; albums are fully scriptable.

### 6.3 Integration & UI tests
- `SameAgeTests` (host app, simulator): `PhotoLibraryService` against the seeded library — album discovery, item mapping correctness (count, dates→ages, favorites, shared-asset duplication), snapshot save/load round-trip, change-observer diff on album edit.
- `SameAgeUITests` (thin — 3 smoke tests): cold-launch-to-feed, scroll + rail scrub doesn't crash and age pill updates, tap-to-fullscreen-and-back. Screenshot checkpoints handled outside XCUITest via the simulator MCP (faster iteration, agent-verifiable): standard checkpoint set = ages {3 mo, 12 mo, 36 mo (sparse), axisMax} × {all, favorites} in light + dark.
- **Not covered pre-device:** true iCloud download behavior, 100k-library perf, thermal — explicitly deferred to Phase 6 on hardware.

---

## 7. TestFlight runbook (end-to-end)

One-time steps marked ①; per-release steps marked ⟳.

1. ① **[USER]** B1 membership verify + ASC agreement banners.
2. ① **[USER]** B2 macOS 15.7.x → B3 Xcode 26.3 (with agent assists) → **[AGENT]** B4 runtime.
3. ① **[USER]** B5 API key → **[AGENT]** install key + `.env`.
4. ① **[AGENT]** Register bundle ID `org.dudgeon.sameage` (§7.4 script or first archive's `-allowProvisioningUpdates`).
5. ① **[USER]** B6 create app record in ASC.
6. ① **[USER]** B7 TestFlight app on iPhone.
7. ⟳ **[AGENT]** Build & archive (from repo root; `source .env` first):

```bash
xcodegen generate
xcodebuild -project SameAge.xcodeproj -scheme SameAge \
  -destination 'generic/platform=iOS' \
  -archivePath build/SameAge.xcarchive archive \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
```

8. ⟳ **[AGENT]** Export & upload in one step — `ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>R39EF29X3Y</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><true/>
</dict></plist>
```

```bash
xcodebuild -exportArchive \
  -archivePath build/SameAge.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
```

   Notes: `method: app-store-connect` is the current name (`app-store` is the deprecated alias). `manageAppVersionAndBuildNumber` auto-bumps the build number against ASC — no manual `agvtool`. First run mints a **cloud-managed Apple Distribution certificate** — no Keychain wrangling, no Apple ID in Xcode. If upload fails validation, the error text names the fix (icon, Info.plist keys, agreement pending).

9. ⟳ **[AGENT]** Wait for processing (5–30 min): poll §7.4's `builds` query until `processingState=VALID`, or **[USER]** watches ASC → TestFlight → iOS Builds.
10. ① **[USER or AGENT-via-API]** ASC → TestFlight → Internal Testing → **+** group `Family` → enable **automatic distribution** → add tester (the account holder). Agent path: `POST /v1/betaGroups`, `POST /v1/betaTesters` with the API key.
11. ⟳ **[USER]** iPhone: TestFlight shows the build (push arrives automatically for internal groups; export compliance never prompts thanks to `ITSAppUsesNonExemptEncryption=NO`) → Install → launch. Builds expire after 90 days.
12. Later, family/friends at arm's length: either add each as ASC users (internal, ≤ 100, instant) — fine for spouses, weird for friends — or ① create an **external** group + public link (≤ 10,000): first build per version needs **Beta App Review** (~1–2 days, needs a beta description + contact info) **[USER submits, 5 min]**. Recommendation: internal-only until v0.2 is worth strangers' phones.

### 7.4 `scripts/asc_api.sh` (agent writes in Phase 0)

ES256 JWT (`iss=$ASC_ISSUER_ID`, `kid=$ASC_KEY_ID`, `aud=appstoreconnect-v1`, 15-min exp; `openssl` or tiny Swift script) + curl helpers:
`asc get /v1/apps` (smoke-test the key) · `asc post /v1/bundleIds '{"data":{"type":"bundleIds","attributes":{"name":"SameAge","identifier":"org.dudgeon.sameage","platform":"IOS"}}}'` · `asc get "/v1/builds?filter[app]=<appId>&sort=-uploadedDate&limit=1"` (processing poll) · beta-group/tester management per step 10.

---

## 8. Risk register (ranked)

| # | Risk | L×I | Mitigation |
|---|---|---|---|
| 1 | **Disk exhaustion** mid-toolchain-install (19 GB free vs ~35 GB peak need) | High×High | B0 gate ≥ 35 GB before B3; strict order (delete 16.3 → xip → expand → delete xip → runtime); `df` check + fail-stop before every download; Decision 2c (Xcode Cloud) as escape hatch. |
| 2 | **User picks Decision 1b** (custom ML) | Med×High | Recommendation + effort delta (+2–4 wks) stated up front; 1a architecture is 1c-forward-compatible so "start with 1a" loses nothing. |
| 3 | Membership not actually active / agreements pending | Low×High | B1 is step zero; strong prior from the 2026 Developer ID cert; Phases 1–5 proceed regardless. |
| 4 | Xcode 26.3-on-Sequoia path has a snag (e.g., 15.7.x raises its own floor, download friction) | Low-Med×High | All version floors verified against the release table; if 15.x can't run any Xcode 26 → Decision 2b (Tahoe) or 2c (Xcode Cloud). |
| 5 | Album-approach staleness (new photos never appear) — product risk of Decision 1a | High×Med | Honest UX: Settings "last refreshed" + re-add instructions; v2 = Decision 1c suggestion queue; set user expectation now, in this plan. |
| 6 | Feed perf on device (120 Hz, big albums, iCloud stalls) | Med×Med | Hot path is UIKit + O(log n) math + pooled views; preheat window; Phase 6 exists precisely to measure on hardware before sign-off. |
| 7 | App name "SameAge" taken in ASC | Med×Low | Fallback names (Decision 3); TestFlight-internal doesn't care about marketing polish. |
| 8 | `simctl addmedia` ignores EXIF dates | Med×Low | Primary seeding is the in-app seeder with explicit `creationDate` — addmedia is a convenience only (§6.2). |
| 9 | Photos.app click-path instructions drift (iOS 26 Photos redesign) | Med×Low | Onboarding copy kept generic + Phase 6 validates on the user's actual iOS version; screenshots in onboarding marked as illustrative. |
| 10 | User's iPhone on iOS < 17 | Low×Med | Deployment target 17.0 (Decision 5a); B7 reports the version before Phase 0 ships anything. |
| 11 | ASC upload validation surprises (icon, privacy keys) | Low×Low | Phase 0 exists to flush these with a trivial app; icon + `ITSAppUsesNonExemptEncryption` handled preemptively. |
| 12 | Swift 6 strict-concurrency friction with PhotoKit callbacks | Med×Low | Pattern fixed in §3.1 (`@MainActor` VMs, `Sendable` value types, `AsyncStream` bridges); worst case: targeted `@preconcurrency import Photos`. |

---

## Appendix A — Research sources

- People/faces API absence: [Apple Dev Forums 126711 — Access face tags](https://forums.developer.apple.com/forums/thread/126711) · [Apple Dev Forums 688345](https://developer.apple.com/forums/thread/688345) · [Kyle Howells — Querying the iOS Photo Library](https://ikyle.me/blog/2025/querying-the-ios-photo-library) · [objc.io — The Photos Framework](https://www.objc.io/issues/21-camera-and-photos/the-photos-framework/)
- iOS 26-era PhotoKit changes (no People API added): [9to5Mac — iOS 26.1 background photo backup extension](https://9to5mac.com/2025/10/24/ios-26-1-third-party-photos-backup-background/) · [TechCrunch — WWDC 2025 Photos app](https://techcrunch.com/2025/06/09/apple-brings-back-tabs-to-the-photos-app-in-ios-26)
- Vision scope (detection yes, identity no): [Bitcot — Vision Framework guide 2026](https://www.bitcot.com/vision-framework-in-swift-for-ios-development/) · [it-jim — Apple Vision Framework](https://www.it-jim.com/blog/apple-vision-framework/)
- Upload mandate & versions: [Apple — Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/) · [Xcode version/macOS floor table](https://mungomash.com/software/xcode/versions/) · [Apple Dev Forums 806141 — 2026 Xcode mandate clarification](https://developer.apple.com/forums/thread/806141)
- TestFlight & automation: [ASC Help — Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) · [ASC Help — TestFlight overview](https://www.developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview) · [fastlane — App Store Connect API](https://docs.fastlane.tools/app-store-connect-api/) · [AppConsul — ASC API key setup](https://appconsul.com/guides/app-store-connect-api-key-setup/)
