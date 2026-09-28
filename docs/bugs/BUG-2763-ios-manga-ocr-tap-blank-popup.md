## BUG-2763 · iOS 漫画 OCR 后点字只弹出空白框
- **报告**：2026-09-28（转述 iPhone 用户：跑完 OCR 后点任何字都只出一个空白框）
- **真实性**：✅ 真 bug（代码路径定位，未在 iPhone 上复现）。已排除：没查到词时显示「无结果」占位（`fushi/lib/src/pages/implementations/dictionary_popup_layer.dart`）；选中文本为空时 `dispatchMangaSelection`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`）不弹框；未装词典时同样走「无结果」占位；系统 OCR 无逐字区域时会按行均分。根因拆成两条：
  - 「点任何字都空白」→ **BUG-2759**：iOS WKWebView 内容进程在整卷 OCR 的内存峰值下被回收，全仓没人接 `onWebContentProcessDidTerminate`，常驻查词弹窗此后永久空白。
  - 「点某些字空白」→ **BUG-2760**：点纯符号时查询词被清洗成空串，弹窗判据把真结果当成占位。
- **[x] ① 已修复** — 见 BUG-2759、BUG-2760。
- **[x] ② 已加自动化测试** — 见 BUG-2759、BUG-2760。
- **备注**：mokuro.moe 下载的卷自带站点 OCR，「重新识别本卷」会整本覆盖且无确认——那位用户重跑 OCR 很可能把更好的结果盖掉了；此项未处理。用户侧快速自证：退出漫画再进（重建常驻 WebView），第一次点字恢复正常即坐实 BUG-2759。
