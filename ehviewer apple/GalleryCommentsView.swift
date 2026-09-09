//
//  GalleryCommentsView.swift
//  ehviewer apple
//
//  评论列表页面 (对齐 Android GalleryCommentsScene)
//

import SwiftUI
import EhModels
import EhAPI
import EhCookie
import EhSettings
import Translation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct GalleryCommentsView: View {
    let gid: Int64
    let token: String
    let apiUid: Int64
    let apiKey: String
    let initialComments: [GalleryComment]
    let hasMore: Bool
    var onCommentsChange: ((GalleryCommentList) async -> Void)? = nil
    var onClose: (() -> Void)? = nil
    
    @State private var vm = GalleryCommentsViewModel()
    @State private var commentText = ""
    @State private var linkedGallery: GalleryInfo?
    @State private var translationText = ""
    @State private var showsTranslation = false
    @Environment(\.responsiveLayout) private var responsiveLayout

    private var horizontalContentInset: CGFloat {
        responsiveLayout.horizontalSizeClass == .regular
            && (responsiveLayout.height > responsiveLayout.width
                || AppSettings.shared.wideScreenListMode == 1) ? 24 : 0
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.comments.indices, id: \.self) { index in
                    let comment = vm.comments[index]
                    commentRow(comment)
                    
                    if index < vm.comments.index(before: vm.comments.endIndex) {
                        Divider()
                            .padding(.leading)
                    }
                }
                
                // 加载更多
                if vm.hasMore {
                    Button {
                        Task { await vm.loadAllComments(gid: gid, token: token) }
                    } label: {
                        HStack {
                            if vm.isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(AppLocalization.localized(vm.isLoading ? "加载中..." : "加载全部评论"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .disabled(vm.isLoading)
                }
            }
            .padding(.horizontal, horizontalContentInset)
        }
        .navigationTitle("评论 (\(vm.comments.count)\(vm.hasMore ? "+" : ""))")
        .navigationDestination(item: $linkedGallery) { gallery in
            GalleryDetailView(gallery: gallery)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .translationPresentation(
            isPresented: $showsTranslation,
            text: translationText
        )
        .task(id: gid) {
            vm.setInitialComments(initialComments, hasMore: hasMore)
            vm.isSignedIn = EhCookieManager.shared.isSignedIn
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commentComposer
                .padding(.horizontal, 12 + horizontalContentInset)
                .padding(.bottom, 10)
        }
        .alert("评论操作失败", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private var commentComposer: some View {
        HStack(spacing: 8) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("关闭")
            }

            if vm.isSignedIn {
                TextField("撰写评论（支持 BBCode）", text: $commentText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 38)

                Button {
                    let submittedText = commentText
                    Task {
                        if let updated = await vm.postComment(
                            submittedText,
                            gid: gid,
                            token: token
                        ) {
                            commentText = ""
                            await onCommentsChange?(updated)
                        }
                    }
                } label: {
                    if vm.isPostingComment {
                        ProgressView()
                            .controlSize(.small)
                            #if os(iOS)
                            .frame(width: 38, height: 38)
                            #else
                            .frame(width: 70, height: 38)
                            #endif
                    } else {
                        #if os(iOS)
                        Image(systemName: "paperplane.fill")
                            .frame(width: 38, height: 38)
                            .accessibilityLabel("发表评论")
                        #else
                        Label("发表评论", systemImage: "paperplane.fill")
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                        #endif
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                #if os(iOS)
                .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .circle)
                .frame(width: 38, height: 38)
                #else
                .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .capsule)
                .frame(height: 38)
                #endif
                .disabled(
                    vm.isPostingComment
                        || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            } else {
                Label("登录后可发表评论", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(7)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
    
    // MARK: - 单条评论
    
    private func commentRow(_ comment: GalleryComment) -> some View {
        let attributedComment = vm.attributedText(for: comment)
        let plainComment = String(attributedComment.characters)

        return VStack(alignment: .leading, spacing: 8) {
            // 头部：用户名、时间、分数
            HStack {
                Text(comment.user)
                    .font(.subheadline.bold())
                
                Spacer()
                
                Text(GalleryTimestamp.localizedString(from: comment.time))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if comment.score != 0 {
                    Text(comment.score > 0 ? "+\(comment.score)" : "\(comment.score)")
                        .font(.caption)
                        .foregroundStyle(comment.score > 0 ? .green : .red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(comment.score > 0 ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            
            // 评论内容 (HTML 转纯文本，完整显示)
            Text(attributedComment)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        copyComment(plainComment)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }

                    ShareLink(item: plainComment) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button {
                        translationText = plainComment
                        showsTranslation = true
                    } label: {
                        Label("翻译", systemImage: "translate")
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    guard let gallery = GalleryCommentLinks.gallery(from: url) else {
                        return .systemAction
                    }
                    linkedGallery = gallery
                    return .handled
                })
            
            // 投票按钮
            if comment.voteUpAble || comment.voteDownAble {
                HStack(spacing: 16) {
                    if comment.voteUpAble {
                        Button {
                            Task {
                                await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id,
                                    // EH toggles a comment vote when the same
                                    // direction is submitted again; `0` is not
                                    // a valid cancel request on all edge nodes.
                                    vote: 1
                                )
                            }
                        } label: {
                            if vm.isVoting(comment.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(AppLocalization.localized(comment.voteUpEd ? "取消赞同" : "赞同"), systemImage: comment.voteUpEd ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.isVoting(comment.id))
                    }
                    
                    if comment.voteDownAble {
                        Button {
                            Task {
                                await vm.voteComment(
                                    apiUid: apiUid, apiKey: apiKey,
                                    gid: gid, token: token,
                                    commentId: comment.id,
                                    vote: -1
                                )
                            }
                        } label: {
                            if vm.isVoting(comment.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(AppLocalization.localized(comment.voteDownEd ? "取消反对" : "反对"), systemImage: comment.voteDownEd ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.isVoting(comment.id))
                    }
                }
            }
            
            // 编辑信息
            if let lastEdited = comment.lastEdited {
                Text("最后编辑：\(GalleryTimestamp.localizedString(from: lastEdited))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func copyComment(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class GalleryCommentsViewModel {
    var comments: [GalleryComment] = []
    var hasMore = false
    var isLoading = false
    var isPostingComment = false
    var isSignedIn = false
    var errorMessage: String?
    private var votingCommentIDs: Set<Int64> = []

    @ObservationIgnored
    private var attributedBodies: [GalleryCommentTextKey: AttributedString] = [:]
    
    func setInitialComments(_ comments: [GalleryComment], hasMore: Bool) {
        rebuildPlainTextCache(for: comments)
        self.comments = comments
        self.hasMore = hasMore
    }

    func attributedText(for comment: GalleryComment) -> AttributedString {
        attributedBodies[GalleryCommentTextKey(comment)]
            ?? GalleryCommentLinks.attributedText(fromHTML: comment.comment)
    }

    func isVoting(_ commentId: Int64) -> Bool {
        votingCommentIDs.contains(commentId)
    }
    
    func loadAllComments(gid: Int64, token: String) async {
        guard !isLoading else { return }
        isLoading = true
        
        do {
            let result = try await EhAPI.shared.getAllComments(gid: gid, token: token)
            try Task.checkCancellation()
            rebuildPlainTextCache(for: result.comments)
            comments = result.comments
            hasMore = result.hasMore
            isLoading = false
        } catch is CancellationError {
            isLoading = false
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
            isLoading = false
        }
    }

    @discardableResult
    func postComment(_ text: String, gid: Int64, token: String) async -> GalleryCommentList? {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSignedIn, !comment.isEmpty, !isPostingComment else { return nil }

        isPostingComment = true
        defer { isPostingComment = false }

        do {
            let site = AppSettings.shared.gallerySite
            let url = EhURL.galleryDetailUrl(gid: gid, token: token, site: site)
            let result = try await EhAPI.shared.commentGallery(url: url, comment: comment)
            rebuildPlainTextCache(for: result.comments)
            comments = result.comments
            hasMore = result.hasMore
            errorMessage = nil

            if var cachedDetail = GalleryCache.shared.getDetail(gid: gid) {
                cachedDetail.comments = result
                GalleryCache.shared.putDetail(cachedDetail)
            }
            Haptics.success()
            return result
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
            return nil
        }
    }

    /// 评论投票 — 连通 EhAPI.voteComment (对齐 Android GalleryCommentsScene.voteComment)
    func voteComment(
        apiUid: Int64, apiKey: String,
        gid: Int64, token: String,
        commentId: Int64, vote: Int
    ) async {
        guard !votingCommentIDs.contains(commentId) else { return }
        votingCommentIDs.insert(commentId)
        defer { votingCommentIDs.remove(commentId) }

        do {
            var resolvedUid = apiUid
            var resolvedKey = apiKey

            // 详情缓存可能生成于登录前，此时评论仍可显示，但缓存中的 API
            // 凭据为空。投票前自动刷新详情，避免按钮看似可用却始终失败。
            if resolvedUid <= 0 || resolvedKey.isEmpty {
                let site = AppSettings.shared.gallerySite
                let url = EhURL.galleryDetailUrl(gid: gid, token: token, site: site)
                let detail = try await EhAPI.shared.getGalleryDetail(url: url)
                resolvedUid = detail.apiUid
                resolvedKey = detail.apiKey
            }

            guard resolvedUid > 0, !resolvedKey.isEmpty else {
                errorMessage = AppLocalization.localized("登录凭据不可用，请重新登录后再投票。")
                return
            }

            let result = try await EhAPI.shared.voteComment(
                apiUid: resolvedUid, apiKey: resolvedKey,
                gid: gid, token: token,
                commentId: commentId, commentVote: vote
            )
            // 更新本地评论状态
            if let idx = comments.firstIndex(where: { $0.id == commentId }) {
                comments[idx].score = result.score
                // vote == 1 → 用户点赞; vote == -1 → 用户点踩
                // result.vote: 服务端返回的最终投票状态 (1 = 已赞, -1 = 已踩, 0 = 取消)
                comments[idx].voteUpEd = result.vote == 1
                comments[idx].voteDownEd = result.vote == -1
            }
        } catch {
            errorMessage = EhError.localizedMessage(for: error)
        }
    }

    private func rebuildPlainTextCache(for comments: [GalleryComment]) {
        var cache: [GalleryCommentTextKey: AttributedString] = [:]
        cache.reserveCapacity(comments.count)

        for comment in comments {
            cache[GalleryCommentTextKey(comment)] = GalleryCommentLinks.attributedText(
                fromHTML: comment.comment
            )
        }
        attributedBodies = cache
    }
}

private struct GalleryCommentTextKey: Hashable {
    let id: Int64
    let body: String

    init(_ comment: GalleryComment) {
        id = comment.id
        body = comment.comment
    }
}



#Preview {
    NavigationStack {
        GalleryCommentsView(
            gid: 12345,
            token: "abc123",
            apiUid: -1,
            apiKey: "",
            initialComments: [],
            hasMore: true
        )
    }
}
