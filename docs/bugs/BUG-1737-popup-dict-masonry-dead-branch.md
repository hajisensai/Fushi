## BUG-1737 · 查词弹窗词典方框在支持原生masonry的WebKit上塌成行对齐grid
- **报告**：2026-08-19（用户：macOS 26.6.1，截图为证——词典卡之间出现大片纵向空洞）
- **真实性**：✅ 真 bug（**特性检测通向一条从未实现的分支**）。根因：
  - `fushi/assets/popup/popup.js:3705-3707`（修前）
    `const HAS_NATIVE_MASONRY = CSS.supports('display', 'grid-lanes')`；
  - `fushi/assets/popup/popup.js:3759`（修前）
    `function layoutMasonry() { if (HAS_NATIVE_MASONRY) return; // 交给 CSS（未来分支）`
  - **但 CSS 侧那条「未来分支」从未写过**：全仓 grep `grid-lanes` / `item-flow` /
    `grid-template-rows: masonry` **只命中这行检测本身**，`popup.css` 一行实现都没有。
  - `grid-lanes` 是 CSSWG 给 masonry 的新值，2026-08 的 WebKit（macOS 26 / Safari 26）
    开始支持 → 检测转 true → JS masonry 整体放弃 → 布局退回
    `popup.css:1178-1197` 的 `.glossary-section > .category-body`
    **行对齐 grid**（`grid-template-columns: repeat(N, minmax(0,1fr))` + `align-items:start`）。
  - 后果：同一"行"的词典卡按最高的那张占位，已折叠 / 义项少的矮卡（如「大辞泉 第二版」
    「NHK日本語発音アクセント新辞典」）下方留出大片空玻璃盒，下一张卡被推到很下面才开始。
    CSS 的 `align-items:start` 只解决了「卡片被拉伸等高」，**解决不了「行内空洞」**——
    紧密堆本来就只有 JS masonry（`layoutMasonry`，按最短列打包）能做。
  - 平台归属：WebKit 家族（macOS / iOS 的 WKWebView）先支持先发作；Chromium/Android
    与 Windows WebView2 尚未支持 `grid-lanes`，检测为 false，故只在 Apple 端可见。
- **[x] ① 已修复** — 删掉 `HAS_NATIVE_MASONRY` 常量与 `layoutMasonry()` 开头那条提前
  返回，两份镜像同步（`fushi/assets/popup/popup.js` + `tools/browser-extension/vendor/popup.js`）。
  在 CSS 原生分支真正落地之前，masonry 一律由 JS 铺。原则：**特性检测只有在对应实现
  确实存在时才允许提前返回**，否则它只是一条定时炸弹——浏览器哪天支持了，功能哪天就坏。
- **[x] ② 已加自动化测试** — 新增
  `fushi/test/pages/popup_masonry_no_dead_branch_guard_test.dart`，对两份镜像各断言：
  ① `layoutMasonry` 体内不得出现 `HAS_NATIVE_MASONRY`（不得按原生支持度整体放弃）；
  ② 更一般的不变式——JS **代码**里只要检测了某个原生 masonry 特性名
  （`grid-lanes` / `item-flow` / `grid-template-rows: masonry`），同目录 CSS 就必须真的
  用上它。匹配前先剥掉整行 `//` 注释，否则解释本 bug 的注释本身会误触发守卫。
- **备注**：未做真机验收（用户侧仍在使用旧构建）。修复只影响「JS masonry 是否运行」，
  CSS grid 规则原样保留作无-JS 兜底，故现有 grid 守卫测试不受影响。
