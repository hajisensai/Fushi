## BUG-516 · VN模式常驻遮罩且图片极小
- **报告**：2026-07-01（用户：TODO-1085）
- **真实性**：✅ 真 bug（两个独立根因，均在 VN shell）

### 症状①：常驻遮罩（persistent mask）
- **根因**：`hibiki/lib/src/reader/reader_visual_novel_scripts.dart` 的 `initialize()`（原 `985`）里，`readyPromise` 链
  （`document.fonts.ready` → detach → waitForImages → buildSourceIndexes → buildScreens → renderInitialScreen →
  `notifyRestoreComplete()`）**没有 `.catch` 兜底**。`notifyRestoreComplete`（`reader_visual_novel_scripts.dart:940`
  调 `callHandler('onRestoreComplete')`）是**唯一**能清除 Dart 侧 loading 遮罩的信号——遮罩为
  `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1940` 的 `if (!_readerContentReady) Positioned.fill(ColoredBox)`，
  由 `reader_hibiki/navigation.part.dart:67` `_onRestoreComplete` 把 `_readerContentReady` 翻 true。该 notify 是 happy-path 最后一步，
  且所有 restore 方法（`restoreProgress:2582`/`restoreToCharOffset`/`jumpToFragment`）都 `await` 这同一个 `readyPromise`。
  链上任何一步（buildSourceIndexes/buildScreens/renderInitialScreen 对异常章节 markup 抛错）reject 都会**静默吞掉 notify**，
  遮罩只能等 8s 兜底 `_startContentReadyTimeout`（`reader_hibiki/navigation.part.dart:30`）才消失 → 表现为"一直有遮罩"。
- **对比**：分页/连续 shell（`reader_pagination_scripts.dart`）把 restore 折进 initialize 的 `.then`、链更短依赖更少，且不挂在
  可能 reject 的多步 readyPromise 上，所以遮罩总能清掉。

### 症状②：图片极小（tiny image）
- **根因**：共享 reader 图片 CSS（`hibiki/lib/src/reader/reader_content_styles.dart:378-427`）用
  `--hoshi-image-max-width`/`--hoshi-image-max-height` 给 `.block-img` 一个页面尺寸的居中盒。分页 shell 在
  `reader_pagination_scripts.dart:2285-2286/2330-2331` 设这些变量，并在 `_sharedInitImages`（`1470-1491`）把 >256px 的
  standalone `<img>`/`<svg>` 提升为 `.block-img` + `.block-img-wrapper`。**VN shell 两件都没做**：`setupReaderImages`
  （原 `reader_visual_novel_scripts.dart:2341`）调的是 M0 no-op stub（`133-136`），从不加 `.block-img`；那两个 CSS 变量
  也从未被 VN 设置，落回 CSS 回退。结果 VN 图片命中 `img:not(.block-img){max-width:100%}`（`reader_content_styles.dart:397`），
  `100%` 对着 shrink-to-fit 的 `.hoshi-vn-content`（`673`，flex item + `align-items/justify-content:center`）解析 → 坍成几像素。

### 修复（VN-only，非 VN 模式零变化）
- `initialize()` 补 `.catch((error) => { ...; this.notifyRestoreComplete(); })`——fail-open，就绪失败也放行遮罩（症状①根因修复）。
- 新增 `applyImageMaxVars()`（在 `initialize` 里 `ensureStage()` 之后调），按 VN viewport 设 `--hoshi-image-max-width/height`
  （ratio = `ReaderLayoutDefaults.imageWidthViewportRatio` = 0.95，单一真相源）。
- `setupReaderImages` 先调新增 `promoteBlockImages(scope)`：镜像分页 `_sharedInitImages` 把 >256px 的 standalone img/svg 提升为
  `.block-img` + `.block-img-wrapper`，gaiji 字形图排除（症状②根因修复）。

- **[x] ① 已修复** — `reader_visual_novel_scripts.dart`：`initialize` 加 `.catch` + `applyImageMaxVars`（`initialize`/`ensureStage` 后）+
  `setupReaderImages` 调 `promoteBlockImages`/`wrapBlockImage`。提交见分支 `fix-1085-vn-mode-mask-image`。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/vn_shell_smoke_test.dart`：新增
  `BUG-516①`（initialize `.catch` 里仍 fire notifyRestoreComplete）、
  `BUG-516②`（VN 设 --hoshi-image-max 变量 + 大图提升为 .block-img + gaiji 排除 + ratio 0.95）、
  never-break（分页 shell 不含 promoteBlockImages/applyImageMaxVars）。6 tests 全绿。
- **备注**：源码/生成器守卫层（headless WebView CI 跑不到真实 DOM）。真机 Gate 留 owner：开 VN 模式 → 无常驻遮罩（不必等 8s）+ 图片正常大小。
