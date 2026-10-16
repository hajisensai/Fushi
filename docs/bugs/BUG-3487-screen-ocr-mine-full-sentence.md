## BUG-3487 · 截屏识字制卡句子只有被点字所在一行，竖排/折行长句只剩半句
- **报告**：2026-10-16（用户：应用内反馈 1Mwaro8UTC，Android vivo V1901A / API 28，「应用外 OCR 查词制卡只有单词、没有例句」）
- **真实性**：✅ 真 bug（部分）。BUG-2900 已把被点字所在**整行**补进 `{sentence}`，但行是 ML Kit 的排版行：
  `ScreenOcrService.toLines`（修前 `fushi/android/app/src/main/java/app/fushi/reader/ScreenOcrService.java:493-519`）
  遍历 `TextBlock → Line` 时把 block 丢掉，`onSelectionTap`（修前 `:580`）只把那一行放进 `EXTRA_PROCESS_TEXT`；
  Dart 侧 `popup_dictionary_page.dart` 修前 `:155` `_sentenceOf` 直接拿整行当句子。竖排一列一行、横排折行时，
  一句话被拆成多行，制卡句子只剩被点的那一行（半句 / 几个字，用户看来接近「没有例句」）；一行装两句时又多出无关的半句。
- **[x] ① 已修复** — 原生 `toLines` 保留每行所属 block：块内各行按 `\n` 拼成块全文，记下本行起点
  （`ScreenOcrLayout.Line.blockText` / `blockOffset`、`ScreenOcrLayout.blockLineOffsets`），点字时经新 extra
  `PopupDictFlutterActivity.EXTRA_SOURCE_BLOCK` / `EXTRA_SOURCE_BLOCK_OFFSET` → `PopupEngineHolder`（载荷键
  `sourceBlock` / `sourceBlockOffset`）→ `PopupChannel` → `popup_main` → `PopupDictionaryPage.sourceBlock`。
  句子由纯函数 `fushi/lib/src/lookup/ocr_block_sentence.dart` `ocrBlockSentenceAt` 从块里截：换行不是句界
  （CJK 直接相连、拉丁词间补空格），句末标点 `。｡！？!?．‼⁇⁈⁉` 与后跟空白的半角 `.`，句末闭括号 / 引号归前句，
  `」「` 紧邻也算句界，`…` 不算句界；截出超过 200 码元（无标点的长块）返回 null。块缺失 / 与行对不上 /
  截不出时回落为整行（BUG-2900 原行为）。源文本条上点同一行别的字时按那个字重新取句。
  `EXTRA_PROCESS_TEXT` 仍是整行，源文本条与扫描查词不变；旧入口不带新 extra 时行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/ocr_block_sentence_test.dart`（竖排多行合并、跨行句、多句块、
  标点缺失、超长回落、中英文）；`fushi/test/pages/popup_dictionary_source_line_test.dart` 新增三条 BUG-3487
  （真页面制卡取块内整句、条上点字换句、错位块回落整行）+ 通道载荷透传/不残留断言；
  `fushi/android/app/src/test/kotlin/app/fushi/reader/ScreenOcrLayoutTest.kt` `blockLineOffsetsIndexIntoNewlineJoinedBlock`。
- **备注**：BUG-2900 的防误填判据未改：基础层原地跳到释义里的别的词、嵌套层再查时仍不补句；
  系统 PROCESS_TEXT / 分享 / 剪贴板 / 悬浮查词窗（`FloatingDictService`）本来就没有上下文，仍无句子；
  悬浮字幕点字传的已是整条字幕，不带块、句子仍为整条。
