## BUG-2787 · iOS 漫画 OCR 后点字只弹出空白框
- **报告**：2026-09-28（转述 iPhone 用户：跑完 OCR 后点任何字都只出一个空白框）
- **真实性**：✅ 真 bug（代码路径定位，未在 iPhone 上复现）。已排除：没查到词时显示「无结果」占位（`fushi/lib/src/pages/implementations/dictionary_popup_layer.dart`）；选中文本为空时 `dispatchMangaSelection`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`）不弹框；未装词典时同样走「无结果」占位；系统 OCR 无逐字区域时会按行均分。根因拆成两条：
  - 「点任何字都空白」→ **BUG-2759**：iOS WKWebView 内容进程在整卷 OCR 的内存峰值下被回收，全仓没人接 `onWebContentProcessDidTerminate`，常驻查词弹窗此后永久空白。
  - 「点某些字空白」→ **BUG-2784**：点纯符号时查询词被清洗成空串，弹窗判据把真结果当成占位。
- **[x] ① 已修复** — 见 BUG-2759、BUG-2784。
- **[x] ② 已加自动化测试** — 见 BUG-2759、BUG-2784。
- **备注**：此前写的「重新识别本卷会静默覆盖 mokuro.moe 自带 OCR」不准确——该入口打开的是整卷 OCR 向导（`MangaModule.openBookOcr`，需选引擎并确认），属显式操作；且报告者是因导不进 `.mokuro`（BUG-2786）才自行跑 OCR，与本 bug 无关。用户侧快速自证 BUG-2759：退出漫画再进（重建常驻 WebView），第一次点字恢复正常即坐实。
