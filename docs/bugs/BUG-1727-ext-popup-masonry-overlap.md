## BUG-1727 · 扩展弹窗渲染中间态多卡片重叠
- **报告**：2026-08-19（用户：弹窗渲染过程中多张词典卡片叠在一起，渲染完才恢复正常）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.js:3466-3484`（`appendNextDeferredGlossaryBlock`，修复前行号；vendor 双镜像同）：masonry 首轮（popup.js:3863 短路条件 `configured<=1 || items.length===0` 不拦 1 张卡）把 `.category-body` 设 `position:relative; display:block`、既有卡片 absolute、body 高度钉死（:3873-3910）；此后逐宏任务 append 的新词典卡是静态流内元素——不触发 masonry、不被 ResizeObserver observe——从 body 顶部流布局压在 absolute 卡片上，直到全部建完 `_firePopupRendered()` 才统一重排。复现条件：`--dict-columns>=2` 且词典数 >=2。
- **[x] ① 已修复** — commit 144ee0bc13。popup.js 两处（三镜像同步）：
  - `appendNextDeferredGlossaryBlock`：body 已处 masonry 态（`dataset.masonryCols` 存在）时，新卡片 append 前先打 `visibility:hidden; position:absolute; left:0; top:0`（不进流、不可见）；append 后调 `scheduleMasonry()`（masonryRaf 已合帧去重）——每追加一块下一帧就落位，不再等全部建完。
  - `layoutMasonry` 定位每张卡片时清 `visibility`（恢复可见）；`resetMasonryBody` 回落 CSS 流布局时同样清掉，不留死藏卡。中间帧彻底消失。
- **[x] ② 已加自动化测试** — `fushi/test/reader/popup_dict_masonry_guard_test.dart` 新增用例「BUG-1727 增量追加词典块不产生重叠中间帧」：锁 `appendNextDeferredGlossaryBlock` 内 masonry 态门控 + visibility 预藏 + `scheduleMasonry()` 调用、`layoutMasonry` / `resetMasonryBody` 清 visibility。变异实测：删掉 `scheduleMasonry();` 调用 → 守卫红（EXIT=1，-1）；还原 sha256 比对一致后全绿（11/11）。三镜像 byte-identical 由既有 `fushi/test/build/browser_extension_popup_parity_guard_test.dart` 锁死（本轮全绿）。
- **备注**：调查另发现 popup.js `effectiveDictColumns()`（约 :4060）在扩展里读的是**宿主页** `window.innerWidth`（如 1920），不是弹窗 host 宽——视口收敛逻辑在扩展里失效（窄弹窗不收列）。**本轮不修**，记为后续项：修法方向是在扩展上下文用 host/容器实际宽度替代 window.innerWidth。
