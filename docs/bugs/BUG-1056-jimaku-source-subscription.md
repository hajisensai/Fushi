## BUG-1056 · 字幕来源不可选且连载订阅无法绑定合集字幕
- **报告**：2026-07-24（用户：合集字幕界面没有可选字幕；部分字幕按整季合集发布，不知道如何选）
- **真实性**：✅ 真 bug/功能缺口。修前番剧下载在 Jimaku 返回多个条目时固定取 `entries.first`；合集批量流程把多个 entry id 静默交给匹配器，UI 只显示逐集占位行。`AnimeDownloadSubscription` 又只保存番剧/发布组/分辨率，无法表达“视频版本 + 指定 Jimaku 字幕条目/语言”的组合。
- **[x] ① 已修复** — `anime_download_dialog.dart:381/1175` 与 `jimaku_batch_dialog.dart:405` 显式列出 Jimaku 条目并允许选一个来源与语言；整季合集被视为一个来源，在该条目内部按集号匹配。`anime_download_subscription.dart:37-103/413` 持久化条目 id、名称、语言，并在每轮新集入队前从该条目获取对应字幕；未到字幕时保留该集 pending，避免视频先入库后永远漏字幕。订阅页同时展示已绑定字幕组合。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/jimaku_entry_picker_test.dart` 覆盖来源与语言交互；`hibiki/test/torrent/anime_download_subscription_test.dart` 覆盖组合身份、JSON 兼容、字幕暂存与缺字幕保持 pending；`hibiki/test/pages/download_subscriptions_panel_test.dart` 覆盖窄屏/桌面展示无溢出。
- **备注**：确认页对来源区设置滚动高度上限，条目多时不会挤掉下载/订阅按钮。未在用户当前真实 Jimaku 合集上完成 GUI 肉眼复测，PR 保持 draft。
