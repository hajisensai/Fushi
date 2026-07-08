## BUG-651 · 图片合并两张连续图只有最后一张合并进章节
- **报告**：2026-07-09（用户：）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/reader/reader_pagination_scripts.dart:1562`（`_sharedInitImages` 给合并注入的前导插图也无条件挂 `loading="lazy"`），与 `hibiki/lib/src/reader/reader_pagination_scripts.dart:1955`（`buildPaginationMetrics` 的 `firstContentEdge` 跳过 0 尺寸媒体）共同作用。
- **[x] ① 已修复** — 提交 本提交（分支 `todo1339-merge-consecutive-images`，见 `git log --grep TODO-1339`）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/merged_image_eager_guard_test.dart`（源码扫描守卫，CI 可跑）+ `hibiki/integration_test/merged_image_eager_load_test.dart`（live WebView 行为，Windows 真实 WebView2 已验：`lead1=eager lead2=eager normal=lazy gaiji=eager`），提交 本提交
- **备注**：

### 先证伪 map/注入层（不是这里）
`EpubSpreadMap._mergeImageEntries`（`epub_spread_map.dart`）把整段前导单图片 run 全部收进
`mergedImageChapters`——既有测试 `epub_spread_map_test.dart` 断言两张连续图 `mergedImageChapters == [1, 2]`，
现网通过。`webview.part.dart _injectMergedChapterImages` 也 `for imageChapter in merged` 逐张注入
`<div class="hoshi-merged-image"><img class="block-img"></div>`——复现证实注入产物含**两张** block-img。
**map 层与注入层都正确**，PM 初判「合并逻辑只保留最后一张」被证伪，根因在**渲染落点**。

### 根因（渲染落点，非合并逻辑）
1. 合并注入的前导插图是章首**结构性**内容，插在正文 `<body>` 最前（img1、img2、正文）。
2. 章首落点（`restoreProgress`/`restoreToCharOffset` 在 `charOffset<=0` 时走 `minScroll`）依赖
   `buildPaginationMetrics` 的 `firstContentEdge`。`firstContentEdge` 只计入**非零尺寸**媒体
   （`reader_pagination_scripts.dart:1944` `if (mediaRect.width <= 0 || height <= 0) continue;`）——
   reader 自身注释（TODO-1229/BUG-594，`:2028-2033`）明确「firstContentEdge 已含前导 block 图，落点即插图页」。
3. 但 `_sharedInitImages`（`:1562`）给**所有**非 gaiji 图无条件挂 `loading="lazy"`，**包括这些前导插图**。
4. 章首首次分页时两张前导图都未 load（0 尺寸）→ 落点先锚到正文/最近图。懒加载只对进入视口 margin 的图触发 load：
   离首个文本落点**较近的最后一张（img2）**进 margin → load → 撑开尺寸 → 重锚回它；离得**较远的第一张（img1）**
   永不进 margin → 永不 load → 永远 0 尺寸 → 被 `firstContentEdge` 排除 → 章首锚落到 img2，**跳过 img1**。
   用户所见即「两张连续图只有最后一张合并进章节」。

### 修复
`reader_pagination_scripts.dart _sharedInitImages`：给 lazy 门控加 `.hoshi-merged-image` 放行——
合并注入的前导插图与 gaiji 同理保持 **eager**（`var isMergedLeadImg = img.closest('.hoshi-merged-image')`；
`if (!isGaiji && !isMergedLeadImg) setAttribute('loading','lazy')`）。eager 保证全部前导图无条件 load、
撑开真实尺寸 → `firstContentEdge` 计入**全部**前导图 → 章首锚落到第一张，两张都在章内。
仅影响合并书的少量前导插图，普通正文大图仍 lazy（不回退 TODO-1074），gaiji 仍 eager（行为不变）；
非合并书无 `.hoshi-merged-image`，完全 no-op（向后兼容）。

### 测试
- `hibiki/test/reader/merged_image_eager_guard_test.dart`（CI 可跑源码扫描守卫）：`_sharedInitImages` 设置
  `loading=lazy` 前必须放行 `.hoshi-merged-image`（引用 `isMergedLeadImg` / `closest('.hoshi-merged-image')`），
  且注入端仍用 `hoshi-merged-image` marker（两端接线一致）。
- `hibiki/integration_test/merged_image_eager_load_test.dart`（live WebView，跑**真实** `_sharedInitImages`）：
  两张 `.hoshi-merged-image` 前导图 loading 都不是 lazy（eager），普通图仍 lazy，gaiji 仍 eager。
  **Windows 真实 WebView2 离屏已验通过**：`[merge-eager] lead1=eager lead2=eager normal=lazy gaiji=eager`。
- 回归：`flutter test test/reader/ test/epub/` 全绿（1152 项）。

### 真机验收步骤（用户）
1. 一本含**两张连续整页插图后跟一个文本章**的 EPUB（如封面/口绘×2 + 第一章正文）。
2. 设置里开「图片合并」（`ttu_merge_image_pages`）。
3. 从插图前一章向后翻到该文本章章首（或点目录跳该章）。
4. 期望：章首**两张插图都在**（先第一张、再第二张、再正文），修复前只显示第二张。
