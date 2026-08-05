# SameAge — session handoff

**Last updated:** 2026-08-05, immediately before the macOS Tahoe 26 upgrade.
**Read this first, then [PLAN.md](PLAN.md) for the full architecture and TestFlight runbook.**

---

## 1. Resume in one minute

```bash
cd /Users/geoffreydudgeon/repos/kid-scroller
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # see §2 — may be unnecessary after the upgrade
swift test --package-path Packages/SameAgeCore                    # expect 44 tests, 0 failures
xcodegen generate                                                 # SameAge.xcodeproj is gitignored/generated
```

**First things to check after the Tahoe upgrade** (in this order):

1. `sw_vers -productVersion` → expect `26.x`.
2. `xcodebuild -version` → **if this still says 16.3, Xcode 26.6 is not installed yet.** Install it, then
   `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (needs the user's password — the agent cannot run it).
3. `xcrun --sdk iphoneos --show-sdk-version` → must be `26.x` before *any* TestFlight attempt.
4. Simulator runtimes: `xcrun simctl list runtimes`. The old iOS 18.4 device may not survive the upgrade; recreate with
   `xcrun simctl create "SameAge-Dev" "iPhone 16 Pro" <runtime-id>`.
5. **Confirm Apple Developer Program membership** at `developer.apple.com/account` → Membership details.
   The user reports being signed in already; this was never actually verified in-session and is still open (task #1).

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

| # | Work | Blocked by |
|---|---|---|
| 5 | Image pipeline — `PHCachingImageManager`, opportunistic delivery as the R25 iCloud placeholder. Cells are still coloured placeholders. | nothing |
| 5 | Contacts birthday prefill (R9) — the picker exists, `CNContactPickerViewController` prefill does not | nothing |
| 6 | Fullscreen (R17), counterpart inset + tap-to-swap (D7/R18), share composite (R19), Live Photo motion (R16) | nothing |
| 5 | Index persistence — `IndexStore` snapshot so launch is instant (R24). Currently re-enumerates each launch. | nothing |
| — | Settings screen — edit birthdays, re-pick albums, rail side toggle (R10) | nothing |
| — | Video autoplay (R15) — `onSettled` already fires correctly after 1s idle; no `AVPlayerLayer` attached yet | nothing |
| 7 | **TestFlight** | Xcode 26 + membership confirmation |

### Critical path to TestFlight

App Store Connect has **rejected uploads not built with Xcode 26 / iOS 26 SDK since 2026-04-28**
([Apple](https://developer.apple.com/news/upcoming-requirements/)). Xcode 16.3 cannot ship — this is why the plan's
"Phase 0 hello-world to TestFlight first" ordering was abandoned. **The signing/upload chain is still completely
unproven.** Prove it with a throwaway archive as soon as Xcode 26.6 is in place, before building more features.

Then, per PLAN.md §7: App Store Connect API key → `~/.appstoreconnect/private_keys/` + `.env` → register
`org.dudgeon.sameage` → create the app record in the browser (no ASC API endpoint exists for this) → archive with
`-allowProvisioningUpdates` → `xcodebuild -exportArchive` with `destination: upload` → internal TestFlight group.
`ITSAppUsesNonExemptEncryption=NO` is already set, so no export-compliance prompt per upload.

---

## 6. Open questions for the user

1. **Apple Developer Program membership** — believed active (a Developer ID cert was issued to team `R39EF29X3Y`
   on 2026-04-26, and those are paid-members-only), but never confirmed on the membership page.
2. **Deployment target** is iOS 17.0; the phone runs iOS 18.x, so this is safe but could be raised.
3. **Nothing is committed.** The repo has zero commits. Worth doing before or right after the upgrade.
