# AI Agent Handoff

## Identity / Constraints

- Repo: `https://github.com/kGMia/EhViewer-Apple-native`; upstream: `https://github.com/felixchaos/EhViewer-Apple`; author `kGMia`, upstream author `felixchaos`; Apache-2.0.
- Branch at handoff: `codex/reader-cache-stability`. Worktree is intentionally dirty (many user-owned edits); **never reset/checkout/rewrite unrelated changes**. `ehviewer apple/NativeGalleryContextMenu.swift` is currently untracked but required.
- Swift 6, SwiftUI-first, Xcode/OS target 26.2+, iOS+iPadOS+macOS. User normally performs runtime/UI testing; run targeted compile checks, not exhaustive testing unless needed.
- Build: `xcodebuild -project 'ehviewer apple.xcodeproj' -scheme 'ehviewer apple' -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`; macOS destination `platform=macOS`.

## Structure

- App entry/navigation: `ehviewer apple/ehviewer_appleApp.swift` → `RootView.swift` → `MainTabView.swift`.
- Main UI: `GalleryListView.swift`, `GalleryDetailView.swift`, `GalleryCommentsView.swift`, `PreviewView.swift`, `ImageReaderView.swift` + `ReaderViewModel.swift`, `SearchView.swift`, `SettingsView.swift`, `DownloadView.swift`.
- App services: `GalleryActionService.swift`, `AppIntentsSupport.swift`, `UIPolisher.swift`, localization under `en.lproj`, `zh-Hans.lproj`, `zh-Hant.lproj`.
- Packages: `EhCore` = models/GRDB/settings; `EhNetwork` = API/cookies/DNS; `EhParser` = HTML parsing; `EhSpider` = gallery image retrieval; `EhDownload` = actor-based downloads; `EhUI` = shared UI.
- Release docs: `README.md`, `CHANGELOG.md`, `RELEASE_CHECKLIST.md`, `PrivacyInfo.xcprivacy`.

## Implemented State (summary)

- Responsive native navigation: iPhone single-column, iPad/macOS adaptive split; home/subscription/search/my, favorites/download/history/watch-later; search has persistent results, nested search history/back stack, continuous pagination and position restoration.
- Gallery feed: list + proportional masonry, hover/context actions, local watch-later, favorite/download/share; detail has compact Liquid Glass header, ambient cover glow, tags/voting/comments/link handling, preview paging and reverse loading.
- Reader: horizontal/vertical, LTR/RTL, single/double page, first-page-alone, gestures/keyboard/haptics/animation/fullscreen, local/original image, animated images, OCR/system translation, configurable background/accent-colored progress, adaptive prefetch/cache.
- Downloads: pause/resume/delete/select/location/filesize, Live Activity actions/deep link. Settings are reactive; app lock removed. App Shortcuts/macOS menus/Handoff/localization (zh-Hans/zh-Hant/en) added.
- Performance/stability: bounded/retry-safe network layer, background parsing/decoding/keychain/cache work, request coalescing/cancellation, separate cache budgets, memory-pressure handling, cookie/QoS fixes, release diagnostics/privacy work.
- Recent native migrations: login uses SwiftUI `WebView`/`WebPage`; logs use SwiftUI `fileExporter`; iOS feed context menu uses UIKit preview (list previews whole row, masonry previews cover+marquee), macOS uses prebuilt `NSMenu`; comment composer is one glass capsule with 38pt close/send controls (mobile send = circular icon).
- Current iOS context-menu behavior: native SwiftUI `contextMenu` owns source lift/return. List uses the default snapshot; waterfall provides a SwiftUI cover + live scrolling-title preview. No UIKit preview controller, transparent interaction overlay, or manual visibility state remains. macOS keeps a cached AppKit menu.

## Known / Verify Next

