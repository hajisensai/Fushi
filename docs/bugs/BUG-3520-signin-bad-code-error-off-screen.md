## BUG-3520 · signin-bad-code-error-off-screen
- **报告**：2026-10-18（用户：验证码不对没有提醒）
- **真实性**：✅ 真 bug（展示位置问题）。服务端 `consumeCode` 正确回 400 `bad_code`，客户端也映射成「验证码不对。」，但 `fushi/lib/src/pages/implementations/leaderboard/leaderboard_sign_in_page.dart` 把它放进页面底部唯一的 `_error` 行——在公开数据清单与同意勾选之后、离验证码框很远，手机上处于屏幕外，用户看不到。
- **[x] ① 已修复** — `bad_code` / `code_expired` / `too_many_attempts`（`kLeaderboardCodeErrorCodes`）改挂到验证码输入框的 `errorText`，验证码一改即清；其余错误仍走底部行。提交 `fix(leaderboard): email code body and code-field error`。
- **[x] ② 已加自动化测试** — `fushi/test/leaderboard_ui/leaderboard_ui_test.dart`「注册流程：发码失败、验证码错、邮箱已注册都就地显示人话」：断言 `bad_code` / `code_expired` 文案出现在验证码框内、底部错误行不出现、改验证码后消失。
- **备注**：开发者网页 `/dev` 登录页（`devconsole.js`）错误本就渲染在表单内，不受影响。
