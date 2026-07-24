## BUG-1054 · 下载发现未读取环境与系统代理导致搜索超时
- **报告**：2026-07-24（用户：下载页搜索 `Watashi wo Tabetai, Hitodenashi` 显示“搜索失败或超时”）
- **真实性**：✅ 真 bug。修前 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:184/258/336` 的 AniList、Nyaa、Jimaku 均直接构造裸 `http.Client`；自动订阅与单集/合集字幕也各自直连。Dart 客户端不会自动继承 Windows GUI 代理，故命令行经 `127.0.0.1:34151` 可访问而 app 请求超时。更新器已有 `applyUpdateProxy` 的 `env > 已启用系统代理 > DIRECT` 能力，但下载链路未复用。
- **[x] ① 已修复** — 新增 `download_network_proxy.dart:42` 的统一客户端工厂和“自动 / 直连 / 自定义”三态；AppModel 将同一策略注入 AniList、Nyaa、Jimaku、单集/合集字幕及自动订阅。自动模式复用更新器的平台解析器；更新设置补充自动读取说明。种子载荷仍由 qB/内置引擎管理，不受发现代理影响。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/download_network_proxy_test.dart` 覆盖模式解码、DIRECT、自定义代理归一及非法配置拒绝；既有 `hibiki/test/utils/misc/update_checker_proxy_test.dart` 覆盖 Windows/macOS/Linux 系统代理解析。
- **备注**：本机 Windows 注册表 `ProxyEnable=0`，因此“自动”按约定回退直连；要使用仍在监听但未启用为系统代理的端口，应在下载设置选“自定义”并填 `127.0.0.1:34151`。未在用户当前 Windows GUI 构建中走完真实三源请求，PR 保持 draft。
