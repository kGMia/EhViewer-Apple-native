# AI Agent Handoff

## Identity / Constraints

- Repo: `https://github.com/kGMia/EhViewer-Apple-native`; upstream: `https://github.com/felixchaos/EhViewer-Apple`; author `kGMia`, upstream author `felixchaos`; Apache-2.0.
- Branch at handoff: `codex/reader-cache-stability`. Preserve user-owned changes; never reset/checkout/rewrite unrelated changes. NativeGalleryContextMenu.swift is tracked.
- SwiftUI-first, Xcode/OS target 27.0+, iOS+iPadOS+macOS; Swift 5 language mode with the Swift 6 compiler. User normally performs runtime/UI testing; run targeted compile checks, not exhaustive testing unless needed.
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
- First preview/share stall remains intermittent, cause unproven: iOS recent trials did not reproduce; iPadOS user observed it only after the first build. macOS preview slider system-transparency mismatch is explicitly deferred at user request.
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

## 2026-09-09 ordered refinement pass

- Previous-page responses now carry the replacement generation: switching/restoring/cancelling search invalidates old results, pending scroll restoration and old-request loading-state cleanup. Cancellation is rechecked after asynchronous enrichment.
- Geometry anchor ties select by vertical position, then horizontal position, then gid. Three anchor regressions passed including partial rows, viewport-sized rows, deterministic columns and stale owner cleanup.
- Search panel resolves its keyboard selection once per body instead of rebuilding candidate arrays for each row highlight. Previous-page button has 44 pt minimum height and loading feedback.
- Added background ThumbnailDecode signpost with static, metadata-free names. Failure-cache pruning now enforces 500 entries even when all failures are inside the 120-second cooldown.
- xctrace device enumeration found paired iOS/iPadOS devices offline. Device first/second-preview traces, scroll frame-rate/memory measurements and runtime visual acceptance remain pending; do not claim these steps verified or the cold stall fixed.
- GitHub push remains paused. These changes are uncommitted after local commit 5311688.

## 2026-09-09 system-style search refinement

- Focused search uses an explicit localized Cancel text button; home/popular switching is temporarily hidden. Cancel width is measured so the history surface aligns with the actual field, including longer localizations.
- Removed the history panel's extra horizontal inset, adjusted headers/icon hierarchy and delete target size, and softened focus-transition bounce. Compact List section spacing is iOS-only.
- Preserved image search, advanced search, keyboard candidate routing, Liquid Glass and separate unscaled text. This is a refinement of the existing search component, not a migration to searchable.
- Current running macOS app was inspected as a reference only; its build identity was not verified. Do not treat that observation as validation of the new binary.
- Validation: iOS and macOS Debug builds succeeded; git diff --check passed. New-build visual acceptance and device touch/keyboard testing remain pending. No commit or push this turn.

## 2026-09-09 glass consistency, close icon and list preview

- User requested the close icon back: focused search now uses the original circle xmark. Measured trailing width and aligned panel remain.
- SearchSurfaceStyle shares 22 pt corners, 12 pt inset, 6 pt gap and spring timing. At 44 pt height the field still reads as a capsule. History clips its foreground before adding glass so the system shadow is not cut off. No manual shadow/blur layer.
- iOS GalleryActionMenu has a cached-image-only horizontal GalleryListPreview (larger cover, headline, uploader/category/page metadata). The system still owns source visibility and dismissal. Debug system-snapshot control now also bypasses the list custom preview.
- Reduced iOS startup feedback warmup from seven engines to light/selection and removed the unattached dummy menu. This reduces known startup work but is not evidence that it caused the cold stall. Keep profiling controls.
- Runtime verification needed for preview size/continuity, narrow screens, Dynamic Type and first/second press timing. No new device trace this turn.
- Validation: iOS/macOS Debug builds and git diff --check passed. Build logs: /tmp/ehviewer-glass-preview-ios.log and /tmp/ehviewer-glass-preview-macos.log. Changes remain uncommitted; push remains paused.

## 2026-09-09 finishing and submission

- List preview uses a minimum height rather than a fixed height to accommodate larger text; decorative cover is hidden from accessibility and metadata is grouped. Added matching list-preview disappearance event.
- User renewed the request to finish, commit and push these changes to GitHub. Target remains origin (kGMia/EhViewer-Apple-native), branch codex/reader-cache-stability; the previous local commit 5311688 may be uploaded with this follow-up.
- First-use stutter remains unverified. Do not conflate reduced startup work or passing builds with device performance validation.


