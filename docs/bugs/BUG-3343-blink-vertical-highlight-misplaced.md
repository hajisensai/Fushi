## BUG-3343 · Android 旧 WebView（Blink 105–119）竖排查词高亮错位 / 不可见
- **报告**：2026-10-13（反馈 9GvPvaQQMq、YIP4vKSIJn，同一台 HUAWEI XYAO-W00 / 鸿蒙 4.2（Android 12, SDK 31）：阅读器竖排正文点击查词，「価値」（章标题）的选中高亮画在左上方邻列、形状是横条；「時間」（正文）完全看不到高亮。查词本身命中正确）
- **真实性**：✅ 真 bug（WebView 内核缺陷 + 我方判据只问「API 在不在」）。
  - `window.__fushiCssHighlightsSupported` 原先在四处各写一份 `!!(window.CSS && CSS.highlights && window.Highlight)`（`fushi/lib/src/reader/reader_selection_scripts.dart:381`、`fushi/lib/src/media/audiobook/highlight_bridge.dart:16`、`fushi/lib/src/reader/reader_pagination_scripts.dart:2415` / `:3488`，修复前行号），Chromium 105 起这个 API 就在，于是查词选区一律走 `::highlight(fushi-selection)`（`reader_selection_scripts.dart` `highlightSelection`）。
  - Blink 105–119 的 `::highlight()` 在竖排里不按书写方向旋转高亮矩形：画成横排的「两字宽 × 一行高」横条、落在转置后的位置。Chrome for Testing 同一探针页（`writing-mode: vertical-rl`、h1 + 正文、同一对 Range）逐版截图：113 / 119 标题字高亮不见、正文「時間」的高亮画到下一列行首「の」上；120 / 121 / 122 / 123 / 124 / 125 / 154 全部正确。与用户两张截图的症状一致（标题横条偏左上、正文看不见）。用户日志不带 WebView UA，内核版本是按症状推断、未直接确认。
- **[x] ① 已修复** — （提交见 PR）：判据收成一处 `kReaderCssHighlightsSupportedJs`（`fushi/lib/src/reader/reader_css_highlight_capability.dart`），四个赋值点放逐字副本（这些脚本源码会被 node 行为测试按文本切出来跑，不能写 Dart 插值），逐字相等由测试钉住；UA 里 `Chrome/<120` 的内核按「API 不可用」处理，走既有兜底（查词选区 `.fushi-dict-highlight` 包裹 span、收藏 class span），元素背景随排版画在字上。WebKit（UA 无 `Chrome/`）与 Blink ≥120 不变。代价：旧内核上搜索命中不画 `::highlight(fushi-search)` 标记（跳转照常）。
  - 验证：同一探针页把兜底 span 套上去，113 / 119 走兜底（橙色）、120 / 125 走 `::highlight`（蓝色），四版高亮都正好压在「価値」「時間」上。
  - 三种 view mode：修复是能力判据，与 view mode 无关（分页 / 连续两个 shell 与选区脚本赋的是同一个值，VN 跑在同一份 shell 上）；本机没有 Blink 105–119 的 Android WebView 真机 / 镜像，**未在真 app 的翻页 / 滚动 / VN 下逐一实测**，只在旧版 Chromium 的竖排流式探针页上验过错位与兜底。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_css_highlight_capability_bug3328_test.dart`：node 真跑判据（旧 Android WebView UA / Chrome 105 / 119 → false，120 / 154 / iOS WKWebView → true，无 API → false，无 navigator 不抛）；四个赋值点都用共享判据、不留旧裸判据。
- **备注**：真绘制只能在真 Chromium 里验（上面的逐版截图）。
