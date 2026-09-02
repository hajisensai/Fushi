## BUG-2058 · 非拉丁非CJK文字字数恒0：统计为0且章内进度退化成章号
- **报告**：2026-09-02（用户：针对英语等类似语言优化字符与词）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/epub/epub_book.dart:679` 的
  `_isCountedJapaneseRune` 白名单（v3 口径，逐区间对齐 ttu `isNotJapaneseRegex`）。

  它只收：ASCII 字母数字、平假名、片假名、半角片假名、全角字母数字、CJK 部首与
  统一表意文字、少数迭代符。于是——

  | 内容 | v3 计数 | 应为 |
  |---|---|---|
  | 俄 / 韩 / 希腊 / 阿拉伯 / 希伯来 / 泰 / 天城文 | **0**（整个脚本一个码点都不收） | > 0 |
  | `café` | 3（`é` 不在白名单） | 1 |
  | `I don't know` | 10（逐字母） | 3 |

  「整脚本记 0」不只是统计难看：每章 `characters` 全 0 → `computeBookProgress`
  （`fushi/lib/src/media/sources/reader_fushi_source.dart:110`）的分母 `totalChars`
  为 0 → 走章级回退，**章内进度完全消失**（书架进度条只按「章号 / 章数」跳）；
  `studyGoalCharsForDay` 的分子恒 0 → 每日目标永远不动。

  同一问题的第二面：仓库里**有三套互不相同的字数口径**同时往
  `study_segments.chars` 这一列写——EPUB / 漫画走上述白名单、视频字幕走裸
  `String.runes.length`（`video_watch_tracker.dart:229`，标点空白照计）、galgame 走
  `countGalgameChars`（`galgame_char_count.dart`，CJK 按字 + 西文连续串按词）。三个数
  相加、同图表展示、同一个每日目标，本身就不成立。
- **[x] ① 已修复** — 收敛成全仓唯一口径 `countStudyChars`
  （`fushi/lib/src/stats/study_char_count.dart`）：无空格文字（汉字 / 假名 / 谚文 /
  泰 / 老挝 / 高棉 / 缅甸 / 藏 / 注音 / 彝）按码点计 1，其余文字的连续字母数字串计 1，
  组合记号（阿拉伯 harakat、天城文 matra）与词内撇号透明，标点空白符号断词不计。
  判定顺序**先脚本后类别**（`〇` 是 `\p{N}` 但属 Han，`。` 属 Han 但非字母数字）。
  口径对齐 LunaTranslator `count_words_mixed` 与 exSTATic，也就是仓库 galgame 路径
  2026-04 起已在用的那套——不是新发明，是把已有的正确实现提升为共享原语。

  四条写入路径（EPUB 章字数 / 漫画 OCR / 视频字幕 / galgame hook）全部改走它；
  删掉 ttu 白名单三个函数与 galgame 的两张手写码点表。`kChapterCharCountCaliber`
  3→4，已有书开书时后台按新口径重算并回写。

  **JS 侧同步**：JS 算出的 `charOffset` 会写进 DB 的 `char_offset` 列，并与 Dart 侧
  每章 `characters` 直接相加（`computeCharWatermark` / `computeBookProgress`，注释
  原文「同单位」），所以三个 shell 的计数点一并收敛到共享判据
  `window.fushiStudyUnits`（`fushi/lib/src/reader/reader_study_unit_script.dart`，
  单一 JS 真相源，由 `engineShell` 在任何 shell 安装前注入）。逐字符谓词从
  「这个字符计不计」换成「这个位置是不是一个学习单位的结束」，于是 11 个调用点
  每处只改一行，几何与结构一律不动。

  **刻意不动**：`isMatchableChar` / `normalizeText` / `readerRegexNegated` 那套白名单
  仍是有声书 cue 重定位（`foldNormalize`、`buildSentenceAudioNormIndex`、VN 的
  `collectMatchableSegments`）和纯图片章判定的坐标系，与 Dart `AudioTextNormalizer`
  逐值对齐，跟着改会打断有声书高亮。计数与匹配是两个问题，本轮只统一计数。
- **[x] ② 已加自动化测试** —
  - `fushi/test/stats/study_char_count_test.dart`：口径行为锁定（13 组，覆盖各脚本、
    撇号、组合记号、判定顺序陷阱 `〇` / `。`）。
  - `fushi/test/stats/study_char_count_parity_test.dart` + `.js`：**Dart↔JS 对拍**，
    node 真执行 `kStudyUnitJs`（与真机注入同一常量），40 条语料逐条比对
    ① JS `count` == Dart `countStudyChars`，② 逐位置 `isUnitEnd` 累加 == `count`。
    此前两侧各有一份手写白名单、只靠注释互相引用维持对齐，**没有任何测试会在分叉时
    报红**——分叉表现为续读位置与书架进度静默偏移，不崩不报错。
  - `fushi/test/epub/chapter_char_count_test.dart`（取代 `japanese_char_count_test.dart`）：
    英文章节按词计、俄文章节不再记 0、caliber 已到 v4。

  变异实测：从 JS 侧移除 `Script_Extensions=Hangul` → 对拍红，报「语料 #10 分叉，
  Dart 8 / JS 2」；按唯一锚点还原后 sha256 与变异前一致。
- **备注**：**已有统计数据不重算**——`reading_statistics` / `study_segments` 里按旧口径
  记下的历史值留在原处，所以英文 / 非日语用户的图表在升级点会有一次不连续（数字变小
  约 5 倍，那是修正而非丢失）。日文 / 中文内容实测变化 <0.1%（只在夹杂西文串处）。
  合入前需真机复测阅读器续读与书架进度（改动触及 `charOffset` 坐标系）。
