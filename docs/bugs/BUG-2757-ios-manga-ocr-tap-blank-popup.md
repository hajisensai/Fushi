## BUG-2757 · iOS 漫画 OCR 后点字只弹出空白框
- **报告**：2026-09-28（转述 iPhone 用户：跑完 OCR 后点任何字都只出一个空白框）
- **真实性**：⚠ 未复现（没有 iPhone 现场）。代码路径排除项：没查到词时显示带图标的「无结果」占位（`fushi/lib/src/pages/implementations/dictionary_popup_layer.dart`），不是空白；选中文本为空时 `dispatchMangaSelection`（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`）直接 return、不弹框。所以「空白框」更像是 iOS 上弹窗 WebView 没渲染出来。候选：A）块被判成横排（Vision 只按单行 h > 1.6w 判竖排，见 BUG-2755 备注），弹窗贴在高句组上/下方，剩余高度过小只剩空壳；B）预热槽复用走 `_showPopupWaitingForRender`（`fushi/lib/src/pages/base_source_page.dart`），注释里记录过 macOS WKWebView「露出白色空 WebView」，iOS 同为 WKWebView。另：mokuro.moe 下载的卷自带站点 OCR，「重新识别本卷」会整本覆盖它且没有确认。
- **[ ] ① 未修复** — 先要证据：请用户开「显示识别范围」截图 + 导出日志（`onMangaOcrHitDebug`、`MangaFushi.onTextSelected`、popupRendered 是否回调），再判 A / B。
- **[ ] ② 未加自动化测试**
- **备注**：同时要确认用户有没有装词典——没装词典时的表现也要对照。
