## BUG-5215 · 曲库页测试在 macOS 主机上因 Apple Music 事件通道无插件实现而红
- **报告**：2026-11-22（dist_test 在 self-mac 跑 `fushi/test/pages/music_library_page_test.dart` 时发现；同一份代码在 self-win 上重跑全绿，dist 判 `onlyOriginal`）
- **真实性**：✅ 测试环境问题（只在 macOS 主机复现）。`五个分区；专辑网格 → 歌曲 → 作品空态`、`「继续收听」只在曲库 / 推荐……` 两条报 `MissingPluginException(No implementation found for method listen on channel app.fushi.reader/apple_music/events)`：macOS 上 Apple Music 能力开着，页面订阅 `AppleMusicNativeBridge.events`，`fushi/lib/src/media/music/apple_music/apple_music_native_bridge.dart:88` 对真实 `EventChannel` 调 `receiveBroadcastStream()`，测试进程里没有原生插件 → 错误经 `onError: _out.addError` 冒成未处理异常。与 PR #4164 的改动无关（该 PR 只改了 `_continueListening` 与播放页唱片摆法）。
- **[ ] ① 未修复** — 方向：测试里给 Apple Music 桥注入假实现（或页面测试的宿主在 macOS 上关掉 Apple Music 能力），不在生产代码里吞 `MissingPluginException`。
- **[ ] ② 未加自动化测试** —
- **备注**：
