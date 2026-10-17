## BUG-3303 · 排行榜注册强制同意公开且绑定启用上传
- **报告**：2026-10-13（用户反馈 #2Ih1Fl3Nsh：注册页不勾同意公开就无法注册，而且这份同意会直接启用书架上传）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/leaderboard/leaderboard_sign_in_page.dart` 旧 `_canSubmit` 注册分支要求 `_consent`；`fushi/lib/src/leaderboard/leaderboard_service.dart` 旧 `enable()` 写死 `_adopt(identity, self, consent: true)`，同意 = 公开 + 开启本机上传绑成一件事。服务端注册本就不要求同意（`services/leaderboard/src` 无 consent 字段），是客户端把「创建账户」与「公开上传」耦合。换设备登录页早已是分离的（不勾 = 账户建好、本机上传关）。
- **[x] ① 已修复** — `bf1e268c6c`：注册页与登录页同一口径，不勾同意也能注册；`enable({consent})` 透传到 `_adopt`，不勾时 `uploadEnabled=false`、不记同意时刻，之后在账户页打开上传时再确认。注册页同意文案统一用登录页那句（含「不勾则本设备暂不上传」），删掉不再使用的 `leaderboard_signin_consent`。
- **[x] ② 已加自动化测试** — `fushi/test/leaderboard_ui/leaderboard_ui_test.dart`：注册页不勾同意提交按钮可用；「注册页：不勾同意也能注册，但本机上传默认关闭、不记同意时刻」断言落盘的 `uploadEnabled=false`、`consentAt=null`。
- **备注**：`enable()` 的 `consent` 默认 true 仅为兼容既有调用与服务层测试。
