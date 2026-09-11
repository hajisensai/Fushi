## BUG-2468 · 分页整页插图在 chrome inset 变化后被切成三段
- **报告**：2026-09-11（用户：截图，Windows 竖排分页，无職転生 21 卷插图：前一页底部一条、本页整图、后一页顶部一条）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_pagination_scripts.dart:2893`（分页 shell `setChromeInsets`）与 `:3558`（连续 shell 同名）：写入 `--chrome-top/bottom-inset` 后只清 `paginationMetrics`，**不重算** `--fushi-image-max-width/height`。
  - 机制：图片 max 盒 = body content-box（`_imageMaxBox` → `_contentSize`，`:983`），而 chrome inset 正是 body padding 的一部分（`reader_content_styles.dart:947-948`）。`initialize()` 按初始 HTML 的 inset 取快照——那时 `_hasEverLoaded=false`，顶栏 / 底栏都还没占位（`_readerTopOffset` / `_readerBottomReserve` 只含状态行）；内容就绪后 `_reapplyChromeInsetsAfterFirstLoad` 把顶栏 48 + 底栏 56 补进去，列高（`verticalColumnWidthCss`）随之缩短，图片 max-height 却还停在旧值 → 整页插图比列高多出一条 chrome 高。竖排 multicol 的列沿纵轴堆叠，Blink 把放不下的 monolithic `<img>` 按列切片：上一列末尾一条、本列主体、下一列开头一条——正是截图三张的形态。
  - 只有换样式（`beginStyleReanchor`）/ 改窗口尺寸（`updatePageSize`）才重算过图片盒，所以用户随手改一下字号就会「自愈」，重开书又复发；悬浮态 inset 不变（0）故不触发。
- **[x] ① 已修复** — `e4dc88bc46`：两个 shell 的 `setChromeInsets` 在写入 inset 后、重锚采样前调 `_resetImageMaxVars()`（与 `beginStyleReanchor` 同一 helper）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_chrome_inset_metrics_guard_static_test.dart`：枚举两份 `setChromeInsets`，断言 `_resetImageMaxVars()` 位于 `--chrome-bottom-inset` 写入之后、`inFlight` 早返回之前。
- **备注**：与 BUG-2467 同一根：都是「chrome 占位变化」没有传导到全部消费方。