## 2026-09-16 OS 27 compatibility

- User had already upgraded project format/deployment to 27.0 and moved Info.plist metadata into build settings. Preserved these edits; aligned iOS/macOS tests and Live Activity extension deployment targets.
- Xcode 27 clean build identified deprecated BGTaskScheduler.submit and ActivityKit actor-conformance warnings. Migrated submission to the async API off MainActor and marked attributes/state nonisolated in app and extension.
- Adopted systemPrefersReducedResourceUsage for animated images and marquee titles. Settings export now uses scene-owned SwiftUI fileExporter instead of arbitrary-window presentation / modal NSSavePanel.
- Actual host: macOS 27.0, Xcode 27.0 27A266a. OS27_ADAPTATION.md records evidence, official references and remaining device QA. Project still uses Swift 5 language mode; do not claim full Swift 6 migration.
- No commit/push requested for this turn; user project/Info.plist edits remain in the working tree.

## 2026-09-16 warning cleanup and window toolbar

- Cleared the seven user-reported diagnostics in EhDatabase, ArchiveParser and EhAPI; the parser now guards missing body instead of force-unwrapping it.
- MainTabView uses macOS toolbarVisibility for the windowToolbar. Main browser defaults hidden; View-menu Toggle (showsMainWindowToolbar AppStorage) restores automatic visibility. Compact navigation keeps toolbar automatic when its path is nonempty. No private AppKit view traversal or layer masking.
- iOS and macOS Debug builds passed with no reported warnings in /tmp/ehviewer-toolbar-ios.log and /tmp/ehviewer-toolbar-macos.log; git diff --check passed. Actual titlebar appearance and navigation remain runtime QA items.
- OS 27 SDK confirms swipeActionsContainer and reorderContainer/reorderable APIs as candidates for waterfall swipe actions and local queue/saved-search ordering; not implemented this turn.

## 2026-09-16 native swipe and reorder

- OS 27 swipeActionsContainer enables watch-later/favorite actions on the two GalleryListView waterfall entry points. Full swipe is disabled; existing native menus remain.
- QuickSearch and Downloads use ForEach.reorderable + reorderContainer. Saved-search reorder is available with empty query; download reorder only with no label/status/search filter or multi-selection.
- Migration v6 adds nullable sortIndex to quickSearch/download. GRDB writes the complete order atomically; dates and states are unchanged. Unknown sources/destinations or destinations inside moved items are rejected without changing data. Multi-item moves preserve existing relative order.
- DownloadManager persists before sorting its queue and leaves activeTask unchanged; future waiting tasks follow new order. New unranked records follow manually ranked entries; legacy databases without manual order keep date-descending ordering.
- Three targeted tests passed: saved order/date/stale drop, download order after state changes, and legacy JSON decoding without sortIndex. macOS and iOS builds passed. Logs: /tmp/ehviewer-native-actions-tests.log, /tmp/ehviewer-native-actions-ios.log.
- Still requires runtime drag/swipe QA on iPhone/iPad/macOS; compilation is not a gesture validation. No commit or push this turn.

## 2026-09-17 macOS feed activation

- Replaced macOS embedded feed Button rows inside selection List with tagged GalleryRow rows, letting native selection drive detail and arrow-key navigation. Embedded lists use stable gid selection instead of hashing mutable GalleryInfo metadata; spacer/loading selection does not clear detail.
- Restricted the newly added waterfall swipeActionsContainer and both card swipeActions modifiers to iOS/iPadOS. macOS keeps ordinary button activation and existing right-click menus; this removes a candidate mouse gesture conflict, not a proven SDK root cause.
- Narrowing a macOS window now preserves both the current content route and selected gallery in compactPath, instead of dropping the detail whenever a tag/uploader route exists.
- The already-running app could open waterfall detail via accessibility activation. Physical mouse failure was not conclusively reproduced, and the rebuilt app still needs runtime verification: wide list/card clicks, keyboard selection, and wide → narrow → back.
- Final macOS 27 and iOS/iPadOS 27 Debug builds passed without warning/error diagnostics (/tmp/ehviewer-navigation-macos.log and /tmp/ehviewer-navigation-ios.log). No commit/push.

## 2026-09-17 window controls and restoration

