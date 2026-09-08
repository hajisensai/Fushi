## BUG-2272 · 公网图片及原生网络链路未继承应用代理
- **报告**：2026-09-08（用户：漫画搜索全部来源失败，要求检查所有同类出站）
- **真实性**：✅ 真 bug。原桌面 Mihon Java 启动未装配应用代理，Android OkHttp / Aidoku / libmpv 同样未消费应用模式；20 个图片入口使用框架裸网络。实测本机 MangaDex 直连超时、经系统 HTTP 代理返回 pong。
- **[x] ① 根因修复** — Mihon 逐 URL 鉴权策略回调；原生播放器与 Aidoku 鉴权回环 HTTP/CONNECT 转发；图片统一 `app_http_image.dart:24` / `:120` 并保留磁盘缓存；公网 WebDAV 接工厂（`webdav_ops.dart:107`）；主/词典入口等待网络装配（`app_model.dart:2571` / `:2931`）；手动凭据读取与既有 client 的后填认证在请求时生效（`app_proxy.dart:414`）。均在本修复提交。
- **[x] ② 自动化测试** — `app_proxy_local_bypass_test.dart`、`webdav_proxy_test.dart`、`app_network_bindings_test.dart`、`app_http_image_proxy_test.dart`、`network_image_proxy_guard_test.dart`、`app_native_proxy_test.dart`、`mihon_proxy_policy_server_test.dart`、`android_mihon_proxy_policy_test.dart` 及 JVM `HostProxyPolicyTest`。本地 socket/代理验证真实 HTTP 与 CONNECT；实际安装包 libmpv 成功加载代理后的测试 WAV。
- **备注**：局域网与配对端 TLS 保持原边界，BT 保留独立 P2P 开关。Mihon 禁止旧连接跨策略复用，代价是额外握手；Android Release 缺本地签名配置，Apple 原生打包及用户原始漫画 UI 路径未验收。源码修复不等于已更新用户安装包。完整架构与边界见 `fushi/lib/src/utils/net/DESIGN.md`。
- **后续覆盖**：Cloudflare 交互验证浏览器的代理隔离单独由 BUG-2275 处理。Android `compileDebugKotlin` 已通过，完整 APK/Apple 包未构建；libmpv 验证为 HTTP 音频加载，HTTPS 播放仅验证到 CONNECT 真 socket 通道。
