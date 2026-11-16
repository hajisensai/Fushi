## BUG-4707 · 截屏识字点字查词只扫被点那一行，折行处把词截断
- **报告**：2026-11-16（用户：应用内反馈 il3dIBVGJq——安卓悬浮球与 PC 应用外截屏识字，分行处单词被截断）
- **真实性**：✅ 真 bug。OCR 的行是排版折行（BUG-3487 已定「换行不是句界」），但三条截屏识字查词入口的查词串都只取被点那一行：
  - Android 应用外查词窗：`fushi/lib/src/pages/implementations/popup_dictionary_page.dart:268`（`_lookupWidgetSource` 只对行做 `sourceLookupSuffixAt`，原生已传来的 ML Kit 块全文只用于截句）与 `:429`（条上点字同样只取行内后缀）；
  - 桌面冻结层：`fushi/lib/src/floating_ball/app_floating_ball_host.dart:1242`（`text.substring(hit.charIndex)` + `sentence: text`，查词串与制卡句子都只有这一行，桌面识别器只给行框、没有块）；
  - iOS 截屏 / 拍照选取页：`fushi/lib/src/floating_ball/screen_ocr_picker.dart:324`（只把行交给查词）。
  词被折到下一行时，从被点字扫到行尾就断了，查不到整词。
- **[x] ① 已修复** — 块内续文规则收进 `ocr_block_sentence.dart` 的 `ocrBlockContinuationAfterLine`（与截句同一套折行拼接：CJK 直连、拉丁补空格）；只有行框的平台的文本块聚合从卡图模块抽到 `screen_ocr_text_block.dart`（`screenOcrTextBlockMembers` 按阅读顺序给块内行，卡图与查词共用），`screenOcrBlockLookupForHit` 给出「被点行 + 续文」与块级整句。Android 查词窗首查与条上点字的查询串都接上块续文，源文本条仍是被点那一行；桌面冻结层与 iOS 选取页改用 `screenOcrBlockLookupForHit`。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/ocr_block_sentence_test.dart`（续文拼接 / 截断）、`fushi/test/floating_ball/screen_ocr_text_block_test.dart`（行框聚合成块、阅读顺序、续文与整句）、`fushi/test/pages/popup_dictionary_source_line_test.dart`（真查词窗：首查与条上点字都跨行查词）。
- **备注**：真机（Android 悬浮球、Windows 冻结层）未复测原始失败路径。只有行框的平台按几何聚合块（与卡图同一规则），Lens 一段已是一行，相邻两段几何上挨着时也会被并成一块。
