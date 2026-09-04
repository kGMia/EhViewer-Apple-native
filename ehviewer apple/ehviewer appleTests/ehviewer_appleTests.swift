//
//  ehviewer_appleTests.swift
//  ehviewer appleTests
//
//  Created by 晓卡 on 2026/2/12.
//

import Testing
import AppKit
import ImageIO
import EhModels
import EhAPI
import EhParser
import EhDatabase
import EhDownload
import EhSettings
@testable import EhSpider
@testable import EhCookie
@testable import ehviewer_apple

private actor PreviewPaginationProbe {
    private(set) var requestedPages: [Int] = []
    private let delayedPage: Int?
    private var delayedStarted = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(delayedPage: Int? = nil) { self.delayedPage = delayedPage }

    func waitForDelayedRequest() async {
        if delayedStarted { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func load(_ url: String) async throws -> (PreviewSet, Int) {
        let components = URLComponents(string: url)
        let page = Int(components?.queryItems?.first(where: { $0.name == "p" })?.value ?? "0") ?? 0
        requestedPages.append(page)
        if page == delayedPage {
            delayedStarted = true
            waiter?.resume()
            waiter = nil
            // Simulate a transport that still delivers a cancelled response.
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (Self.previews(page: page), 5)
    }

    nonisolated static func previews(page: Int) -> PreviewSet {
        .large((page * 4..<page * 4 + 4).map {
            LargePreview(position: $0, imageUrl: "https://unit.invalid/\($0).jpg", pageUrl: "")
        })
    }
}

private actor GalleryUpdateResponseGate {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<Void, Never>?

    func holdResponse() async {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { responseWaiter = $0 }
    }

    func waitForRequest() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseResponse() {
        responseWaiter?.resume()
        responseWaiter = nil
    }
}

@Suite(.serialized)
struct ehviewer_appleTests {
    @Test func imageQuotaAcceptsIPModeWithoutInventingNumericLimits() throws {
        let body = """
        <h2>Image Limits</h2><p>You are currently using IP-based limits. No restrictions are currently in effect.</p>
        <p>Alternatively, you can unlock a high-resolution quota for 24 hours by spending 20,000 GP.</p>
        """
        let result = try HomeParser.parseQuota(body)
        #expect(result.limitMode == .ipBasedUnrestricted)
        #expect(result.resetCost == nil)
        let uncertain = try HomeParser.parseQuota("<p>You are currently using IP-based limits.</p>")
        #expect(uncertain.limitMode == .ipBased)
        do {
            _ = try HomeParser.parseQuota("<p>This page requires you to log on.</p>")
            Issue.record("Expected sign-in failure")
        } catch EhParseError.parseFailure(let reason) {
            #expect(reason == "Image quota requires sign-in")
        }
    }

    @Test @MainActor func imageQuotaIPModeIsNotReportedAsFailure() async {
        let vm = ImageQuotaViewModel(loader: { HomeDetail(limitMode: .ipBasedUnrestricted) }, context: { "test" })
        await vm.refresh().value
        #expect(vm.detail?.limitMode == .ipBasedUnrestricted)
        #expect(vm.updatedAt != nil && vm.errorMessage == nil)
    }

    @Test func imageSearchRedirectStaysOnChosenSite() throws {
        let base = try #require(URL(string: "https://upld.e-hentai.org/image_lookup.php"))
        let valid = "https://e-hentai.org/?f_shash=abcdef&fs_similar=1"
        #expect(EhAPI.imageSearchResultURL(valid, relativeTo: base, site: .eHentai)?.absoluteString == valid)
        #expect(EhAPI.imageSearchResultURL(valid, relativeTo: base, site: .exHentai) == nil)
        for bad in ["https://untrusted.invalid/?f_shash=abc", "http://e-hentai.org/?f_shash=abc", "https://e-hentai.org/?f_shash=", "https://e-hentai.org/bounce_login.php"] {
            #expect(EhAPI.imageSearchResultURL(bad, relativeTo: base, site: .eHentai) == nil)
        }
    }

    @Test @MainActor func imageSearchPreparationPreservesExactBytes() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 100,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = try SearchImage.prepare(png)
        #expect(image.original == png && image.originalType == "image/png")
        #expect(image.thumbnail.width <= 1600 && image.thumbnail.height <= 1600)
        #expect(CGImageSourceCreateWithData(image.similarityData as CFData, nil) != nil)
        #expect(image.similarityData.starts(with: [0xff, 0xd8]))
        #expect(throws: (any Error).self) { try SearchImage.prepare(Data("not an image".utf8)) }
    }

    @Test @MainActor
    func previewArrowTargetsAccumulateAndRejectOldCompletion() {
        var navigation = PreviewPageNavigation()
        navigation.observe(page: 5)
        let first = navigation.begin(page: navigation.currentPage + 1, pageCount: 30)
        let second = navigation.begin(page: navigation.currentPage + 1, pageCount: 30)
        #expect(navigation.currentPage == 7)
        navigation.observe(page: 5)
        navigation.complete(first)
        #expect(navigation.currentPage == 7 && navigation.pending == second)
        navigation.complete(second)
        // A short last page may leave previous-page thumbnails visible. Their
        // layout callbacks must not undo an explicit selection.
        navigation.observe(page: 6)
        #expect(navigation.currentPage == 7)
        navigation.cancel() // user scrolling takes over
        navigation.observe(page: 6)
        #expect(navigation.currentPage == 6)
        let last = navigation.begin(page: 300, pageCount: 30)
        #expect(last.page == 29)
        let reverse = navigation.begin(page: navigation.currentPage - 1, pageCount: 30)
        navigation.complete(last)
        #expect(navigation.currentPage == 28 && navigation.pending == reverse)
        navigation.cancel()
        #expect(navigation.currentPage == 6)
    }

    @Test @MainActor
    func previewAdjacentArrowPreservesLoadedPages() async {
        let probe = PreviewPaginationProbe()
        let vm = GalleryPreviewsViewModel(loader: { try await probe.load($0) })
        vm.initialize(gid: 1, token: "test", totalPages: 5, initialPreviewSet: PreviewPaginationProbe.previews(page: 0))
        #expect(await vm.jump(to: 1) == 4)
        #expect(vm.allPreviews.map(\.position) == Array(0..<8))
        #expect(await vm.jump(to: 2) == 8)
        #expect(await vm.jump(to: 1) == 4)
        #expect(vm.allPreviews.map(\.position) == Array(0..<12))
        #expect(await probe.requestedPages == [1, 2])
    }

    @Test func imageQuotaParserHandlesFormattingAndMissingCost() throws {
        let modern = #"""
        <p>You are currently at <strong>1,234</strong> towards your account limit of
        <strong>10,000</strong>.</p> <p>You can reset your image quota by spending <strong>250</strong> GP.</p>
        """#
        let quota = try HomeParser.parseQuota(modern)
        #expect(quota.currentUsed == 1234 && quota.totalLimit == 10000 && quota.resetCost == 250)
        let legacy = #"<p>You are currently at <strong>0</strong> towards a limit of <strong>5,000</strong>.</p><p>Reset Cost: <strong>0</strong> GP</p>"#
        #expect(try HomeParser.parseQuota(legacy).resetCost == 0)
        let noCost = #"<p>You are currently at <strong>12,000</strong> towards your account limit of <strong>10,000</strong>.</p>"#
        #expect(try HomeParser.parseQuota(noCost).resetCost == nil)
        #expect(throws: (any Error).self) { try HomeParser.parseQuota("<html>Please log in</html>") }
        #expect(throws: (any Error).self) { try HomeParser.parseQuota("You are currently at 0 towards a limit of 0.") }
    }

    @Test @MainActor
    func imageQuotaRefreshFailureKeepsDatedSnapshot() async {
        var calls = 0
        let vm = ImageQuotaViewModel(loader: {
            calls += 1
            if calls > 1 { throw URLError(.notConnectedToInternet) }
            return HomeDetail(currentUsed: 120, totalLimit: 100)
        }, context: { "account" })
        await vm.refresh().value
        let date = vm.updatedAt
        #expect(vm.remaining == 0)
        #expect(vm.detail?.currentUsed == 120 && date != nil)
        await vm.refresh().value
        #expect(vm.updatedAt == date && vm.detail?.currentUsed == 120)
        #expect(vm.errorMessage != nil && !vm.isLoading)
    }

    @Test @MainActor
    func imageQuotaRejectsLateAccountResponse() async {
        let gate = GalleryUpdateResponseGate()
        var identity = "old"
        var calls = 0
        let vm = ImageQuotaViewModel(loader: {
            calls += 1
            if calls == 1 {
                await gate.holdResponse()
                return HomeDetail(currentUsed: 90, totalLimit: 100)
            }
            return HomeDetail(currentUsed: 10, totalLimit: 100)
        }, context: { identity })
        let old = vm.refresh()
        await gate.waitForRequest()
        identity = "new"
        vm.invalidateIfNeeded()
        await vm.refresh().value
        await gate.releaseResponse()
        await old.value
        #expect(vm.detail?.currentUsed == 10 && vm.remaining == 90)
        #expect(!vm.isLoading)
    }

    @Test @MainActor
    func galleryUpdateResumeSkipsCompletedBatches() async {
        let galleries = (1...51).map { GalleryInfo(gid: Int64($0), token: "test") }
        var loads = 0
        var requests: [[Int64]] = []
        var shouldFail = true
        var pauses: [Duration] = []
        let checker = GalleryUpdateChecker(dependencies: .init(
            context: { "test" },
            load: { _ in loads += 1; return .init(galleries: galleries) },
            check: { batch, _ in
                requests.append(batch.map(\.gid))
                if batch.first?.gid == 26 && shouldFail {
                    shouldFail = false
                    throw URLError(.networkConnectionLost)
                }
                return batch.map { GalleryVersionCheck(gallery: $0, latest: $0.gid == 1 ? GalleryInfo(gid: 101, token: "new") : nil) }
            },
            pause: { pauses.append($0) }
        ))
        await checker.start()?.value
        #expect(checker.phase == .failed)
        #expect(checker.checkedCount == 25)
        #expect(checker.remainingCount == 26)
        #expect(checker.updates.count == 1)
        #expect(checker.canResume)
        await checker.resume()?.value
        #expect(checker.phase == .finished)
        #expect(checker.checkedCount == 51)
        #expect(checker.remainingCount == 0)
        #expect(checker.updates.count == 1)
        #expect(loads == 1)
        #expect(requests.compactMap(\.first) == [1, 26, 26, 51])
        #expect(pauses == [.milliseconds(500), .milliseconds(500), .milliseconds(500)])
        // A new manual pass still observes the cooldown from earlier attempts.
        await checker.start()?.value
        #expect(pauses[3] == .seconds(5))
    }

    @Test @MainActor
    func galleryUpdateRetryOnlyReplacesFailedItems() async {
        let galleries = (1...3).map { GalleryInfo(gid: Int64($0), token: "test") }
        var loads = 0
        var requests: [[Int64]] = []
        let checker = GalleryUpdateChecker(dependencies: .init(
            context: { "test" },
            load: { _ in loads += 1; return .init(galleries: galleries) },
            check: { batch, _ in
                requests.append(batch.map(\.gid))
                if requests.count == 1 {
                    return [GalleryVersionCheck(gallery: batch[0], latest: GalleryInfo(gid: 101, token: "new")),
                            GalleryVersionCheck(gallery: batch[1], error: "Temporary failure")]
                }
                return batch.map { GalleryVersionCheck(gallery: $0, latest: $0.gid == 2 ? GalleryInfo(gid: 102, token: "new") : nil) }
            },
            pause: { _ in }
        ))
        await checker.start()?.value
        #expect(checker.checkedCount == 3)
        #expect(checker.unavailable.map(\.gallery.gid) == [2, 3])
        #expect(checker.canRetryUnavailable)
        await checker.retryUnavailable()?.value
        #expect(requests == [[1, 2, 3], [2, 3]])
        #expect(loads == 1)
        #expect(checker.checkedCount == 3)
        #expect(checker.updates.map(\.gallery.gid) == [1, 2])
        #expect(checker.unavailable.isEmpty)
        #expect(!checker.canRetryUnavailable)
    }

    @Test @MainActor
    func galleryUpdateCancelledResponseCanBeResumed() async {
        let gate = GalleryUpdateResponseGate()
        var requests = 0
        var loads = 0
        let checker = GalleryUpdateChecker(dependencies: .init(
            context: { "test" },
            load: { _ in loads += 1; return .init(galleries: [GalleryInfo(gid: 1, token: "test")]) },
            check: { batch, _ in
                requests += 1
                if requests == 1 { await gate.holdResponse() }
                return batch.map { GalleryVersionCheck(gallery: $0) }
            },
            pause: { _ in }
        ))
        let first = checker.start()
        await gate.waitForRequest()
        checker.cancel()
        await gate.releaseResponse()
        await first?.value
        #expect(checker.phase == .cancelled)
        #expect(checker.checkedCount == 0)
        #expect(checker.remainingCount == 1)
        await checker.resume()?.value
        #expect(checker.phase == .finished)
        #expect(checker.checkedCount == 1)
        #expect(loads == 1 && requests == 2)
    }

    @Test @MainActor
    func galleryUpdateOldAccountCannotOverwriteNewRun() async {
        let gate = GalleryUpdateResponseGate()
        var identity = "first"
        let checker = GalleryUpdateChecker(dependencies: .init(
            context: { identity },
            load: { _ in .init(galleries: [GalleryInfo(gid: identity == "first" ? 1 : 2, token: "test")]) },
            check: { batch, _ in
                if batch.first?.gid == 1 { await gate.holdResponse() }
                return batch.map { GalleryVersionCheck(gallery: $0, latest: GalleryInfo(gid: $0.gid + 100, token: "new")) }
            },
            pause: { _ in }
        ))
        let first = checker.start()
        await gate.waitForRequest()
        identity = "second"
        checker.invalidateIfNeeded()
        #expect(checker.phase == .idle && checker.updates.isEmpty)
        await checker.start()?.value
        await gate.releaseResponse()
        await first?.value
        #expect(checker.phase == .finished)
        #expect(checker.checkedCount == 1)
        #expect(checker.updates.map(\.gallery.gid) == [2])
        identity = "third"
        #expect(checker.resume() == nil)
        #expect(checker.phase == .idle && checker.updates.isEmpty)
    }

    @Test func galleryVersionChecksPreservePartialResults() throws {
        let galleries = (1...7).map { GalleryInfo(gid: Int64($0), token: "old-token") }
        let data = Data(#"""
        {"gmetadata":[
          {"gid":2,"current_gid":2,"current_key":"unchanged"},
          {"gid":1,"title":"Original title","current_gid":"101","current_key":"new-token"},
          {"gid":"3","current_gid":null,"current_key":null},
          {"gid":4,"error":"Gallery unavailable"},
          {"gid":5,"current_gid":105},
          {"gid":7,"current_gid":"invalid","current_key":"key"}
        ]}
        """#.utf8)
        let results = try GalleryApiParser.parseVersionChecks(data, galleries: galleries)
        #expect(results.map(\.gallery.gid) == galleries.map(\.gid))
        #expect(results[0].gallery.title == "Original title")
        #expect(results[0].latest?.gid == 101)
        #expect(results[0].latest?.token == "new-token")
        #expect(results[1].latest == nil && results[1].error == nil)
        #expect(results[2].latest == nil && results[2].error == nil)
        #expect(results[3].error == "Gallery unavailable")
        #expect(results[4].error == "Invalid gallery version metadata")
        #expect(results[4].latest == nil)
        #expect(results[5].error == "Missing gallery metadata")
        #expect(results[6].error == "Invalid gallery version metadata")
    }

    @Test func galleryUpdateCandidatesAreUniqueAndValid() {
        let source = [
            GalleryInfo(gid: 7, token: "download"),
            GalleryInfo(gid: 7, token: "favorite"),
            GalleryInfo(gid: 0, token: "invalid"),
            GalleryInfo(gid: 8, token: ""),
            GalleryInfo(gid: 9, token: "valid")
        ]
        let result = GalleryUpdateChecker.uniqueGalleries(source)
        #expect(result.map(\.gid) == [7, 9])
        #expect(result.first?.token == "download")
    }


    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test @MainActor
    func previewJumpLoadsTargetThenBothNeighbors() async throws {
        let probe = PreviewPaginationProbe()
        let vm = GalleryPreviewsViewModel(loader: { try await probe.load($0) })
        vm.initialize(gid: 1, token: "test", totalPages: 5, initialPreviewSet: PreviewPaginationProbe.previews(page: 0))
        #expect(await vm.jump(to: 3) == 12)
        #expect(await probe.requestedPages == [3])
        #expect(vm.previousPage == 2)
        #expect(vm.nextPage == 4)
        await vm.loadAdjacent(page: 2)
        await vm.loadAdjacent(page: 4)
        await vm.loadAdjacent(page: 1)
        #expect(vm.allPreviews.map(\.position) == Array(4..<20))
        #expect(vm.page(containing: 12) == 3)
        #expect(vm.previousPage == 0)
        #expect(vm.nextPage == nil)
        #expect(await vm.jump(to: 0) == 0)
        #expect(await probe.requestedPages == [3, 2, 4, 1])
    }

    @Test
    func previewPagerDoesNotMistakeNextForLast() throws {
        for pagerClass in ["ptt", "ptb"] {
            let html = """
            <table class="\(pagerClass)"><tr>
              <td><a href="?p=18">&lt;</a></td>
              <td><a href="?p=0">1</a></td><td>…</td><td>20</td>
              <td><a href="?p=29">30</a></td>
              <td><a href="?p=20">&gt;</a></td>
            </tr></table>
            """
            #expect(try GalleryDetailParser.parsePreviewPages(html) == 30)
        }
        let last = #"<table class="ptb"><tr><td><a href="?p=28">&lt;</a></td><td>30</td><td>&gt;</td></tr></table>"#
        #expect(try GalleryDetailParser.parsePreviewPages(last) == 30)
        #expect(try GalleryDetailParser.parsePreviewPages("<html></html>") == 0)
    }

    @Test
    func previewCombinedParserPreservesImagesAndCount() throws {
        let html = #"""
        <div class="gdtl"><a href="https://e-hentai.org/s/test/1-77"><img alt="77" src="https://unit.invalid/77.jpg"></a></div>
        <table class="ptt"><tr><td>20</td><td><a href="?p=29">30</a></td><td><a href="?p=20">&gt;</a></td></tr></table>
        """#
        let (previews, count) = try GalleryDetailParser.parsePreviewPage(html)
        #expect(count == 30)
        guard case .large(let items) = previews else {
            Issue.record("Expected large previews")
            return
        }
        #expect(items.map(\.position) == [76])
        #expect(items.first?.imageUrl == "https://unit.invalid/77.jpg")
    }

    @Test @MainActor
    func previewJumpPreservesKnownTotalAndCanReachBothEnds() async {
        let vm = GalleryPreviewsViewModel(loader: { url in
            let page = Int(URLComponents(string: url)?.queryItems?.first(where: { $0.name == "p" })?.value ?? "0") ?? 0
            // Simulate a partial pager reporting just the selected page.
            return (PreviewPaginationProbe.previews(page: page), page + 1)
        })
        vm.initialize(gid: 1, token: "test", totalPages: 30, initialPreviewSet: PreviewPaginationProbe.previews(page: 0))
        #expect(await vm.jump(to: 19) == 76)
        #expect(vm.pageCount == 30)
        #expect(vm.previousPage == 18 && vm.nextPage == 20)
        await vm.loadAdjacent(page: 18)
        await vm.loadAdjacent(page: 20)
        #expect(vm.pageCount == 30)
        #expect(vm.allPreviews.map(\.position) == Array(72..<84))
        #expect(await vm.jump(to: 29) == 116)
        #expect(vm.pageCount == 30 && vm.nextPage == nil)
        #expect(await vm.jump(to: 0) == 0)
        #expect(vm.pageCount == 30 && vm.nextPage == 1)
    }

    @Test @MainActor
    func previewPageTotalCanGrowWhenNewMetadataArrives() async {
        let vm = GalleryPreviewsViewModel(loader: { _ in (PreviewPaginationProbe.previews(page: 1), 31) })
        vm.initialize(gid: 1, token: "test", totalPages: 2, initialPreviewSet: PreviewPaginationProbe.previews(page: 0))
        #expect(await vm.jump(to: 1) == 4)
        #expect(vm.pageCount == 31 && vm.nextPage == 2)
    }

    @Test @MainActor
    func previewFailedJumpPreservesCurrentWindow() async {
        let vm = GalleryPreviewsViewModel(loader: { _ in throw URLError(.notConnectedToInternet) })
        vm.initialize(gid: 1, token: "test", totalPages: 5, initialPreviewSet: PreviewPaginationProbe.previews(page: 0))
        #expect(await vm.jump(to: 4) == nil)
        #expect(vm.allPreviews.map(\.position) == Array(0..<4))
        #expect(vm.lowerPage == 0 && vm.upperPage == 0)
        #expect(vm.errors[4] != nil)
        #expect(!vm.isJumping)
    }

    @Test @MainActor
    func previewNewJumpRejectsLateResponse() async {
        let probe = PreviewPaginationProbe(delayedPage: 3)
        let vm = GalleryPreviewsViewModel(loader: { try await probe.load($0) })
        vm.initialize(gid: 1, token: "test", totalPages: 5, initialPreviewSet: PreviewPaginationProbe.previews(page: 0))
        let oldJump = Task { await vm.jump(to: 3) }
        await probe.waitForDelayedRequest()
        #expect(await vm.jump(to: 1) == 4)
        #expect(await oldJump.value == nil)
        #expect(vm.allPreviews.map(\.position) == Array(0..<8))
        #expect(vm.lowerPage == 0 && vm.upperPage == 1)
    }

    @Test
    func cookieSnapshotAcceptsDuplicateNames() throws {
        let first = try #require(HTTPCookie(properties: [
            .name: "ipb_member_id", .value: "first", .domain: "e-hentai.org", .path: "/",
        ]))
        let duplicate = try #require(HTTPCookie(properties: [
            .name: "ipb_member_id", .value: "second", .domain: ".e-hentai.org", .path: "/",
        ]))
        let pass = try #require(HTTPCookie(properties: [
            .name: "ipb_pass_hash", .value: "test-only", .domain: ".e-hentai.org", .path: "/",
        ]))
        let values = EhCookieManager.cookieValues([first, duplicate, pass])
        #expect(values["ipb_member_id"] == "first")
        #expect(values["ipb_pass_hash"] == "test-only")
        #expect(values.count == 2)
        #expect(EhCookieManager.cookieValues([]).isEmpty)
    }

    @Test
    func readerDiskCacheAccountsForOverwriteRemovalAndLimitChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SimpleDiskCache(directory: directory, maxSize: 100)
        #expect(cache.set(Data(repeating: 1, count: 40), forKey: "first"))
        #expect(cache.set(Data(repeating: 2, count: 20), forKey: "first"))
        #expect(cache.usage() == 20)
        #expect(cache.set(Data(repeating: 3, count: 40), forKey: "second"))
        #expect(cache.usage() == 60)
        #expect(cache.remove(key: "first"))
        #expect(cache.usage() == 40)
        cache.updateLimit(maxSize: 20)
        #expect(cache.usage() <= 20)
        #expect(cache.set(Data(repeating: 4, count: 10), forKey: "third"))
        cache.removeAll()
        #expect(cache.usage() == 0)
    }

    @Test
    func readerDiskCacheDoesNotTruncatePageIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SimpleDiskCache(directory: directory, maxSize: 1024)
        let first = "original_123456789012345678_100"
        let second = "original_123456789012345678_101"
        #expect(cache.set(Data([1]), forKey: first))
        #expect(cache.set(Data([2]), forKey: second))
        #expect(cache.getData(forKey: first) == Data([1]))
        #expect(cache.getData(forKey: second) == Data([2]))
    }

    @Test @MainActor
    func readerUsesLocalDownloadInsteadOfScaledDiskCache() async throws {
        let gid = -Int64.random(in: 1...Int64.max)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            SpiderDen.clearCache(forGid: gid, pages: 1)
            try? FileManager.default.removeItem(at: directory)
        }
        SpiderDen.initialize()
        let scaled = try readerTestPNG(width: 4, height: 8)
        #expect(SpiderDen.cacheImageData(scaled, gid: gid, page: 0))
        let localURL = directory.appendingPathComponent("page.png")
        try readerTestPNG(width: 12, height: 4).write(to: localURL)
        let reader = ReaderViewModel()
        reader.gid = gid
        reader.totalPages = 1
        reader.isDownloaded = true
        reader.imageURLs[0] = localURL.absoluteString
        await reader.downloadImageData(0)
        let image = try #require(reader.image(at: 0))
        #expect(image.size.width > image.size.height)
        reader.cancelBackgroundWork()
    }

    @Test @MainActor
    func loadingOriginalDoesNotReuseScaledDiskCache() async throws {
        let gid = -Int64.random(in: 1...Int64.max)
        SpiderDen.initialize()
        defer { SpiderDen.clearCache(forGid: gid, pages: 1) }
        let scaled = try readerTestPNG(width: 4, height: 8)
        let original = try readerTestPNG(width: 12, height: 4)
        #expect(SpiderDen.cacheImageData(scaled, gid: gid, page: 0))
        #expect(SpiderDen.cacheImageData(original, gid: gid, page: 0, original: true))
        let reader = ReaderViewModel()
        reader.gid = gid
        reader.totalPages = 1
        reader.imageURLs[0] = "https://unit.invalid/scaled.png"
        reader.originalImageURLs[0] = "https://unit.invalid/original.png"
        await reader.downloadImageData(0)
        let before = try #require(reader.image(at: 0))
        #expect(before.size.width < before.size.height)
        await reader.loadOriginalImage(0)
        let after = try #require(reader.image(at: 0))
        #expect(after.size.width > after.size.height)
        #expect(reader.pagesUsingOriginalImage.contains(0))
        #expect(SpiderDen.cachedImageData(gid: gid, page: 0) == scaled)
        reader.cancelBackgroundWork()
    }

    @MainActor
    private func readerTestPNG(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<width {
            for y in 0..<height { bitmap.setColor(.white, atX: x, y: y) }
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test @MainActor
    func spritePreviewPipelineCropsCachedSheet() async throws {
        let width = 8
        let height = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let sheet = try #require(context.makeImage())
        let png = try #require(
            NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:])
        )

        let url = try #require(URL(string: "https://unit.test/\(UUID().uuidString).png"))
        let referer = "https://e-hentai.org/"
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.timeoutInterval = 30
        request.setValue(EhRequestBuilder.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        ))
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: png),
            for: request
        )

        let preview = NormalPreview(
            position: 0,
            imageUrl: url.absoluteString,
            pageUrl: "",
            offsetX: 2,
            offsetY: 1,
            clipWidth: 3,
            clipHeight: 2
        )
        let result = await SpritePreviewPipeline.shared.croppedImage(
            for: preview,
            referer: referer
        )

        #expect(result?.image.width == 3)
        #expect(result?.image.height == 2)
        URLCache.shared.removeCachedResponse(for: request)
    }

    @Test @MainActor
    func doublePageLayoutCanPairTheFirstPage() {
        let viewModel = ReaderViewModel()
        viewModel.totalPages = 5
        viewModel.isDoublePageEnabled = true

        viewModel.firstPageStandalone = true
        viewModel.computeSpreads()
        #expect(viewModel.spreads.map(\.pages) == [[0], [1, 2], [3, 4]])

        viewModel.firstPageStandalone = false
        viewModel.computeSpreads()
        #expect(viewModel.spreads.map(\.pages) == [[0, 1], [2, 3], [4]])
    }

    @Test
    func subscriptionURLUsesWatchedFeedForSelectedSite() {
        var builder = ListUrlBuilder()
        builder.mode = .subscription
        builder.category = 0x4
        builder.pageIndex = 2

        let eURL = builder.build(site: .eHentai)
        let exURL = builder.build(site: .exHentai)

        #expect(eURL.hasPrefix("https://e-hentai.org/watched?"))
        #expect(exURL.hasPrefix("https://exhentai.org/watched?"))
        #expect(eURL.contains("f_cats=1019"))
        #expect(eURL.contains("page=2"))
    }

    @Test @MainActor
    func subscriptionCanBeSelectedAsLaunchPage() {
        #expect(MainTabView.Tab.fromLaunchPage(6) == .subscription)
    }

    @Test @MainActor
    func myTagParserAndCanonicalizerHandleCurrentMarkupVariants() throws {
        let html = """
        <div id="usertags_outer">
          <div class="header">My Tags</div>
          <div class="wrapper">
            <div id="usertag_12">
              <a id="tagpreview_12" title='f:&quot;big breasts$&quot;'>preview</a>
              <input id="tagwatch_12" checked>
              <input id="taghide_12">
              <input id="tagcolor_12" placeholder="#ff0000">
              <input id="tagweight_12" value="5">
            </div>
          </div>
        </div>
        """

        let list = try MyTagListParser.parse(html)
        let tag = try #require(list.userTags.first)
        #expect(tag.tagName == "f:\"big breasts$\"")
        #expect(tag.watched)
        #expect(GalleryDetailViewModel.canonicalTag(tag.tagName) == "female:big breasts")
        #expect(GalleryDetailViewModel.canonicalTag("female:big   breasts") == "female:big breasts")
    }

    @Test
    func tagGalleryResponsePreservesVoteAndPowerState() throws {
        let tagPane = """
        <table><tbody><tr>
          <td class="tc">female:</td>
          <td><div>
            <a class="gt"><span class="tup"></span>glasses|12</a>
            <a class="gtw"><span class="tdn"></span>low power|2</a>
            <a class="gtl">neutral tag</a>
          </div></td>
        </tr></tbody></table>
        """
        let data = try JSONSerialization.data(withJSONObject: ["tagpane": tagPane])
        let groups = try GalleryDetailParser.parseVoteTagResponse(data)
        let female = try #require(groups.first)

        #expect(female.groupName == "female")
        #expect(female.tags == ["glasses", "low power", "neutral tag"])
        #expect(female.metadata["glasses"]?.vote == .up)
        #expect(female.metadata["glasses"]?.power == .solid)
        #expect(female.metadata["low power"]?.vote == .down)
        #expect(female.metadata["low power"]?.power == .weak)
        #expect(female.metadata["neutral tag"]?.vote == GalleryTagVoteStatus.none)
        #expect(female.metadata["neutral tag"]?.power == .active)
    }

    @Test @MainActor
    func galleryPaginationPrefersOpaqueCursorAndStopsOnDuplicatePage() {
        var state = GalleryPaginationState()
        let first = state.merge([
            GalleryInfo(gid: 1), GalleryInfo(gid: 1), GalleryInfo(gid: 2)
        ], replacing: true)
        state.consume(
            nextPage: 1,
            prevHref: nil,
            nextHref: "https://e-hentai.org/?next=opaque",
            totalPages: -1,
            loadedPage: 0,
            appendedCount: first.count,
            replacing: true
        )

        #expect(first.map(\.gid) == [1, 2])
        #expect(state.nextRequest == .href("https://e-hentai.org/?next=opaque"))

        let duplicatePage = state.merge([GalleryInfo(gid: 1), GalleryInfo(gid: 2)], replacing: false)
        state.consume(
            nextPage: nil,
            prevHref: nil,
            nextHref: "https://e-hentai.org/?next=same",
            totalPages: -1,
            loadedPage: 0,
            appendedCount: duplicatePage.count,
            replacing: false
        )
        #expect(duplicatePage.isEmpty)
        #expect(state.nextRequest == nil)
    }

    @Test @MainActor
    func galleryPaginationFallsBackToServerPageNumber() {
        var state = GalleryPaginationState()
        _ = state.merge([GalleryInfo(gid: 10)], replacing: true)
        state.consume(
            nextPage: 4,
            prevHref: nil,
            nextHref: nil,
            totalPages: 8,
            loadedPage: 3,
            appendedCount: 1,
            replacing: true
        )

        #expect(state.nextRequest == .page(4))
        #expect(state.totalPages == 8)
    }

    @Test @MainActor
    func galleryPaginationSnapshotPreservesBothLoadedBoundaries() throws {
        var state = GalleryPaginationState()
        let pageTwo = [GalleryInfo(gid: 20), GalleryInfo(gid: 21)]
        _ = state.merge(pageTwo, replacing: true)
        state.consume(
            nextPage: nil,
            firstHref: "https://e-hentai.org/",
            prevHref: "https://e-hentai.org/?prev=two",
            nextHref: "https://e-hentai.org/?next=two",
            lastHref: "https://e-hentai.org/?last=one",
            totalPages: 8,
            loadedPage: 2,
            appendedCount: pageTwo.count,
            replacing: true
        )

        let pageThree = [GalleryInfo(gid: 30)]
        _ = state.merge(pageThree, replacing: false)
        state.consume(
            nextPage: nil,
            prevHref: "ignored-after-append",
            nextHref: "https://e-hentai.org/?next=three",
            totalPages: 8,
            loadedPage: 3,
            appendedCount: pageThree.count,
            replacing: false
        )

        var restored = GalleryPaginationState()
        let allGalleries = pageTwo + pageThree
        restored.restore(state.snapshot, galleries: allGalleries)
        #expect(restored.firstLoadedPage == 2)
        #expect(restored.lastLoadedPage == 3)
        #expect(restored.prevHref == "https://e-hentai.org/?prev=two")
        #expect(restored.nextRequest == .href("https://e-hentai.org/?next=three"))
        #expect(restored.merge([GalleryInfo(gid: 21)], replacing: false).isEmpty)

        restored.consumePrepending(
            prevHref: "https://e-hentai.org/?prev=one",
            totalPages: 8,
            loadedPage: 1,
            prependedCount: 1
        )
        #expect(restored.firstLoadedPage == 1)
        #expect(restored.lastLoadedPage == 3)
        #expect(restored.prevHref == "https://e-hentai.org/?prev=one")
    }

    @Test @MainActor
    func systemGalleryDeepLinkRoundTripsIdentity() throws {
        let gallery = GalleryInfo(gid: 12345, token: "abcdef1234", title: "Test")
        let url = try #require(SystemGalleryIntegration.deepLink(for: gallery))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "ehviewer")
        #expect(components.host == "gallery")
        #expect(components.queryItems?.first(where: { $0.name == "gid" })?.value == "12345")
        #expect(components.queryItems?.first(where: { $0.name == "token" })?.value == "abcdef1234")
    }

    @Test
    func galleryMetadataSurvivesEveryPersistenceBridge() {
        let gallery = GalleryInfo(
            gid: 42,
            token: "token",
            title: "English title",
            titleJpn: "中文标题",
            thumb: "https://unit.test/cover.jpg",
            category: .manga,
            posted: "2026-08-21 10:00",
            uploader: "uploader",
            rating: 4.75,
            pages: 128,
            simpleLanguage: "ZH"
        )

        let restored = [
            gallery.historyRecord().galleryInfo,
            gallery.downloadRecord(state: 0).galleryInfo,
            gallery.localFavoriteRecord().galleryInfo,
        ]
        for value in restored {
            #expect(value.gid == gallery.gid)
            #expect(value.token == gallery.token)
            #expect(value.title == gallery.title)
            #expect(value.titleJpn == gallery.titleJpn)
            #expect(value.thumb == gallery.thumb)
            #expect(value.category == gallery.category)
            #expect(value.posted == gallery.posted)
            #expect(value.uploader == gallery.uploader)
            #expect(value.rating == gallery.rating)
            #expect(value.pages == gallery.pages)
            #expect(value.simpleLanguage == gallery.simpleLanguage)
        }
    }

    @Test
    func galleryTimestampParsesServerUTCAndGalleryAuthors() throws {
        let date = try #require(GalleryTimestamp.serverDate(from: "2026-08-21 12:34"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 21)
        #expect(components.hour == 12)
        #expect(components.minute == 34)

        let gallery = GalleryInfo(simpleTags: [
            "artist:Alice", "female:glasses", "artist:alice", "artist:Bob",
        ])
        #expect(gallery.authorNames == ["Alice", "Bob"])
    }

    @Test
    func downloadLifecycleRecoversAndCompletesDeterministically() {
        #expect(
            DownloadTaskLifecycle.recoveredState(from: DownloadManager.stateDownload)
                == DownloadManager.stateWait
        )
        #expect(
            DownloadTaskLifecycle.recoveredState(from: DownloadManager.stateFinish)
                == DownloadManager.stateFinish
        )
        #expect(DownloadTaskLifecycle.canResume(from: DownloadManager.stateNone))
        #expect(DownloadTaskLifecycle.canResume(from: DownloadManager.stateFailed))
        #expect(!DownloadTaskLifecycle.canResume(from: DownloadManager.stateWait))
        #expect(!DownloadTaskLifecycle.canResume(from: DownloadManager.stateDownload))
        #expect(!DownloadTaskLifecycle.canResume(from: DownloadManager.stateFinish))
        #expect(
            DownloadTaskLifecycle.completionState(finishedPages: 12, totalPages: 12)
                == DownloadManager.stateFinish
        )
        #expect(
            DownloadTaskLifecycle.completionState(finishedPages: 11, totalPages: 12)
                == DownloadManager.stateFailed
        )
        #expect(
            DownloadTaskLifecycle.completionState(finishedPages: 0, totalPages: 0)
                == DownloadManager.stateFailed
        )
    }

    @Test @MainActor
    func appSettingsClampValuesAndPersistVisibleToggles() {
        let settings = AppSettings.shared
        let originalPreload = settings.preloadImage
        let originalTimeout = settings.downloadTimeout
        let originalInterval = settings.autoPageInterval
        let originalPages = settings.showGalleryPages
        let originalRating = settings.showGalleryRating
        let originalFixThumb = settings.fixThumbUrl
        defer {
            settings.preloadImage = originalPreload
            settings.downloadTimeout = originalTimeout
            settings.autoPageInterval = originalInterval
            settings.showGalleryPages = originalPages
            settings.showGalleryRating = originalRating
            settings.fixThumbUrl = originalFixThumb
        }

        settings.preloadImage = -10
        #expect(settings.preloadImage == 1)
        settings.preloadImage = 99
        #expect(settings.preloadImage == 10)

        settings.downloadTimeout = 1
        #expect(settings.downloadTimeout == 10)
        settings.downloadTimeout = 999
        #expect(settings.downloadTimeout == 120)

        settings.autoPageInterval = 0
        #expect(settings.autoPageInterval == 1)
        settings.autoPageInterval = 99
        #expect(settings.autoPageInterval == 60)

        settings.showGalleryPages = !originalPages
        settings.showGalleryRating = !originalRating
        settings.fixThumbUrl = !originalFixThumb
        #expect(settings.showGalleryPages == !originalPages)
        #expect(settings.showGalleryRating == !originalRating)
        #expect(settings.fixThumbUrl == !originalFixThumb)
    }

    @Test @MainActor
    func readerPrefetchPlanIsBoundedOrderedAndClamped() {
        #expect(
            ReaderPrefetchPlanner.pages(
                around: 5,
                totalPages: 20,
                ahead: 3,
                behind: 1
            ) == [6, 4, 7, 8]
        )
        #expect(
            ReaderPrefetchPlanner.pages(
                around: 0,
                totalPages: 3,
                ahead: 10,
                behind: 2
            ) == [1, 2]
        )
        #expect(
            ReaderPrefetchPlanner.retainedPages(
                around: 9,
                totalPages: 10,
                radius: 2
            ) == Set([7, 8, 9])
        )
    }

    @Test @MainActor
    func continueReadingRouteRoundTripsWithoutPreviewPayload() throws {
        let route = ReaderWindowRoute(
            gid: 123,
            token: "token",
            pages: 40,
            previewSet: nil,
            initialPage: 17
        )
        let data = try #require(AppNavigationRequest.encodedReaderRoute(route))
        let decoded = try #require(AppNavigationRequest.readerRoute(from: data))

        #expect(decoded.gid == route.gid)
        #expect(decoded.token == route.token)
        #expect(decoded.pages == route.pages)
        #expect(decoded.initialPage == route.initialPage)
        #expect(decoded.previewSet == nil)
    }

}
