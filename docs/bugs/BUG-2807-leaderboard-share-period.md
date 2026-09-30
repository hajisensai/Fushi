## BUG-2807 · 排行榜分享只能分享本月且无法只分享链接
- **报告**：2026-09-30（用户：统计中心 › 排行 › 分享，弹窗写死「分享本月」，选了「周」也只能分享本月；且希望能直接用链接分享）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/leaderboard/leaderboard_share_card.dart` 的 `loadLeaderboardShareCardData` 把周期硬编码成本月（本地时区月初 + `LeaderboardWindow.month` 字数榜），卡片文案也只有「本月读完」；`showLeaderboardShareSheet` 不接收排行页当前选中的周期。对话框唯一的出口是「图片 + 主页链接」系统分享面板，没有不带图片的链接入口。另：月初按本地时区算，而服务端周期按 UTC 日期起算（`services/leaderboard/src/snapshots.js` `windowStartKey`），跨时区边界时读完数与字数榜口径不一致。
- **[x] ① 已修复** — 分享周期改成与榜单同一套周 / 月 / 总：`leaderboardShareWindowStart` 按 UTC 日期对齐服务端（周 = 本周一、月 = 1 日）；周 / 月数书架并取同周期字数榜 `me`，「总」取用户卡累计（不受 200 部翻页上限影响）；对话框加周期切换（默认跟随排行页当前周期、按周期缓存）、「复制链接」按钮（`/u/<id>` 主页链接，不依赖卡片加载）；取数用服务注入时钟 `LeaderboardService.nowMs()`。
- **[x] ② 已加自动化测试** — `fushi/test/leaderboard_ui/leaderboard_ui_test.dart`：周期起点 UTC 口径、周 / 总取数、对话框默认周期 → 切「总」→ 复制链接写剪贴板。
- **备注**：链接仍是用户主页 `/u/<id>`，服务端只读网页不按周期展示；如需带周期的分享页要改 `services/leaderboard/src/pages.js`。
