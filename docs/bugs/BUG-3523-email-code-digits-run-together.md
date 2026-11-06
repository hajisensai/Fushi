## BUG-3523 · email-code-digits-run-together
- **报告**：2026-10-18（用户：邮箱验证码「10 分钟」和前面的数字没有间隔）
- **真实性**：✅ 真 bug。`services/leaderboard/src/email.js` 的 `MESSAGES` 正文是 `验证码是：${code}\n\n10 分钟内有效`（en / ja 同构）：码与时长之间只靠换行分隔，通知栏 / 邮件列表摘要把换行吞掉后读成 `12345610 分钟内有效`。
- **[x] ① 已修复** — 码后紧跟句末标点，下一句改成不以数字开头（「有效期 10 分钟」/ 「有効期限は 10 分です」），三语一致；提交 `fix(leaderboard): email code body and code-field error`。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/auth.test.js`「邮件正文吞掉换行后验证码也不和后面的数字粘连」：三语逐个发码，去掉全部空白后断言验证码后面不是数字。
- **备注**：