- Supersedes toolbar hiding above: windowToolbar hidden visibility also hides traffic lights (documented SwiftUI behavior). Both wide and compact roots now use toolbarBackgroundVisibility only. The View menu's localized label now says “显示窗口工具栏背景”; existing preference key is retained.
- Main WindowGroup uses restorationBehavior(.automatic). Removed MainWindowFrameAutosaveModifier/View: asynchronous view.window lookup could miss attachment, a shared frameAutosaveName conflated multiple windows, and explicit scene restoration disabling competed with native restoration. defaultSize remains the fallback for a fresh window; system restoration owns saved frame/scene identity. Relaunch may restore multiple main windows as standard macOS behavior.
- macOS Debug build passed without warning/error diagnostics: /tmp/ehviewer-window-state-macos.log. All three Localizable.strings pass plutil; git diff --check passes. Physical resize → quit → relaunch, full screen, and multi-display restoration remain runtime QA; no claim of end-to-end verification. No commit/push.

## 2026-09-17 column layout, paging glass, performance follow-up

- MainTabView stores sidebar/feed widths in separate SceneStorage values per window. Actual rounded widths are measured only in split layout, validated against column bounds, and supplied as ideal widths. Divider dragging remains enabled; the detail receives remaining space. Interpret “分栏宽度也固定” as remembering adjusted widths, not disabling resizing. Native restoration still needs quit/relaunch QA.
- GalleryPreviewsView uses GlassEffectContainer, glassEffectID for page/slider morphing, and separate system glass arrow/close buttons. Removed the single interactive glass wrapper around all controls. iOS button labels are 44 pt; Reduce Motion disables the expansion animation. Favorites processing HUD uses the same rounded regular glass as preview loading.
- GalleryWaterfallView reuses preparedLayout when the full key matches and reuses its synchronous columns when publishing small-list snapshots. Background column computation now has a WaterfallLayout signpost. Existing metadata/sort/append keys remain unchanged.
- Five focused tests passed (three waterfall sorting/append/cache tests and two preview arrow/adjacent-page tests); macOS build/test and iOS/iPadOS build pass. Logs: /tmp/ehviewer-glass-layout-tests.log and /tmp/ehviewer-glass-layout-ios.log. git diff --check passes.
- xctrace now detects an online OS 27 mobile device; two other paired devices are offline. No cold first-long-press recording was obtained: the relevant gesture must be exercised during capture. Do not say the startup stall is fixed or that all planned features are implemented.
- Plan remains ordered: finish interaction profiling; native-search prototype with feature parity (history, suggestions, advanced filter, close button); page bookmarks/notes; smart local collections. This turn advanced the performance stage; later stages remain pending. No commit/push requested.

## 2026-09-17 Liquid Glass system preference clarification

- User clarified the bug is failure to follow OS 27's Liquid Glass transparency slider, not absence of glass or an animation request. Prior paging redesign alone must not be represented as fixing this.
- Inspected installed SDK Glass API and official Apple Liquid Glass guidance: use native materials to inherit preferences; no public slider-value API was found. Do not read private defaults, force Glass.clear, or simulate opacity.
- Removed ImageReaderView.readerPanelTint (fixed white 0.42 / black 0.30) from top page capsule and bottom panel. Glass controls now use semantic primary foreground instead of forcing white/black from reader canvas luminance; canvas/HUD colors are unchanged. GalleryPreviewsView page button now uses native glass button style, like arrows/close; slider container remains untinted regular glass.
- User was asked whether they meant thumbnail preview or full-screen reader, and which platform; reply was “继续”, so both surfaces were covered. The thumbnail page already used untinted regular glass; its reported preference mismatch has NOT been conclusively diagnosed or reproduced.
- Both final builds passed without warning/error diagnostics: /tmp/ehviewer-glass-preference-macos.log and /tmp/ehviewer-glass-preference-ios.log. Diff whitespace check passes. Runtime verification of the system slider at both extremes, while page stays open and after foregrounding, is still required. No commit/push.

## 2026-09-17 persistent column correction and glass verification attempt

