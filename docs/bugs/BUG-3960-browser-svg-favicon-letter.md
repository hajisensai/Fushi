## BUG-3960 · 浏览器标签页图标退回首字母（站点声明 SVG favicon）
- **报告**：2026-11-01（用户：截图「没有 icon」，jiten.moe 标签只有首字母色块）
- **真实性**：✅ 真 bug。jiten.moe `<head>` 同时声明 `favicon.svg`（`sizes="any"`）、96px png、48px ico；`fushi/lib/src/web_browser/tab_view/web_browser_page_scripts.dart` `kWebBrowserFaviconScript` 按「声明尺寸接近 32」打分，`sizes="any"` 记默认 16 分，与 48px ico 同分且先出现，选中了 SVG。`WebBrowserFavicon` 用 Flutter `Image`（`AppHttpImage`）解码，不认 SVG → errorBuilder 退回首字母色块。
- **[x] ① 已修复** — 脚本跳过 SVG 候选（`type` 含 svg / href 以 `.svg(z)` 结尾 / `data:image/svg`），在位图里挑；全是 SVG 时退到 `/favicon.ico`。
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/tab_view/web_browser_favicon_script_test.dart`：node 真跑脚本，喂 jiten.moe 的 link 组合断言选 ico、喂只有 SVG 的组合断言退 `/favicon.ico`（无 node 时 skip）。
- **备注**：Windows 真机肉眼复测待补。
