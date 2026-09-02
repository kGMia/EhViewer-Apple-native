# EhViewer Apple Native

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-brightgreen" alt="Version"/>
  <img src="https://img.shields.io/badge/platform-iOS%2026.2%2B%20%7C%20iPadOS%2026.2%2B%20%7C%20macOS%2026.2%2B-blue" alt="Platform"/>
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift 6.0"/>
  <img src="https://img.shields.io/badge/license-Apache%202.0-green" alt="License"/>
</p>

EhViewer Apple Native 是适用于 iPhone、iPad 和 Mac 的 [E-Hentai](https://e-hentai.org) / [ExHentai](https://exhentai.org) 原生客户端。项目以 SwiftUI 为主体，针对 Apple 平台重新设计导航、搜索、画廊详情、阅读器与下载体验。

本仓库由 [felixchaos/EhViewer-Apple](https://github.com/felixchaos/EhViewer-Apple) Fork 并持续开发，保留原项目的 Apache License 2.0 授权与版权信息。上游更新会先经过差异审查，再选择性适配到本项目，避免覆盖本 Fork 的跨平台界面和功能改造。

> **致敬**: 本项目灵感来源于 Android 端的 [EhViewer](https://github.com/Ehviewer-Overhauled/Ehviewer) 和 [EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ)，感谢原作者的出色工作。

---

## 📢 v1.0.0

这是本 Fork 的首个发行准备版本，重点是原生化、跨平台一致性、阅读体验与稳定性。

### 原生体验

- SwiftUI 响应式导航，自动适配 iPhone 单栏、iPad 分栏与 macOS 窗口
- Liquid Glass 风格的悬浮搜索、工具栏、阅读控件与紧凑画廊页头
- 列表和瀑布流两种浏览方式，支持标签、上传者、历史与保存的搜索
- 简体中文、繁体中文（台湾）和英文（美国）本地化
- App Shortcuts、macOS 菜单命令、系统分享与接力入口

### 阅读与媒体

- 横向翻页、从右到左、从左到右和纵向连续阅读
- 单页／双页、首页单独显示、缩放、翻页动画、手势与键盘控制
- 原图加载、保存、拷贝、图片文字识别与系统翻译
- 动图显示、阅读进度、主题色进度条及图片氛围背景
- 内存与有界磁盘缓存；已下载画廊使用本地文件快速读取

### 资料管理

- 云端／本地收藏、历史、稍后再看和标签屏蔽
- 后台下载、暂停／继续、批量选择、文件大小与自定义下载位置
- iPhone 和 iPad 下载 Live Activity，可暂停任务并跳转到下载页面
- 搜索结果多层导航、连续分页和位置恢复
- 评论发表、赞同／反对，以及评论中的画廊链接识别

### 稳定性与安全

- Swift 6 并发隔离与主线程负载优化
- 登录凭据由系统钥匙串保存，Cookie 容器仅保留会话副本
- 图片请求合并、后台降采样、预览精灵图共享解码与内存压力响应
- 阅读预取按设备、网络状态和阅读方向调整
- 网络请求使用系统 TLS、代理与 VPN，并提供受控的连接回退

更完整的变更记录请查看 [CHANGELOG.md](CHANGELOG.md)，发行前检查项目见 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。

## 📦 项目结构

```
EhViewer-Apple/
├── ehviewer apple/              # 主 App 目标
│   ├── *View.swift              # SwiftUI 视图层
│   ├── ehviewer_appleApp.swift  # App 入口
│   └── Assets.xcassets/         # 资源文件
├── Packages/                    # Swift Package 模块化架构
│   ├── EhCore/                  # 核心模型、数据库、设置
│   │   ├── EhModels/            #   数据模型
│   │   ├── EhDatabase/          #   GRDB 数据库
│   │   └── EhSettings/          #   全局配置
│   ├── EhNetwork/               # 网络层
│   │   ├── EhAPI/               #   API 请求引擎
│   │   ├── EhCookie/            #   Cookie 管理
│   │   └── EhDNS/               #   DNS 与域名前置
│   ├── EhParser/                # HTML/JSON 解析器
│   ├── EhSpider/                # 图片抓取引擎
│   ├── EhDownload/              # 下载管理器
│   └── EhUI/                    # 可复用 UI 组件
└── ehviewer apple.xcodeproj/    # Xcode 工程文件
```

## 🛠️ 环境要求

| 项目 | 最低版本 |
|------|---------|
| Xcode | 26.2+ |
| Swift | 6.0 |
| iOS / iPadOS | 26.2+ |
| macOS | 26.2+ |

## 🚀 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/kGMia/EhViewer-Apple-native.git
cd EhViewer-Apple-native
```

### 2. 打开项目

```bash
open "ehviewer apple.xcodeproj"
```

### 3. 构建运行

在 Xcode 中选择 **My Mac**、模拟器或已连接的设备，然后按 `⌘R` 运行。

> **注意**: Swift Package 依赖会在首次打开时自动解析，请确保网络畅通。

### 4. 安装到 iPhone / iPad

将应用安装到 iOS 真机需要以下步骤：

#### 前置条件

1. **Apple ID** — 免费 Apple ID 即可（无需付费开发者账号）
2. **Xcode 26.2+** — 从 Mac App Store 安装
3. **USB 数据线** — 用于连接 iPhone/iPad（首次需要有线连接）

#### 配置签名

1. 打开 Xcode，进入菜单 **Xcode → Settings → Accounts**
2. 点击左下角 **+**，选择 **Apple ID**，登录你的 Apple ID
3. 在项目导航器中选择 **ehviewer apple** 项目（蓝色图标）
4. 选择 **Signing & Capabilities** 标签页
5. 勾选 **Automatically manage signing**
6. 在 **Team** 下拉菜单中选择你的 Apple ID 对应的团队（通常是 `你的名字 (Personal Team)`）
7. 如果 **Bundle Identifier** 冲突，修改为唯一值，例如 `com.yourname.ehviewer`

#### 构建安装

1. 用 USB 线将 iPhone/iPad 连接到 Mac
2. 在设备上弹出的 **"信任此电脑"** 对话框中选择 **信任**
3. 在 Xcode 顶部工具栏的设备列表中选择你的 iPhone/iPad
4. 按 `⌘R` 构建并安装

#### 首次安装注意事项

- **设备信任**: 首次安装后需要在 iPhone/iPad 上前往 **设置 → 通用 → VPN与设备管理**，找到你的开发者描述文件并点击 **信任**
- **免费账号限制**: 免费 Apple ID 签名的应用有效期为 **7 天**，到期后需要重新连接 Mac 用 Xcode 重新安装
- **无线调试**: 首次有线连接成功后，可在 Xcode 中启用无线调试（**Window → Devices and Simulators**，勾选 **Connect via network**）

### 5. 构建 macOS 分发安装包（Developer ID 签名 + 公证）

如果你拥有 Apple Developer 付费账号（$99/年），可以使用 `distribute_mac.sh` 脚本构建一个**已公证、无安全警告、有效期约1年**的 `.dmg` 安装包，直接分发给其他用户。

#### 5.1 获取 App 专用密码 (App-Specific Password)

Apple 公证服务要求使用 App 专用密码（而非你的 Apple ID 登录密码）：

1. 访问 [appleid.apple.com](https://appleid.apple.com/)，使用 Apple ID 登录
2. 进入 **登录和安全 → App 专用密码**（或直接访问 [appleid.apple.com/account/manage/section/security](https://appleid.apple.com/account/manage/section/security)）
3. 点击 **生成 App 专用密码**
4. 输入一个标签名（如 `ehviewer-notarize`），点击 **创建**
5. 记录生成的密码（格式如 `xxxx-xxxx-xxxx-xxxx`），**此密码只显示一次**

#### 5.2 查找 Team ID

1. 访问 [developer.apple.com/account](https://developer.apple.com/account)
2. 在页面上方找到 **Membership Details**
3. **Team ID** 是一个 10 位字母数字组合

或者在终端中执行：
```bash
# 列出 Keychain 中所有 Developer ID 证书及 Team ID
security find-identity -v -p codesigning | grep "Developer ID"
```

#### 5.3 确保已安装 Developer ID 证书

1. 打开 Xcode → **Settings → Accounts**
2. 选择你的 Apple ID → 点击 **Manage Certificates**
3. 如果没有 **Developer ID Application** 证书，点击左下角 **+** 创建
4. 证书会自动下载到 Keychain

#### 5.4 配置环境变量

在项目根目录创建 `.env` 文件（已加入 `.gitignore`，不会被提交）：

```bash
# .env
APPLE_ID=your-email@example.com
TEAM_ID=YOUR_TEAM_ID
APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

或者直接导出环境变量：
```bash
export APPLE_ID="your-email@example.com"
export TEAM_ID="YOUR_TEAM_ID"
export APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

#### 5.5 运行构建脚本

```bash
./distribute_mac.sh
```

脚本会自动完成以下流程：
1. **Archive** — Release 模式编译项目
2. **导出 .app** — 使用 Developer ID 方式导出
3. **深度签名** — Hardened Runtime + Timestamp
4. **创建 DMG** — 带 Applications 快捷方式的安装镜像
5. **Apple 公证** — 提交至 Apple 服务器并等待审核通过
6. **植入票据** — Staple 公证票据到 DMG

完成后在 `build/` 目录下生成 `EhViewer-Apple-1.0.0.dmg`。

> **签名有效期**: Developer ID Application 证书有效期为 **1 年**（从证书创建日起算）。到期前在 Xcode 中续签证书，重新运行脚本即可。

## 📱 截图

<!-- 
TODO: 添加 App 截图
<p align="center">
  <img src="screenshots/home.png" width="200"/>
  <img src="screenshots/reader.png" width="200"/>
  <img src="screenshots/download.png" width="200"/>
</p>
-->

欢迎通过 Issue 或 Pull Request 补充最新平台截图。

## 🔄 同步上游

如需在自己的克隆中检查上游更新：

```bash
git remote add upstream https://github.com/felixchaos/EhViewer-Apple.git
git fetch upstream
git log --oneline HEAD..upstream/main
```

由于本 Fork 已对导航、阅读器和数据流进行较大调整，建议逐项审查或选择性移植上游提交，不建议直接强制覆盖当前分支。

## 🤝 参与贡献

欢迎贡献代码！请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 了解贡献流程。

简要步骤：

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'feat: 添加某个功能'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

## 📋 更新日志

查看 [CHANGELOG.md](CHANGELOG.md) 了解版本历史和更新内容。

## 📄 开源协议

本项目基于 [Apache License 2.0](LICENSE) 协议开源 — 查看 [LICENSE](LICENSE) 文件获取详细信息。

## 🙏 致谢

- [felixchaos/EhViewer-Apple](https://github.com/felixchaos/EhViewer-Apple) — 本项目的上游来源
- [EhViewer](https://github.com/Ehviewer-Overhauled/Ehviewer) — Android 端 EhViewer
- [EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ) — Android 端中文增强版
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite 数据库工具包

## ⚠️ 免责声明

本项目仅供学习和技术交流使用。用户应遵守当地法律法规，开发者不对使用本软件产生的任何后果承担责任。

---

<p align="center">
  <sub>使用 ❤️ 和 SwiftUI 构建</sub>
</p>
