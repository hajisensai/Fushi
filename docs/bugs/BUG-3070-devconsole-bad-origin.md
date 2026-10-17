## BUG-3070 · 反馈处理台网页登录一律 403 bad_origin
- **报告**：2026-10-08（用户：在 rank.fushi.moe/dev 提交邮箱后页面只剩 `{"error":"bad_origin"}`）
- **真实性**：✅ 真 bug。`services/leaderboard/src/devconsole.js` 的 `html()` 给处理台页面发 `Referrer-Policy: no-referrer`；按 Fetch 规范，该策略下页面自己的表单 POST 一律带 `Origin: null`（同站也是），而 `checkOrigin`（同文件）要求 Origin 严格等于本站，于是浏览器里的发码 / 登录 / 处理 / 退出全部 403。线上 curl 复现：`Origin: https://rank.fushi.moe` → 200，`Origin: null` → 403。测试只伪造了正确的 Origin，所以没抓到。
- **[x] ① 已修复** — `c281267497`：策略改为 `same-origin`（外链仍不带 referrer，同站 POST 带真实 Origin，CSRF 判据不变），并在 `checkOrigin` / `html()` 处注明两者的耦合。已部署（Worker 版本 `5dac156c`），线上响应头为 `Referrer-Policy: same-origin`。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/feedback.test.js`「网页处理台」用例断言 `/dev` 的 `Referrer-Policy` 为 `same-origin` 且页面无 `<meta name="referrer">`；变异实测：改回 `no-referrer` 该用例红。
- **备注**：BUG 由 9f47a35d（反馈功能）引入，上线当天发现。