- User reports both glass preference mismatch and lost split widths persist. Supersedes SceneStorage width implementation: main.preferredSidebarWidth / main.preferredFeedWidth use AppStorage; geometry only writes during current leftMouseDragged events with event.window.inLiveResize false. This avoids storing provisional launch geometry or compressed window sizes. Feed defaults to 520, minimum 460, maximum 900; actual frame(minWidth:460) complements navigationSplitViewColumnWidth because ideal/min column preferences alone proved insufficient. Sidebar minimum 160. Preferences are shared across main windows, not per-window, intentionally; physical divider drag/relaunch still needs verification.
- GalleryPreviewsView now uses safeAreaBar(bottom) for page controls, replacing overlay + fixed 68 pt content padding with system layout and 16 pt content padding. This is a layering/layout improvement, NOT a confirmed system opacity fix.
- User explicitly authorized temporary macOS Liquid Glass slider changes with restoration. CUA found initial slider value 0, changed to 1, and RESTORED TO 0; full final AX tree confirmed 0. Do not leave settings altered. No other appearance preferences were changed.
- Used a non-explicit military model art gallery to open preview and expand pager. CUA screenshots only return a tiny tilted window thumbnail despite AX Raise; cannot reliably judge opacity differences. Existing user-run binary was rebuilt during inspection; not all observations are tied to /tmp build. Do not claim end-to-end visual verification or known root cause. No private preferences/API used.
- macOS build passed (/tmp/ehviewer-columns-bar-macos.log). Earlier iOS build passed (/tmp/ehviewer-columns-bar-ios.log); final iOS constraint-only check uses /tmp/ehviewer-columns-bar-ios-final.log. No commit/push.

## 2026-09-22 thumbnail bounds and pending device profiling

- User confirmed split-column width issue solved; leave that behavior unchanged. System glass preference mismatch and first mobile preview/share stall remain open.
- Added PreviewThumbnailLayout.height with 240 pt cap and invalid ratio fallback. Full preview and detail preview both cap standalone and sprite thumbnails, using fit rendering for complete images; animated previews also use fit. URL changes reset standalone provisional ratio.
- Height bounds/invalid ratios and adjacent-page regression tests pass; iOS/iPadOS build passes. Logs: /tmp/ehviewer-preview-height-tests.log and /tmp/ehviewer-preview-height-ios.log.
- User agreed to connect Lavender iPhone 17 (OS 27), now visible to xctrace. Installed bundle is kgmia.ehviewer-apple, version 1.0.0 (1). First Time Profiler + Points of Interest launch was rejected by iOS citing invalid signature, inadequate entitlements, or missing user trust. /tmp/ehviewer-cold-preview-20260922.trace is a FAILED recording, not evidence of app stalls. Asked user to manually open app before trying attach. Do not weaken device security or silently install/trust profiles.

## 2026-09-22 device profiling follow-up

- Two successful device-wide Time Profiler captures on Lavender: /tmp/ehviewer-device-interaction-20260922.trace (already-running/idle baseline), /tmp/ehviewer-cold-immediate-20260922.trace (recording started before user was instructed to force-quit/reopen and immediately long-press, repeat and share). User reported no noticeable stall in BOTH trials. Do not claim fixed or infer idle time is the cause. Direct PID attach failed; name attach selected Live Activity extension and is not a valid main-app recording.
- First baseline includes two potential main-thread hangs of approximately 392 ms and 346 ms. Second flags a 27.14 s interval starting at 63.899 s and extending to recording end; PID 7722 main CPU samples stop at 63.931 s. This does not establish a 27-second visible freeze or its cause: suspension/process lifecycle and waiting threads are not resolved by active-thread CPU samples. User perceived no freeze. Partial system symbolication and lack of gesture-aligned markers prevent attributing these records to first preview/share.
- PerformanceDiagnostics and BackgroundPerformanceDiagnostics now use PointsOfInterest category, matching the recording instrument's observed filter. This only improves future capture visibility after deploying the new build; it does not retroactively add markers or fix stalls. No speculative additional warmup added.
- Final incremental iOS and macOS builds pass: /tmp/ehviewer-diagnostics-ios.log and /tmp/ehviewer-diagnostics-macos.log. Earlier two thumbnail/paging tests pass; git diff --check passes. Device sampling is complete; no further connected-device action required now. Glass transparency mismatch remains unresolved. No commit/push.

## 2026-09-22 user platform clarification

