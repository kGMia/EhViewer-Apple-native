//
//  ehviewer_appleTests.swift
//  ehviewer appleTests
//
//  Created by 晓卡 on 2026/2/12.
//

import Testing
import AppKit
import EhModels
import EhAPI
import EhParser
import EhDatabase
import EhDownload
import EhSettings
@testable import ehviewer_apple

@Suite(.serialized)
struct ehviewer_appleTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
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
