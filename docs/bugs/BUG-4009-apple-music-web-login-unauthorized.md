## BUG-4009 · apple-music-web-login-unauthorized
- **报告**：2026-11-04（用户：应用内反馈 FK0EFFDLIS「Apple Music 登录失败」；之前点登录无反应，现报 `AUTHORIZATION_ERROR: Unauthorized`）
- **真实性**：✅ 真 bug（HiBreak 真机探针取证）。三处：
  1. 回传通道断：托管页 `services/leaderboard/src/musickit_page.js:258` 原为 `Referrer-Policy: no-referrer`，加上 Android WebView 多窗口（`window.open` → 新 WebView）本身不带 referrer，Apple 授权弹窗 sessionStorage 里没有 `ac`（opener 地址），不对 `window.opener` 建 JSON-RPC 通道——即使有订阅，token 也回不到桥页，只看到窗关了 → Unauthorized。
  2. 无订阅账号：Apple 授权页走 `/upsell`，「以后再说」只发 `close`，网页版 MusicKit 不给无订阅账号授权（Apple 侧行为），而错误文案只有 `Unauthorized`，用户看不懂。
  3. 「点了没反应」：平板 Widevine HAL 卡死时 `fushiMusicKit.init()` 无限期挂起，`apple_music_web_login_page.dart` 的 init 调用没有超时；隐藏桥 `apple_music_web_bridge.dart:298` 的 `onCreateWindow` 返回 true 却不建窗，请求悬空。
- **[x] ① 已修复** — 托管页改 `strict-origin`；登录页在弹窗进入 `authorize.music.apple.com` 时补 `ac`（`apple_music_web_login_flow.dart` `appleMusicPopupOpenerSeedJs`，只补不改）；按弹窗走过的结论页给明确原因（无订阅 / 地区 / 设备）；init 40 s 超时给 DRM 文案；弹窗再开窗（订阅页）交系统浏览器；登录轨迹（只记主机+路径）写诊断日志；隐藏桥 `onCreateWindow` 改返回 false。真机验证：补 `ac` 后点「以后再说」桥页收到 `{"jsonrpc":"2.0","method":"close"}`（修前收不到任何消息）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/apple_music/apple_music_web_login_flow_test.dart`（补 ac 脚本、结论页映射、真机无订阅路径轨迹与脱敏、失败文案）；`services/leaderboard/test/musickit_page.test.js` 断言 `Referrer-Policy: strict-origin`。
- **备注**：有订阅账号的完整 token 回传未在真机走通（手头账号无订阅），通道本身已证实可达。