- User confirms preview-control Liquid Glass transparency mismatch occurs ONLY on macOS. Focus further diagnosis on macOS material hosting and system preference updates; do not treat iOS/iPadOS transparency as a known failure.
- User's additional iOS testing did not reproduce the preview/share stall. On iPadOS it occurred on launch after the first build, then did not recur. This is a user observation, not an instrumented reproduction; fresh-install status, debugger attachment and exact trigger remain unverified. Distinguish first launch after build from ordinary process cold launch. Neither a cache/SDK cause nor a permanent fix has been established.
- Prioritize the reproducible macOS transparency issue. Keep the mobile stall open as intermittent, with any future capture targeting the iPadOS first-launch-after-build condition; avoid speculative warmup changes.

## 2026-09-22 macOS preview slider material

- User further clarified: the affected control is the expanded slider in GalleryPreviewsView, NOT ImageReaderView. Do not conflate these surfaces. No reader changes in this turn.
- Replaced only the macOS expanded slider's SwiftUI glassEffect background with an NSGlassEffectView representable, regular style and no tint. AppKit owns material/preference handling; capsule radius follows actual bounds. The native view returns nil from hitTest, and the SwiftUI background also disables hit testing/accessibility so the existing slider remains the input surface. macOS 27 effectIsInteractive follows Reduce Motion. No private defaults, alpha simulation or forced clear style.
- iOS/iPadOS retain their original SwiftUI glass and matched glass transition. Native AppKit background is not enrolled in SwiftUI glassEffectID morphing; macOS retains the surrounding smooth layout animation. Added native help text to preview page and arrow/close buttons.
- macOS build and two targeted tests pass (/tmp/ehviewer-native-slider-tests.log): overlapping AppKit glass cannot intercept slider input; adjacent arrows preserve loaded pages. This does NOT verify visual opacity response. CUA still yields a tiny tilted Stage Manager thumbnail, preventing reliable visual comparison; transparency fix remains pending user/runtime verification.
- Official SDK check: NSGlassEffectView.h declares effectIsInteractive on macOS 27, regular/clear styles and tintColor. Apple's WWDC26 Modernize your AppKit app describes native interactive glass for control containers: https://developer.apple.com/videos/play/wwdc2026/289/ . No new mobile warmup or stall-fix claim; no commit/push.
- Final iOS/iPadOS build passed (/tmp/ehviewer-native-slider-ios.log), with no warning/error diagnostics in this build or the macOS test build; git diff --check passed.

## 2026-09-22 unified SwiftUI pager (supersedes AppKit slider above)

- User reports transparency only after expansion, collapsed controls too tall, and prefers SwiftUI. Removed PreviewSliderGlass/PreviewSliderGlassView and its bridge-specific hit-test test. Entire pager is SwiftUI again.
- All three surfaces (slider capsule, page capsule, circular arrows/close) now explicitly use regular.interactive(!reduceMotion) glass. Buttons use plain style so their already-sized labels do not acquire a second set of glass button insets. macOS height is 32 pt, iOS/iPadOS stays 44 pt. Both page states share glassEffectID again, including macOS. No forced clear material or simulated opacity.
- This addresses inconsistent rendering paths and excess height. It does not prove the original macOS system-opacity preference issue resolved; visual response at both slider extremes still needs confirmation. Pagination logic unchanged. macOS build passes (/tmp/ehviewer-swiftui-pager-mac.log); iOS build log: /tmp/ehviewer-swiftui-pager-ios.log. No commit/push.

## 2026-09-22 upstream review and authorized publication

- Fetched both remotes. Upstream main is 76c62c5fab3ba4784b11f8b5f1905bf50ac16871; two new commits since shared base 4635577. Reviewed both; no applicable code to port. 92203c9 lowers deployment to iOS 18, incompatible with this fork’s native OS 27 APIs; 76c62c5 fixes AltStore MinimumOSVersion extraction, but this fork has no AltStore generator/source.json. Do not reintroduce upstream release URLs or downgrade deployment targets. No wholesale merge performed.
- User explicitly deferred macOS transparency work and authorized commit/push of accumulated changes to the current origin branch. No main merge or force push requested.
- Pre-publication validation: five focused macOS tests passed (manual order persistence/stale drops/legacy decoding and preview bounds/adjacent pages), log /tmp/ehviewer-precommit-tests.log. Both latest platform builds passed; metadata-only preflight, zsh syntax and diff whitespace checks passed. Preflight now accepts encryption declarations from every main-app build configuration; CI selects an installed Xcode 27 and reports clearly if unavailable. Hosted runner availability and full Release analysis were not verified in this turn.
