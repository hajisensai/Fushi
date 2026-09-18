## BUG-2580 · 阅读器目录靠锚点分节时当前章名与勾选落错
- **报告**：2026-09-18（用户：「章节显示有问题，無職転生 23 的第十话起码要去到 79.31% 这么多的
  进度，而且看过的都没打勾」，附 Windows 阅读器截图：顶栏「無職転生 23 · 第十話『二つ目』」、
  页脚进度 50.4%，左侧「导航」列表里第七～十话**四行都带勾**、第一～六话没有）
- **真实性**：✅ 真 bug，但不是进度算错——50.4% 是对的，错的是**章名**和**勾**。
  真书取证（`C:\文档\fushi_books\無職転生 ～異世界行ったら本気だす～ 23`）：正文只有 4 个 xhtml，
  nav 里第一～六话全指向 `p-002.xhtml#id-a002…a007`、第七～十话全指向
  `p-003.xhtml#id-a008…a011`。DB `reader_positions` 落的是 `(section 10 = p-003, char_offset 7923)`，
  用 `computeTocAnchorCharOffsets` 实跑 p-003 的锚点在 0 / 9688 / 25600 / 40770（共 49298 字）——
  7923 是**第七話**，截图正文（「何か違和感を覚えて、エリスの方を見る」）也在第七話。
  第十話锚点在全书 79.2% 处，与用户说的 79.31% 吻合：用户是被顶栏「第十話」误导，以为读到第十话了。
  根因两处，同一个模型缺陷——`TtuTocEntry` 只有 spine 章号 `index`，同章多条目录项完全同解：
  - `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:2537`（修复前）
    `_currentChapterLabelFor` 从目录**末尾**往前找第一个 `index <= 章号` 的条目 → 同章四条永远命中
    最后一条「第十話」；顶栏章名、收藏 / 制卡落库的 `chapterLabel` 全错。
  - `fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart:1305`（修复前）
    `resolveCurrentTocChapter` 只按章号 floor，`selected: currentIdx == toc[i].index` 让同章四条
    全部打勾（那个勾是「当前章」标记，不是「已读」；用户看到四个勾自然理解成已读标记，
    于是又觉得「看过的第一～六话没勾」）。有声书面板「章节」tab 同款判据。
  上游 `5fffeff48c7` 已给条目补了 `fragment`（目录跳转带锚），但「当前是哪一条」仍没用它。
- **[x] ① 已修复** — `c905db3eefb`：
  - 引擎 `packages/fushi_engine/lib/epub/epub_book.dart` 新增
    `chapterAnchorCharOffsets(index, fragments)`：一次 DOM 遍历（跳 `rt/rp/rtc`，与
    `chapterPlainText` 同剥离规则），给每个锚点 id 算「之前的实义字数」（`countStudyChars` 口径，
    与阅读器回报的 `charOffset` / 落库 `char_offset` 同尺）。
  - `reader_fushi_page.dart` 开书后 `compute(computeTocAnchorCharOffsets)` 在后台 isolate 算整本
    目录锚点偏移（这本书 875 ms，不阻塞首屏；目录无锚点的书直接跳过），落定作废压平缓存；
    `TtuTocEntry.anchorCharOffset` 经 `flattenTtuTocEntries(anchorCharOffset:)` 填入。
  - `ttu_toc_flatten.dart` 用 `resolveCurrentTocEntry(toc, chapter, charOffset)` 取代
    `resolveCurrentTocChapter`：按 (章号, 章内偏移) floor 返回**唯一一条**的下标；位置未知
    （刚开书 / 刚跳章）取当前章首条而非末条。顶栏章名（`_currentChapterLabelFor` 带
    `charOffset`，来源依次：最近回报的精确偏移 → 本次导航目标锚点 → 章内分数折算）、导航面板
    勾选行（新参数 `readerCharOffset`）、有声书「章节」tab（`currentCharOffset`）三处同一口径；
    收藏 / 制卡落库的 `chapterLabel` 也带句子偏移。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_toc_anchor_subchapter_bug2580_test.dart`
  （夹具数值全取自真书）：DB 位置 (10, 7923) → 第七話；同 xhtml 逐锚点切话；位置未知取首条不掉
  上一章；`chapterAnchorCharOffsets` 与 `countStudyChars(锚前纯文本)` 相等、振假名不计、与全章计数
  闭合、kobo 自闭合 `<script/>` 章可解析、`computeTocAnchorCharOffsets` 按章分组只算带锚条目；
  真面板 widget 用例：第七～十话同章、`readerCharOffset: 7923` → 恰好一个勾且落在第七話。
  BUG-2545 的用例迁到 `resolveCurrentTocEntry`（floor 语义逐字同解）。
- **备注**：勾的语义仍是「当前所在」，不是「已读」；用户提的「看过的打勾」是另一个功能（按位置
  标已读），本条不做。
