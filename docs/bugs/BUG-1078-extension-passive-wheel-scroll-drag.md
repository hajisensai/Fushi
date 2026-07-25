## BUG-1078 · 扩展在所有网页常驻非passive wheel监听拖慢浏览器滚动
- **报告**：2026-07-25（用户：）
- **真实性**：✅ 真 bug。popup.js 作为 content script 注入 `<all_urls>`，顶层无条件
  `document.addEventListener('wheel', …, { passive: false })`（修复前
  `tools/browser-extension/vendor/popup.js:4042`，监听体到 `:4139`；三镜像同源，唯一一个
  wheel 监听——此前调查说的「:4042 和 :4139 两处」实为同一监听的首尾行）。非 passive wheel
  监听一旦存在，浏览器就放弃合成器快速滚动路径，宿主页每次滚轮都要同步等主线程跑完监听。
  更糟的是监听内部顺序反了：昂贵的祖先遍历 `popupAncestorAbsorbsVerticalWheel`
  （`:3989`，对事件目标每个祖先做 `getComputedStyle` + `scrollHeight/clientHeight` 强制布局读）
  在 `:4073` 先执行，而真正廉价决定性的早退
  `if (!scroller && inExtensionContentScript) return;`（`:4082`）排在它后面——弹窗根本不在场
  时宿主页每次滚轮都白跑整条昂贵路径；且每次 wheel 至少调 2 次 `e.composedPath()`
  （`__hibikiEventTarget` :10 + `__hibikiWheelScroller` :23，各自分配新数组）。
- **[x] ① 已修复** — 提交 `c931d8f98`。三层根因修复（`popup.js` 三镜像 + `content.js` 两镜像同步）：
  1. **懒装监听（扩展上下文）**：popup.js 在扩展上下文（`chrome.runtime.id` 存在）不再挂
     document，把监听暴露为 `window.__hibikiPopupWheelListener`；content.js 在弹窗 shadow host
     创建时（`hibikiEnsureContainer`，host 复用路径不重复挂）以 `{passive:false}` 挂到 host 上、
     `hibikiRemoveContainer` 销毁时卸载。弹窗不在场 ⇒ 宿主页 document 上零 wheel 监听，
     合成器快速滚动路径完整保留。in-app 弹窗 WebView（无 chrome.runtime，document 即弹窗）
     保持常驻 document 监听不变——BUG-1026 滚轮速度、BUG-1065 DPR、PR#395 Alt+滚轮词条
     导航行为全部不动。
  2. **早退前置（纵深防御）**：监听体最顶部先用一次 `composedPath + indexOf` 解析滚轮表面，
     `!scroller && inExtensionContentScript` 立即放行原生滚动；昂贵的祖先遍历和词条导航判定
     只在滚轮确认落在弹窗内（或 in-app）时才执行。原 BUG-732 守卫字面量保留在新位置。
  3. **composedPath 单次复用**：新增 `__hibikiComposedPath(e)` 把路径缓存在事件对象上，
     `__hibikiEventTarget` / `__hibikiWheelScroller` 共享同一次 `composedPath()` 结果。
- **[x] ② 已加自动化测试** —
  - `tools/browser-extension/popup-wheel-lazy.test.js`（node:test，真加载 popup.js + content.js）：
    ①扩展上下文加载后 document 零 wheel 监听且监听已全局暴露；②`hibikiEnsureContainer` 挂
    `{passive:false}` 到 host 且复用不重复挂；③弹窗内滚轮行为不变（preventDefault + 滚 host、
    不碰 window）；④`hibikiRemoveContainer` 卸载监听。
  - `hibiki/test/lookup/browser_extension_page_scroll_bug732_test.js`（更新，由同名 `.dart` 在
    `flutter test` 里驱动）：新增断言扩展上下文 document 无任何 wheel 注册、in-app 恰好一个
    常驻 `{passive:false}` document 监听；原 BUG-732 四表面行为断言（扩展宿主页放行原生 /
    弹窗内接管 / in-app 接管）全部保留。
  - 相邻守卫回归绿：`hibiki/test/build/browser_extension_popup_wheel_surface_guard_test.dart`、
    `hibiki/test/reader/popup_wheel_scroll_asset_test.dart`、
    `hibiki/test/reader/popup_wheel_scroll_behavior_test.dart`（+`.js`）、
    `hibiki/test/reader/popup_wheel_speed_asset_test.dart`、
    `hibiki/test/shortcuts/popup_entry_wheel_binding_test.dart`。
- **备注**：改动文件——`tools/browser-extension/vendor/popup.js` /
  `hibiki/assets/popup/popup.js` / `hibiki/assets/browser_extension/vendor/popup.js`（三镜像逐字节
  一致）、`tools/browser-extension/content.js` / `hibiki/assets/browser_extension/content.js`
  （两镜像逐字节一致）。content.js 的 Shift 悬停 / 定时器 / CSS 注入未动（不在本 bug 范围）。
