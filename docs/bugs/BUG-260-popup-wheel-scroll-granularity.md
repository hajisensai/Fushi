## BUG-260 · 查词弹窗滚轮滚动粒度太粗

- **报告**：2026-06-14（用户：）
- **真实性**：✅ 真 bug。根因有两层：
  1. `hibiki/assets/popup/popup.js` 全文从无 `wheel` 监听 → 弹窗滚轮落 WebView 原生整页式滚动，每格步长固定且很粗，不像普通网页那样平滑细滚。
  2. `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:495` 给 `document.documentElement.style.zoom` 注入 `popupContentZoom`（跟随界面大小 + 词典字号）。CSS `zoom` 下，滚动 D 个 *布局* px 视觉移动 D×zoom px → zoom>1 时把本就粗的原生步长再放大，每格跳得更远。
  （注：阅读器 `reader_hibiki_page.dart:2221` 的 wheel 是整页翻页，弹窗是独立 WebView，未改动；已有的 `popupInstantScroll` 只影响 caret 滚动非鼠标滚轮。）
- **[x] ① 已修复** — `hibiki/assets/popup/popup.js:2189-2271` 新增自定义 `wheel` 监听（`passive:false` + `preventDefault` 压掉原生粗步长）：`popupWheelDeltaToPixels` 归一 `deltaMode`（LINE×16 / PAGE×innerHeight / PIXEL 原值）→ 乘 `POPUP_WHEEL_PIXEL_FACTOR=0.35` 做更细每格 → 除以 `popupCurrentZoom()`（读 `documentElement.style.zoom`）抵消 zoom 视觉放大使步长 zoom-无关 → `window.scrollBy({top,behavior:'auto'})`。`popupAncestorAbsorbsVerticalWheel` 把内部可竖滚容器（描述遮罩 / 义项 y-overflow）在未到边界前留给原生，只精修主文档滚动；ctrl+滚轮缩放手势与纯横向滚动放行。提交：0a44e85a9
- **[x] ② 已加自动化测试** — `hibiki/test/reader/popup_wheel_scroll_asset_test.dart`（源码守卫，rootBundle 读 popup.js 资产）：断言非 passive wheel 监听 + preventDefault、`window.scrollBy` + `POPUP_WHEEL_PIXEL_FACTOR` 细步长、deltaMode 归一、除 `popupCurrentZoom()` 抵消 zoom、保留内部竖滚容器、放行 ctrl/横向。提交：0a44e85a9
- **备注**：真机滚动手感（系数 0.35 是否合适、不同鼠标/触控板 deltaMode 差异）待设备验证。