- Runtime-verify system context-menu lift/return, cancel, action selection and repeated press on iOS/iPadOS; see `GalleryActionMenu` in `NativeGalleryContextMenu.swift`.
- First-ever system context-menu/share invocation can still stall on some devices (UIKit service initialization); intentionally deferred rather than degrading native menu UX.
- Waterfall now uses lazy columns and a full ordered-data cache key. Targeted tests cover interior sorting and append stability; runtime-verify favorites sorting, cross-page scrolling, rotation/window resizing and visible-footer pagination.
- Image quota: IP-based accounts may legitimately expose “no restrictions” without numeric used/limit; do not fabricate quota values.
- Release risk: E-Hentai content may require separate App Store policy review. README has some legacy lower sections (e.g. old minimum OS/app-lock wording); trust top v1.0 section/current code and clean stale documentation before release.
- Upstream changes must be reviewed/cherry-picked selectively; do not wholesale merge over this fork’s navigation/UI/concurrency changes.

## Editing Rules

- Prefer SwiftUI/system APIs and shared cross-platform code; isolate UIKit/AppKit only where SwiftUI lacks behavior. Preserve native navigation gestures and Liquid Glass conventions.
- Settings must update live; keep I/O/network/image decode off MainActor; honor cancellation and never auto-retry mutating requests (comment/vote/favorite).
- Maintain all three localizations and update `CHANGELOG.md`. Do not commit/push unless explicitly requested.

## 2026-09-05 interaction follow-up

- Removed the dummy URL share-controller pool and launch-time `loadViewIfNeeded()`. Each UIKit gallery share uses an immutable real URL with local `LPLinkMetadata`; both detail layouts use `GalleryShareLink` with a URL payload and explicit `SharePreview`.
- Feed sharing now waits for the context-menu dismissal completion. Source restoration captures the callback belonging to the presented row.
- Context preview uses `.secondarySystemGroupedBackground` instead of a nested `UIGlassEffect`; the system context menu remains native. Marquee respects Reduce Motion. This supersedes the earlier glass-preview/share-prewarming notes above.
- Added `GalleryShareControllerBuild` signpost alongside existing preview/presentation intervals. No device Instruments measurements yet: do not treat system first-use latency as proven fixed. Runtime-check fresh launch → first list/masonry long press, cancel, menu share, direct detail share, second gallery sharing, and iPad popover anchoring.

## 2026-09-05 source-restoration follow-up

- User confirmed first-use context-menu/share stalls persist; defer further warmup experiments until device profiling is available.
- Source visibility now uses a stable opacity modifier instead of conditional `hidden()` branches. Dismissal captures a once-only restoration object independently of the coordinator; dismantling schedules cleanup, and stale completions cannot clear the current presentation.
- Runtime verification remains necessary: cancel outside preview, choose each action, repeat long presses, navigate/remove a row during dismissal; check source returns after the full dismissal and does not appear twice during it.

## 2026-09-05 native source transition and feed optimization

- Supersedes all previous manual source-restoration experiments above: removed the UIKit iOS implementation and its hidden/opacity state. SwiftUI owns lifting and returning the actual card, including preview shape. There is no separate enlarged cover/marquee layout now; this intentionally favors continuity with the original content.
- Removed redundant preview-image state from rows/cards, eliminating an extra update per image load. Full ordered gallery values invalidate the waterfall cache, including metadata. Each column is lazy; footer visibility gates pagination because the outer container is no longer lazy.
- Detail compact actions use 44 pt touch frames on iOS and retain 27 pt on macOS; VoiceOver labels use existing translations. Hover titles scale with caption size and respect Reduce Motion. Animated images in feeds/vertical reader track scroll visibility and scene phase and stop on dismantling.
- Two macOS Swift Testing regressions passed: `waterfallCacheDetectsInteriorSortAndMetadataChanges()` and `waterfallAppendPreservesColumnMembershipAndOrder()`.
- Search migration evaluated: existing SwiftUI TextField owns keyboard candidate navigation, history/quick-search overlay and the right-side image-search affordance. Keep it for now; a later `.searchable` migration must preserve these behaviors and the persistent Search tab routing. Reader zoom/system analysis platform bridges remain appropriate.
- Still no device animation/performance measurement. First-use system context-menu/share stalls remain deferred; verify return animation and lazy-column scroll anchoring on device.

