## BUG-1809 · iOS歌词loadData返回后不触发onLoadStop导致永不ready
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机，从有声书快速设置进入歌词模式）
- **真实性**：✅ 真 bug。阶段探针证明状态持久化、歌词 profile、5 cues / 78KB HTML 生成与 `loadData` 均返回，但 iOS 没有歌词 onLoadStop/ready。继续追到 `webview.part.dart:2505-2519`：iOS 会把 `loadData(baseUrl: https://fushi.local/lyrics)` 交给 `shouldOverrideUrlLoading`，而现有代码只放行 `_isNavigatingToChapter`，歌词主文档没有该旗，遂被当普通链接 `CANCEL`。所以旧正文仍留在 WebView，HTML 内 ready bridge 也没有机会执行。既有 BUG-649 只过滤旧正文 onLoadStop，没有给歌词主文档导航放行。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED：物理机歌词入口连续多轮均在 60 秒 ready 超时，阶段日志最后停在 `loadData returned`；`fushi/test/media/audiobook/lyrics_mode_html_caret_test.dart` 新增生成 HTML 契约，要求 DOM API 建好后通过 `onLyricsReady` 主动通知 Dart，修前 handler 不存在、修后 1/1 GREEN。
- **备注**：`_lyricsDocumentLoadInFlight` 只在歌词主文档 loadData 窗口放行 shouldOverride，sentinel finalize/主帧错误/退出歌词时清除，不放开后续普通链接。LyricsModeHtml 在 sentinel API 建好后以最多 5 秒的条件轮询等待 JS bridge；Dart `onLyricsReady` 与原 onLoadStop 共用幂等 finalize，避免双回调重复初始化。
