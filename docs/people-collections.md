# Getting People collections into the picker — research

**Goal:** let the user pick a *person* (the Photos app's People & Pets tiles) as a kid's
photo source, instead of manually materialising an album.

**Ground truth, unchanged since the original R4 finding:** PhotoKit exposes no People
API. No `PHAssetCollectionSubtype` for People, no person predicate, blocked even via
private API, and nothing in the iOS 26 SDK changed it. The `collections()` walk in
`PhotoLibraryService` already covers every collection type PhotoKit can enumerate —
People is structurally absent, not merely unlisted. Any route to People data is therefore
a *side door*, and there are exactly three plausible ones.

## Route B — Shortcuts automation (check first; 30 seconds, zero code if it works)

**IF** the Shortcuts app's *Find Photos* action offers a **Person** filter, then a
two-action shortcut — `Find Photos where Person is Owen` → `Add to Album "Owen"` — fully
automates both the initial album build and the refresh, using Apple's own face
clustering, schedulable nightly via a personal automation.

**Status: unverified.** Apple's [filter-parameters documentation](https://support.apple.com/guide/shortcuts/add-filter-parameters-apdbdab3433f/ios)
lists examples (Album, media type, dates) but is not exhaustive about Person, and an
attempt to check empirically on the Mac's Shortcuts app wasn't possible this session.

**The check (on the iPhone):** Shortcuts → **+** → add action → **Find Photos** →
**Add Filter** → does the filter list offer **Person / People**?
- Yes → build nothing; ship a preconfigured shortcut per kid and a Settings pointer.
- No → Route A.

## Route A — the system photo picker (`PHPickerViewController`)

The out-of-process picker needs **no photo permission**, and configured with
`PHPickerConfiguration(photoLibrary: .shared())` it returns **asset identifiers** the
app can then use with PhotoKit ([Apple docs](https://developer.apple.com/documentation/photosui/phpickerviewcontroller),
[WWDC21](https://developer.apple.com/videos/play/wwdc2021/10046/)). The picker has a
search field; if searching "Alina" surfaces her People results (believed but **not
verifiable from documentation**, and untestable in the simulator, which runs no face
clustering), the flow becomes:

> Settings → "Add photos of Alina" → picker opens → search her name → drag-select →
> identifiers stored directly. **No Photos album needed at all.**

This would replace the album model, not just feed it: `KidProfile` gains an
identifier-list source alongside the album source. Costs: no select-all in the picker
(drag-select is quick but real effort at thousands of photos); refresh means reopening
the picker (preselection marks what's already in — noting a
[reported iOS 26.1 preselection regression](https://developer.apple.com/forums/thread/819355)).
Quick reality check without writing code: any app using the system picker (Messages →
attach photo) has the same search box — try a name there.

## Route C — Mac-side `osxphotos` (plan option 1d; most setup, fully automatic after)

Reads the Photos library database on the Mac, extracts person→asset lists, creates and
refreshes per-person albums via AppleScript; albums sync to the iPhone over iCloud.
Schedulable with launchd. Requires the Mac's library to be synced and access to the
Photos database (blocked by session policy earlier; the user can run the script
themselves or allowlist it). Fragile against Photos schema changes, but the tool is
actively maintained.

## Recommendation

**B → A → C.** Do the 30-second Shortcuts check first — if Person is there, the whole
problem dissolves with no app changes. Otherwise build Route A's picker flow (roughly a
day: picker sheet, identifier-list source in KidProfile, indexer support). Keep C for
power users with big libraries if A's drag-select proves too painful.