## 2026-09-05 waterfall preview and sort follow-up

- User confirmed native menu animation continuity is good; first-use stalls persist and remain deferred. Restored waterfall-only live previews via SwiftUI `contextMenu` preview closure. The cover reads the decoded thumbnail cache on demand; the title uses a visibility-scoped 30 Hz TimelineView, pauses at both ends, and honors Reduce Motion. No source hiding/restoration callbacks.
- Full input cache invalidation alone did not fix favorites-sort overlap on device. Layout now publishes columns and a generation atomically; reordering/replacement/revision/column-width changes recreate the lazy column subtree, while unchanged and append-only input retain measurements. The scroll view itself retains identity. Cover layout now comes from a metadata-ratio base with the image overlaid/clipped, preventing intrinsic image sizing from changing cached item heights.
- Background layout cancellation propagates into the detached task; the loop checks cancellation periodically. macOS menus rebuild only when visible menu state or language changes, while action callbacks always use current configuration.
- Added regressions for measurement invalidation vs pagination and marquee pause/return timing; still requires device checks for favorites sort at a nonzero scroll offset, rapid sort changes, title overflow and native preview return animation.

## 2026-09-05 original cover ratio and glass refinements

- Non-server favorite sorting loads FavoriteMetadataRecord, which previously discarded thumbnail dimensions. Schema migration v5 adds nullable thumbWidth/thumbHeight and the record bridge preserves them. Legacy records still decode; cards recover dimensions from the decoded image/cache. Waterfall static/animated images and context previews now use fit rendering so the complete cover remains visible. The bounded aspect-ratio box and sort-generation reset are retained.
- Search controls share a GlassEffectContainer and stable glass IDs. The trailing close/display action retains identity; symbols replace natively, field height expands slightly with a spring, and the jump action morphs away. The interactive glass is a background sibling of the text-input controls; padding taps focus/route search, without attaching custom drag recognizers to the TextField. History panel uses a coordinated spring and Reduce Motion disables custom motion.
- Compact detail header keeps regular Liquid Glass and cover glow, but applies one 24 pt rounded glass shape directly to content, with 8 pt side margins/6 pt top margin. Removed zero-radius glass extended through the top safe area; system soft scroll-edge effect handles the top edge.
- In-memory database regressions pass for dimensions preserved under every FavoriteMetadataSort and legacy records without dimensions. No forced favorite re-sync is required for old cards to display complete images.
- Device QA: focus search by tapping field and capsule padding, drag cursor/select text, dismiss/reopen rapidly; scroll compact header into view in portrait/landscape/split windows; verify tall/wide covers under each favorite sort before and after thumbnail load. Visual results remain unmeasured on device.

## 2026-09-06 search panel and preview investigation

- Search keeps its existing persistent-tab, image-search and keyboard-candidate routing. Added magnifier/submit label; history panel now uses a system material List with content/available-height sizing and keyboard scroll-to-selection. Partial query matching searches beyond the five recent entries, with localized case/diacritic handling.
- Found synchronous saved-search DB I/O on MainActor. QuickSearchStore actor serializes reads/writes and deduplicates inserts. GalleryListView owns the model across focus cycles; generations reject stale loads and mutation controls disable during writes. Failures are not auto-retried.
- Three targeted tests passed for partial matching, concurrent save deduplication and async model CRUD.
- Preview root cause remains unknown. NativeGalleryContextMenu has Debug launch controls and signposts documented in PREVIEW_PROFILING.md. No on-device trace was taken; do not claim first-use stutter fixed or attribute it to a specific framework yet. The normal native animation and scrolling title remain enabled by default.

