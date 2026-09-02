//
//  NavigationComponents.swift
//  ehviewer apple
//
//  全局导航规范组件:
//  1. AppBackButton — 统一返回按钮 (Chevron 圆形半透明)
//  2. EdgeSwipeBackModifier — 恢复边缘滑动返回手势
//  3. NavigationBarCompact — 强制 inline 标题栏修饰符
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Content-column route back action. Wide layouts replace the feed in-place
/// instead of pushing onto a NavigationStack, so the search chrome needs an
/// explicit way to pop that route.
struct ContentRouteBackAction {
    let perform: () -> Void
}

private struct ContentRouteBackActionKey: EnvironmentKey {
    static let defaultValue: ContentRouteBackAction? = nil
}

extension EnvironmentValues {
    var contentRouteBackAction: ContentRouteBackAction? {
        get { self[ContentRouteBackActionKey.self] }
        set { self[ContentRouteBackActionKey.self] = newValue }
    }
}

/// Content-column search chrome for macOS. Keeping search in the content view
/// avoids SwiftUI promoting `.searchable` into the window's trailing toolbar.
/// Native Material supplies the translucent scroll-edge treatment.
struct ContentColumnSearchBar<Actions: View>: View {
    @Binding var text: String
    let prompt: String
    var isFloating = false
    @ViewBuilder let actions: () -> Actions

    @ViewBuilder
    var body: some View {
        if isFloating {
            HStack(spacing: 8) {
                searchField
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)

                actions()
            }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
        } else {
            HStack(spacing: 8) {
                searchField
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: Capsule())

                actions()
            }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 12)
    }
}

/// 独立的 Liquid Glass 筛选胶囊。收藏夹和下载标签共用这一实现。
/// 外层横向 ScrollView 负责关闭裁剪并预留投影绘制空间；这里保留系统
/// 原生的玻璃、光照和交互反馈，不再尝试裁掉投影本身。
struct LiquidGlassFilterChip<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            (isSelected ? Glass.regular.tint(Color.accentColor) : Glass.regular)
                .interactive(),
            in: .capsule
        )
    }
}

// MARK: - 1. 统一返回按钮 (对齐 Android Toolbar NavigationIcon)

/// 全局统一返回按钮 — 所有二级及深层页面使用同一样式
///
/// 样式: Chevron 图标 + 半透明圆形背景
/// 位置: 左上角叠加 (overlay alignment: .topLeading)
///
/// 使用方式:
/// ```swift
/// .overlay(alignment: .topLeading) {
///     AppBackButton { dismiss() }
/// }
/// ```
struct AppBackButton: View {
    let action: () -> Void
    
    /// 背景风格: 当页面有深色/图片背景时使用 dark, 普通页面用 light
    var style: Style = .dark
    
    enum Style {
        case dark   // 白色图标 + 黑色半透明背景 (用于图片/深色背景上)
        case light  // 系统颜色 + 浅色材质背景 (用于普通列表页)
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(style == .dark ? .white : Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            (style == .dark ? Glass.regular.tint(.black.opacity(0.28)) : Glass.regular)
                .interactive(),
            in: .circle
        )
        .accessibilityLabel("返回")
    }
}

// MARK: - 2. View 扩展

extension View {
    /// Apply system searchable chrome only in compact navigation. Wide layouts
    /// render search inside their content column instead of the window toolbar.
    @ViewBuilder
    func searchableWhen(
        _ enabled: Bool,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        if enabled {
            self.searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }

    /// 紧凑导航栏修饰符 — 强制 inline 标题 + 隐藏大标题空间
    @ViewBuilder
    func compactNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
