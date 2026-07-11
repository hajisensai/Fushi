## BUG-731 · 扩展影响普通网页滚动速度
- **报告**：2026-07-11（用户）
- **真实性**：✅ 真 bug。根因 `hibiki/assets/browser_extension/vendor/popup.js`（wheel 监听，本仓约 `popup.js:3639` 起）。
  - 扩展 `manifest.json` 把 `vendor/popup.js` 作为 content script 注入到 `<all_urls>`（每个网页）。
  - popup.js 的 `document.addEventListener('wheel', …, { passive: false })` 是为**查词弹窗**定制的缩放平滑滚动：`e.preventDefault()` 后用 `POPUP_WHEEL_PIXEL_FACTOR = 0.24` 缩放并自行 `scrollBy`。
  - 该弹窗在扩展里是宿主页上的 shadow DOM 覆盖层。`__hibikiWheelScroller(e)` 只有滚轮 `composedPath` 穿过弹窗 shadow 才返回 host；否则返回 null，旧代码 fallthrough 到 `else { window.scrollBy(...) }`，把**整个普通网页**的滚动接管并降速到 24% 速度。shadow host 是懒创建的（`content.js` 弹窗显示时才建、关闭置 `window.__hibikiRoot = null`），所以宿主页大部分时间都被这条 null 分支接管。
- **[x] ① 已修复** — `commit b4e9ec9cb`。在 `e.preventDefault()` 之前加放行守卫：扩展 content-script 上下文（`typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id`）里，滚轮不在弹窗 shadow 内（`!scroller`）时直接 `return`，回落原生滚动。in-app 弹窗（有 `flutter_inappwebview`、无 `chrome`）与「滚轮就在弹窗内」两条路径的缩放滚动保持不变。三镜像（`assets/popup/popup.js` + 两份扩展 `vendor/popup.js`）逐字节同步（TODO-1267）。
- **[x] ② 已加自动化测试** — `test/lookup/browser_extension_page_scroll_bug731_test.js`（Node 真执行 popup.js 的 wheel 监听：扩展宿主页不 preventDefault/不 window.scrollBy；扩展弹窗内滚 host；in-app 弹窗仍 window.scrollBy）+ `test/lookup/browser_extension_page_scroll_bug731_test.dart`（node 驱动 + 源码守卫 + 三镜像字节一致）。移除守卫行后 Case A 变红，已本地验证。
- **备注**：BUG 号取 731 而非工具自动分配的 730——730 已被未合的剪贴板制卡 PR#36 占用，origin/develop 尚未含它导致工具误判空号。
