## BUG-3200 · 反馈人在自己的反馈详情里看不到提交的截图和日志
- **报告**：2026-10-09（用户：「我的反馈」详情里看不到自己提交的截图和日志）
- **真实性**：✅ 真 bug，服务端与 App 两侧都缺：
  - 服务端 `services/leaderboard/src/feedback.js:563`（改前）：附件路径 `/v1/feedback/:id/attachments/:slot` 只接 `PUT`（补传），没有凭 ticket 取回的 `GET`；反馈人详情 `reporterView` 虽然回了附件清单（slot / kind / 大小），字节拿不到。只有开发者路由 `/v1/dev/feedback/:id/attachments/:slot` 能下载。
  - App `fushi/lib/src/pages/implementations/feedback/feedback_detail_page.dart:181`（改前）：详情只渲染一行「N 个附件」的计数文字，没有缩略图、没有日志条目，客户端也没有反馈人取附件的方法。
- **[x] ① 已修复** —
  - 服务端：新增 `GET /v1/feedback/:id/attachments/:slot`（`reporterAttachmentResponse`）。安全边界：先过 `feedbackForTicket`（只认本条的 ticket，库里比对 SHA-256，ticket 错 / 无 ticket / 别的 id 一律 404 不区分）；**只给截图槽位 s0..s2**，日志与空槽位同样 404（压缩日志只给开发者）；单条反馈每小时最多 60 次下载（`reporterDownloadsPerFeedbackHour`）；响应 `Cache-Control: private, no-store`、`X-Content-Type-Options: nosniff`、`Content-Security-Policy: default-src 'none'`，Content-Type 取上传时按魔数嗅出的图片类型。上传侧原有的约束（提交后 24 小时内、每槽一次、单张 1.5 MiB、按魔数与宽高验真图片、结案 90 天清除）不变，所以 ticket 拿不来当网盘。**需要重新部署 Worker 才生效。**
  - App：`LeaderboardClient.feedbackScreenshot` + `FeedbackService.screenshot`（凭本机 ticket）；详情页新增「截图」区（96×128 缩略图，点开 `InteractiveViewer` 大图，缩略图与大图共用一次下载）和日志条目（压缩后大小 + 「日志只有开发者能打开」）。
- **[x] ② 已加自动化测试** — 服务端 `services/leaderboard/test/feedback.test.js`「反馈人取回自己的截图」：本条 ticket 取到 PNG 且带三个安全头；日志 / 空槽 / 越界槽 404；别人的 ticket、无 ticket、别的 id 404；第 61 次 429、下一小时恢复。App `fushi/test/feedback/feedback_pages_test.dart`「BUG-3200 反馈人详情」：凭 ticket 取回并显示缩略图、点开大图、日志条目在且不去下载日志、两处共用一次请求。
- **备注**：Worker 未部署；部署前 App 新版本的详情页缩略图会显示裂图图标（GET 回 404）。