## 2026-09-06 search clarity and active-input press feedback

- Login WebPage.NavigationEvent switch now has @unknown default for Swift 6 forward compatibility; unknown events leave loading state unchanged.
- Supersedes the shared search GlassEffectContainer/IDs: the field now overlays foreground after an independent glass capsule. Only the background scales, keeping text outside refractive/scale composition.
- SearchElasticSurface owns press state so touches do not invalidate GalleryListView or QuickSearchView. iOS passive window touch observation is bounded to each surface; it never recognizes/prevents/cancels input and releases on movement > 10 pt, touch end/cancellation, background or dismantling. History uses the same feedback with regular material. Reduce Motion disables deformation.
- Runtime QA still needed: press while typing, cursor placement/selection, history taps and scrolling, repeated expand/dismiss, background during touch, Reduce Motion. Compilation alone does not establish visual clarity or gesture behavior on device.
- First cold preview stall remains unconfirmed; existing PREVIEW_PROFILING.md A/B controls and native preview/marquee behavior are retained.
- Validation: iOS device-target and macOS Debug builds succeeded after this change; git diff --check passed. No device visual/gesture QA performed this turn. Logs: /tmp/ehviewer-search-press-ios.log and /tmp/ehviewer-search-press-macos.log.

## 2026-09-06 previous-page navigation and glass follow-up

- Native menu actions are explicitly @MainActor @Sendable, passed into Configuration through contextual closures; merely adding annotations still emitted conversion diagnostics in this toolchain.
- Search history now uses direct .glassEffect(.regular, in: .rect(cornerRadius: 20)), superseding the regularMaterial background. Foreground text remains outside the glass/scale hierarchy.
- Both List variants and GalleryWaterfallView expose a previous-page button when a server prev cursor exists. iOS pull-to-refresh retains the same action; macOS has an explicit entry without relying on refreshable pull support.
- GalleryScrollRetention records visible row geometry without observable per-scroll updates, captures the current item/relative viewport alignment immediately before prepend, and restores using ScrollViewReader after the rendered layout matches the current filtered input (including blocked tags). Waterfall waits for prepared columns rather than Task.yield in the network task. Geometry anchors are transient and separate from persisted search positions.
- Previous-page cancellation releases isLoading via defer. Waterfall layout key is explicitly nonisolated so its value equality is safe in background work and Swift Testing.
- Runtime QA needed: jump forward then load previous repeatedly on both platforms and both layouts, partial-row position, slow request while scrolling, >128-item async waterfall, first-page boundary and cancellation. No device scroll/visual verification this turn.
- Validation: final iOS and macOS Debug builds succeeded without menu conversion diagnostics; two targeted scroll-anchor tests passed, including stale-view cleanup. git diff --check passed. Logs: /tmp/ehviewer-pagination-ios.log, /tmp/ehviewer-pagination-macos.log, /tmp/ehviewer-pagination-tests.log.

## 2026-09-06 macOS search sizing and swipe details

- macOS TopListView uses menu pickers instead of seven-category/four-period segmented controls, so entering the Search landing page no longer advertises their combined label widths as the window minimum. iOS segmented controls are unchanged; ranking row titles accept narrow column proposals.
- Both feed List implementations keep GalleryWatchLaterSwipeButton in the same trailing action slot for add/remove. The component reads current service state, disables repeated taps while writing and retains the descriptive VoiceOver label. The old opposite-edge removal action is removed.
- User authorized committing and pushing the accumulated changes to GitHub on the existing codex/reader-cache-stability branch. No force push or main-branch merge is intended.
- Validation before submission: iOS and macOS Debug builds passed (logs: /tmp/ehviewer-search-width-ios.log and /tmp/ehviewer-search-width-macos.log); git diff --check passed. Window sizing and swipe behavior still need runtime verification.
