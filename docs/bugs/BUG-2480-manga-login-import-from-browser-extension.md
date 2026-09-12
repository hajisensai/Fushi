## BUG-2480 · 漫画源登录：从系统浏览器（经 Fushi 扩展）导入已登录会话，不必在 app 内重登
- **报告**：2026-09-12（用户：「能不能先从浏览器获取数据，不然我得全部重新登陆」「给一个按钮，直接让他打开浏览器登录然后再传回来」）
- **真实性**：✅ 产品缺口。直接读 Chrome/Edge 的 cookie 库走不通（127 起 app-bound 加密，普通进程解不开）；能拿到含 HttpOnly 的完整会话且不需要提权的只有浏览器扩展的 `chrome.cookies` API。
- **[x] ① 已修复** —
  - app：`fushi/lib/src/media/manga/cookie/browser_cookie_import.dart` 的 `BrowserCookieImportGate`（登记 host + 一次性 nonce；`deliver` 校验 nonce 后推给登记者；登记活到登录页关闭，扩展每次该站页面加载都会再送一次最新会话）；`yomitan_api_server.dart` 的 `/api/extension/status` 回包带 `cookieImport {host, nonce}`，新端点 `/api/extension/site-cookies`（nonce 不符 409）；`browserCookiesForSite` 与 WebView 导出同一套「只收同站点」过滤。登录页（`mihon_web_login_page.dart`）加「从浏览器导入」按钮：登记 → `launchUrl` 在系统浏览器打开源站 → 收到即写 jar 并显示条数 → 「完成」直接关页。只在桌面 sidecar（jar 非空）提供。
  - 扩展：`tools/browser-extension/site-cookie-export.js`（纯函数）+ `background.js` 桥（tab 加载完成 / 每分钟心跳看到登记且该站有打开的标签页才送，避免把陈旧会话当已导入）；manifest 加 `cookies` 权限。镜像已 `sync-mirrors.mjs` 同步。
- **[x] ② 已加自动化测试** — `fushi/test/sync/yomitan_api_server_site_cookies_test.dart`（真实 HTTP：status 带登记、nonce 对/错/结束、字段解析、同站点过滤）、`fushi/test/media/manga/mihon_web_login_page_test.dart`（按钮 → 登记 + 打开浏览器 → 送达写 jar → 完成关页；Android 无按钮）、`tools/browser-extension/site-cookie-export.test.js`（node）。
- **备注**：扩展是本地解压加载的，加 `cookies` 权限随自更新 reload 即生效，无需商店式二次确认。Android 不提供：扩展连不上手机。
