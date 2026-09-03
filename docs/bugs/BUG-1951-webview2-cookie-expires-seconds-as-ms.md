## BUG-1951 · WebView2 fork getCookies 把 CDP 的秒级 expires 当毫秒回给 Dart：环境间复制 cookie 一律 1970 过期被丢弃、cf_clearance 落库即判过期
- **报告**：2026-08-30（内置网页播放器 4K 窗口宿主档真机验证时发现：把内置档已登录的 Netflix cookie 复制到 4K 环境后，
  站点仍停在未登录的 title 页；`error_log` 零报错——复制「成功」但 cookie 根本没存进去）
- **真实性**：✅ 真 bug。根因 `packages/flutter_inappwebview_windows/windows/cookie_manager.cpp:189` / `:237`
  （`getCookie` / `getCookies`）：CDP `Network.getCookies` 的 `expires` 是**秒**（浮点，会话 cookie 为 -1），代码
  `jsonCookie["expires"].get<int64_t>()` 原样回给 Dart 的 `expiresDate`；而 platform-interface `Cookie.expiresDate`
  是**毫秒**，同文件 `setCookie`（`:131`）也按毫秒收、`/ 1000` 后喂 CDP。于是 getCookies → setCookie 往返把
  `1.79e9 s` 变成 `1.79e6 s` = 1970 年 → Chromium 当场丢弃。两个消费方受害：
  - 网页播放器 `_copyLoginCookiesFromBuiltin`（4K 档登录态复制）静默失效；
  - 漫画 Cloudflare 过盾页 `aidoku_cloudflare_challenge_page.dart:216` 把它存成 `AidokuCookie.expiresAt`
    （doc 明说「毫秒时间戳」，`isExpiredAt(nowMs)` 按毫秒比）→ cf_clearance 落库即判过期。
- **[x] ① 已修复** — `cookie_manager.cpp` 新增 `cookieExpiresDateMs`：`expires` 非数 / 负数（会话）回 null，否则
  `expires * 1000` 取整回毫秒；`getCookie` / `getCookies` 两处改用。页面侧复制时会话 cookie 不带 expires。
- **[x] ② 已加自动化测试** — `fushi/test/build/webview2_cookie_expires_units_guard_test.dart`：源码守卫——
  fork `cookie_manager.cpp` 的 getCookies/getCookie 不得再出现 `jsonCookie["expires"].get<int64_t>()` 直出，且
  `expiresDate` 必须经 `cookieExpiresDateMs`；`setCookie` 的 `/ 1000` 与之成对（两侧单位契约）。
  真机：windowed itest（`FUSHI_WEB_VIDEO_HOSTING=windowed`）复制后 Netflix 直接进 `/watch/` 起播。
- **备注**：fork 无 C++ 单测基建，行为面由 itest 兜底；纯 Dart 守卫只锁「单位换算存在」。
