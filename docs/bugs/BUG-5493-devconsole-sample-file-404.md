## BUG-5493 · 网页处理台样本文件下载 404
- **报告**：2026-11-26（加 triage 角色时顺带发现）
- **真实性**：✅ 真 bug。详情页给样本文件（f0..f2）生成 `/dev/f/:id/a/f0` 下载 / 查看文本链接，但路由正则只收 `log|s[0-2]|v0`（`services/leaderboard/src/devconsole.js` 附件路由），点了落到末尾 404。App 端签名接口 `/v1/dev/feedback/:id/attachments/f0` 正常，只有网页坏。
- **[x] ① 已修复** — 路由正则补上 `f[0-2]`（与 `attachmentResponse` 支持的槽位一致）。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/feedback_triage.test.js`「BUG-5493 网页处理台样本文件」：上传 f0 后经网页会话下载（octet-stream + attachment）与 `?view=text`。
- **备注**：
