## BUG-4479 · 漫画 OCR 行尾断字导致整词查词失败
- **报告**：2026-11-13（漫画 OCR 查词）
- **真实性**：✅ 真 bug。原 `fushi/lib/src/media/manga/ocr/manga_ocr_text_join.dart:35` 只在拉丁行界补空格，保留排版断词的连字符，`Under-` / `stands` 被拼成 `Under-stands`。原 `fushi/lib/src/media/manga/manga_overlay_html.dart:604` 和 `fushi/lib/src/media/manga/reader/manga_fushi/controller_lookup.part.dart:152` 又以原始 `block.lines.join()` 为字格与手柄偏移基准，单独修改拼句会让选中字母错位。
- **[x] ① 根因修复** — 提交 `6ebdb48e565`。以 OCR 行边界识别断词，删 U+002D / U+2010 / U+2011 后直接续接字母；同一次布局生成有效行文本、UTF-16 起点和断词行界。DOM 字格、句子与手柄移动共用该文本。空行起点跟随删除前移；有效文本改变时整块重算旧 regions，避免「删连字符与补空格抵消长度变化」的假匹配。
- **[x] ② 自动化测试** — `fushi/test/media/manga/manga_ocr_dehyphenation_test.dart` 覆盖拼接、空行、多行断词、Unicode、旧字框和偏移；`manga_latin_ocr_word_gap_bug4127_test.dart` 用真实生成器与阅读器注入脚本验证跨字格取整词；`fushi/test/second_screen/controller_lookup_targets_test.dart` 验证手柄文本与词首位置；`fushi/integration_test/manga_ocr_dehyphenation_itest.dart` 验证真实 WebView 的手柄查词路径。五个相关单测文件共 95 例通过，通用样例调整后断词文件 15 例重跑通过；Windows 集成用例 1 例通过（6 个探针）；全量 `flutter analyze --no-pub` 通过。
- **真实数据回归**：2026-11-13，验证断词拼接及行内连字符保留；报告与脚本保存在本地验证目录。
- **取舍与范围**：只根据保留的 OCR 行边界判定；行内连字符、数字区间和破折号不删。真复合词恰好跨行时仍可能被合并。单行化且已丢失原行界的旧 Lens 结果无法按此规则恢复；不加入按几何猜行界或词典兜底。跨 block 的 DOM 查词扩展不在本次范围内。
- **现有取词边界**：逐字格 DOM 中独立撇号仍终止扫描，`EVERYONE'S` 选出 `EVERYONE`；集成测试以未换行对照确认行为一致，完整块文本保留 `'S`。本次不改变跨字格撇号规则。
- **设备复测**：2026-11-13，Windows 真实 WebView 使用合成页面验证：`Understands` 中三个字格都选中整词，后续 `the` 光标偏移正确；断行与未断行的所有格选区一致，行内连字符和数字区间保留。已保存 DOM 结果和正文渲染截图，核对光标落在对应字母上。真实漫画仅做 OCR 数据回归，没有逐页手工点击。
