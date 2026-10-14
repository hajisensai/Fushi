## BUG-3336 · 浏览器扩展查词后滚动页面，高亮与弹窗停在原位
- **报告**：2026-10-13（应用内反馈 rKiz-e3gSk）
- **真实性**：✅ 真 bug。被查词高亮（`fushiDrawHighlightOverlay`，`tools/browser-extension/content.js` 覆盖层的色块）与弹窗宿主（`#hibiki-popup-host`）都是 `position:fixed` 的视口坐标，落点只在查词当帧（`fushiRender` → `place()` → `fushiApplyPlacement`）与弹窗尺寸变化（ResizeObserver）时算；content.js 全文没有任何 `scroll` 监听，页面或内部可滚动容器一滚，词走了，高亮与弹窗留在旧的视口位置。
- **[x] ① 已修复** — `content.js` 新增 `fushiOnPageScroll` / `fushiFollowLookupAnchor` / `fushiShiftPopupBy`：document 上 `capture + passive` 监听 `scroll`（内部容器的 scroll 不冒泡，只有 capture 收得到；弹窗 shadow 内的滚动不 composed，不会误触），每帧最多复算一次，从同一份取词 ranges 重量 rects：词仍在视口内 → 高亮重画、弹窗按词的位移整体平移（尺寸 / 选边 / 手动拖出的尺寸都不动，拖拽夹取上下文同步平移）；词整个滚出视口 → `fushiRemoveContainer()` 关窗（高亮随之撤）；量不到 rects（宿主页重渲染换掉了文本节点）→ 撤掉会错位的高亮，弹窗留原处。只跟随从宿主页选区量到 rects 的那一窗（侧栏权威锚点 / 鼠标兜底不动）。镜像 `fushi/assets/browser_extension/content.js` 经 `scripts/sync-mirrors.mjs` 同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/scroll-follow.test.js`（vm 真加载 content.js：capture+passive 注册、内部容器滚动后高亮与弹窗跟随、词滚出视口关窗撤高亮、无弹窗不排 rAF）。去掉监听注册后 4 条中 3 条红（变异实测）。
- **备注**：嵌套查词的子弹窗（iframe）不随根弹窗平移；根弹窗因词滚出视口关闭时子栈一并清掉。
