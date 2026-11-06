## BUG-4130 · 转录 / 字幕合成书竖排时半角「!」「?」横躺
- **报告**：2026-11-05（用户：应用内反馈 #I2PeHK2ztE；kitsune 模型转录生成的书竖排阅读，「断る!」「何を?」里的符号方向异常）
- **真实性**：✅ 真 bug。ASR 输出（以及大量手写字幕）用 ASCII `!` `?`。阅读器竖排 `text-orientation: mixed` 按 CSS 规范把 UAX #50 R 类的半角拉丁标点横躺排——CSS 行为正确，但不是日文排版；正式日文 EPUB 对这种字符用縦中横标记。字幕合成书的正文由 `packages/fushi_audio/lib/src/matching/cues_to_epub.dart:153` 生成，cue 文本原样转义进 `<span data-cue-id>`，没有任何縦中横标记。根因在「字幕 → EPUB」装配层：它是唯一知道这是日文字幕正文的地方；ASR 文本规范化属上游 `fushi-subtitles` 的算法层，且改写文本会让 cue 文本与正文、查词、制卡的字符不一致；阅读器层面无法用 CSS 选中单个字符，DOM 改写又会牵动三种布局的字符偏移。与 BUG-3606（缺 `vert` 字体导致「」横排）不是同一机制。
- **[x] ① 已修复** — `CuesToEpub.typesetCueText`：紧跟日文字符（假名 / 汉字 / CJK 标点 / 全角）的 1–2 个半角 `!` `?` 包成 `<span class="tcy">`，章节样式加 `.tcy{-webkit-text-combine:horizontal;text-combine-upright:all;}`；文本不转全角，横排不受影响，`Hello!` 与 `!!!` 三连不动。转录书与字幕书重新导入（`srt_book_reimport.dart` 重建正文）同走这条。提交 `2409b4883e`。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/cues_to_epub_test.dart`「半角 ! ? の縦中横」（包裹规则、拉丁 / 三连 / 全角不动、转义、生成 XHTML 含 CSS 与 span）。
- **备注**：已导入的旧书正文不变，需「重新导入字幕」重建。paginated / continuous / vn 三种模式共用章节内样式（VN 克隆元素保留 class，`text-combine-upright` 可继承），但本次没有真机 / 真 WebView 截图复测三种模式：本机无该书与可用设备，属待补。
