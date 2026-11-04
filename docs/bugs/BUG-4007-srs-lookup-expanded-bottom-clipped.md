## BUG-4007 · 复习卡查词弹窗展开后底部被截断且其他词典消失
- **报告**：2026-11-04（开发者反馈 #1b5vbu96Ts，标题「展开以后底部被截断了，而且其他字典没了」，Android OnePlus CPH2747 363x792@3.5，3.3.0-debug.23261；正文空，截图未随导出）。
- **真实性**：❌ 未复现。日志（最后 300 行）只有 `SrsReviewPage.focus` / `DesktopAudioPlayback.playFile` / `Process.memoryPressure` / 远程 Ping 失败，没有任何查词、WebView、布局相关的错误或面包屑，无法判断「展开」指的是哪个动作（词典折叠组展开 / 释义「展开」/ 弹窗拖大）。代码侧相关的只有自适应高度链：外壳按 `layoutAutoFitHeight` 收高、WebView 仍按最大高度布局（`fushi/lib/src/pages/implementations/dictionary_page_mixin.dart:1116-1122` `webViewOverflowHeight`），内容变高后靠 `onContentMetrics`（`:1250-1274`）把外壳长回去。没有现场无法确认是这条链没回报、还是热槽 / 内存压力（日志里 memoryPressure 多次）导致 WebView 重建后只剩一本词典。不凭猜测改。
- **[ ] ①** —
- **[ ] ②** —
- **备注**：需要截图 / 录屏与「展开」的具体操作；可开查词诊断（LookupPerfTrace）后复现再取日志。
