## BUG-4499 · 查词弹窗里点开的放大图跨查词残留，下次查别的词仍盖在结果上
- **报告**：2026-11-15（应用内反馈 GmLVWNpQKc，Windows，3.3.0-debug.26447）
- **真实性**：✅ 真 bug。放大图灯箱 `.dict-image-lightbox` 由 `openImageLightbox`（`fushi/assets/popup/popup.js:1552`）挂在 `__fushiOverlayParent()`（`popup.js:20`，document.body / shadow root）下，**不是** `#entries-container` 的后代；关闭只有 `closeImageLightbox`（`popup.js:1548`）一处，且只在点灯箱 / 再开一张时调用。换词重渲染 `window.renderPopup`（`popup.js:8839` 起）只清容器、关音频源菜单，新查词会话复位 `window.__fushiResetPopupScroll`（`popup.js:8023`，in-app 热槽全量推送与 app 外 / galgame 根 iframe `beginLookup` 共用）只复位滚动，二者都不碰灯箱。热槽 WebView / 常驻根 iframe 跨查词不重载，于是上一个词的放大图一直盖在下一次查词结果上。
- **[x] ① 修复** — 灯箱属于一次查词的旧 DOM：`renderPopup` 换代处（与关音频源菜单同处）与 `__fushiResetPopupScroll` 新会话复位处都调用 `closeImageLightbox()`；后者覆盖同词重查 / 缓存命中不走 `renderPopup` 的路径。popup.js 三份镜像同步。
- **[x] ② 自动化测试** — `fushi/test/pages/popup_image_lightbox_session_test.js`（Node 真执行 popup.js：开灯箱后新会话复位 / renderPopup 各自必须摘掉灯箱；撤掉任一处修复对应断言变红），由 `popup_image_lightbox_session_test.dart` 在 `flutter test` 内驱动。
- **备注**：纯 DOM 生命周期修复，未上真机肉眼复测。
