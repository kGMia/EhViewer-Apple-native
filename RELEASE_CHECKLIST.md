# EhViewer Apple 发行检查清单

## 自动检查

- 仅检查元数据：`./release_preflight.sh --metadata-only`
- 完整静态分析：`./release_preflight.sh`
- 在 Xcode 的 Archive 中分别选择 macOS 与 Any iOS Device，使用实际发行证书完成签名验证。

预检覆盖 Info.plist、PrivacyInfo.xcprivacy、三种本地化、Icon Composer、Live Activity 配置、版本一致性、上游署名、Git 冲突标记，以及 macOS/iOS Release 静态分析。

## 每次发行必须更新

- 同时递增主 App 与 Live Activity 扩展的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
- 使用真实 iPhone/iPad 检查登录、下载暂停/恢复、Live Activity 深链、横竖屏导航和后台恢复。
- 使用浅色、深色与高对比度外观检查画廊详情、阅读器和搜索结果。
- 检查中文菜单、权限说明、关于页版本号和开源协议。
- 生成 Xcode Privacy Report，确认第三方依赖的隐私清单与签名没有缺失。
- 检查 `git status`，确认构建产物、Cookie、账号资料、签名证书和测试截图没有进入提交。

## GitHub 发布

- 当前发布仓库为 `kGMia/EhViewer-Apple-native`，上游为 `felixchaos/EhViewer-Apple`。
- 本地将原项目远程命名为 `upstream`，个人仓库命名为 `origin`，日常只向 `origin` 推送。
- 创建首次发行提交前更新 README 中的克隆地址、Issues、Discussions 和支持链接。
- 推送后先确认 `Release Preflight` 工作流通过，再创建带版本号的 tag 与 GitHub Release。
- 不要把个人部署域名、Team ID、证书、描述文件或公证密码写入公开工作流；敏感值只能存放在 GitHub Actions Secrets。

## 分发与合规

- App Store Connect 中仍需填写隐私详情、年龄分级、支持网址、隐私政策网址和出口合规信息。
- 当前 App 面向可能包含成人内容的网站。提交 App Store 前必须单独评估 App Review Guidelines 1.1.4 与 1.2；技术构建通过并不代表内容审核可通过。
- macOS 已启用 App Sandbox。自定义下载目录必须始终通过系统文件选择器和 security-scoped bookmark 访问。
- 不在仓库、日志、诊断包或截图中包含 Cookie、账号信息、显式内容或个人下载路径。
