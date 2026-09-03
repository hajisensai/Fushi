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

  - `fushi/test/stats/study_char_caliber_guard_test.dart`（复审补）：**口径统一这件事本身
    的结构守卫**。上面两条都只验证「原语算得对不对」，没有任何东西验证「所有写入
    路径是不是都在用它」——实测两条变异**存活**：
    `video_watch_tracker.dart` 改回 `_pendingCueText.runes.length` → 3262 例全绿；
    `reader_selection_scripts.dart` 的计数调用点漏改一个（`fushiStudyUnits.isUnitEnd`
    换回 `fushiReader.isMatchableChar`）→ 1445 例全绿，而第二条的症状正是
    `charOffset` 用错口径写进 DB。新守卫三组：
    A. 四条 Dart 写入路径（EPUB / 漫画 / 视频字幕 / galgame）都调 `countStudyChars`
       且自己不再出现裸码点计数；
    B. 全仓兑底：`.runes.length` / `.characters.length` 只许出现在白名单里那 6 处
       **非学习字数**用途（日志截断 / 排版 / 查词索引 / 输入校验 / 富文本区间），
       新增第五条写入路径会在这里被逼着表态；
    C. JS 侧按**行为分组**（函数名，不按行号）：做计数/偏移的 9 个函数位置
       一律走 `fushiStudyUnits`（转发的转给本表内另一条）且不得出现 `isMatchableChar`；
       反向同时钉住 `buildSentenceAudioNormIndex` / `collectMatchableSegments` 必须
       **保留** `isMatchableChar`，防止将来一刀切把有声书 cue 匹配也换掉。
       登记表还钉住每个函数的**实现份数**（分页 shell 与连续 shell 各一份），
       多冒出一份没被盯着的实现就红。
    变异实测：上述两条存活变异现均令新守卫真红（分别报「不再调 countStudyChars」
    与「计数函数里出现了 isMatchableChar」）；按唯一锚点还原后 sha256 逐字回到基线。
    control：变异二保留、不跑新守卫，`test/reader/` + `test/epub/` + 两条 stats
    共 1683 例全绿 —— 只有新守卫能拓到它。
- **文本节点边界上不可加（复审 P2，已钉成断言、本轮不改行为）**：
  旧口径逐码点，`count(a)+count(b) == count(a+b)` 恒成立；新口径把空格分词文字的
  连续串计 1，于是在**词内**切开时不成立。而两侧的算法正好分立在这条缝两边：
  Dart `chapterCharacterCount` = `countStudyChars(chapterPlainText(i))`（整章**拼接后**
  一个字符串，`epub_book.dart`）；JS `buildNodeOffsets` = Σ `countChars(node.textContent)`
  （**逐文本节点**求和，`reader_pagination_scripts.dart`）。实测：
  `["The end of paragraph one","Start of paragraph two"]` 逐节点 9 / 拼接 8；
  `["un","likely","  to happen"]` 逐节点 4 / 拼接 3。拉丁系文字 + 压缩过的 XHTML
  （`</p><p>` 无空白、`<i>` 切在词中）才触发，日文/中文免疫。

  **影响面（沿真实代码路径核过）**：恢复路的越界判据 `charOffsetInRange`
  （`reader_pagination_scripts.dart`，`runningOffset += this.countChars(node.textContent)`）
  用的是**与写入端同一套逐节点求和**，口径自洽 → **不会误判越界、不会回退
  章首，续读位置不丢**（复审担心的这一条经核不成立，在此记下以免后人重复担心）。
  真正拿 Dart `characters` 与 JS `charOffset` 相加的是 `computeBookProgress`
  （`reader_fushi_source.dart`，`charOffset.clamp(0, sectionSize)`）与 `computeCharWatermark`，
  两者都 **clamp**，所以后果只是「本章进度提前封顶 / 章尾若干单位不计字数」，
  量级 ≈ 该章词内切点数，不崩、不丢位置、换章自愈。

  **为什么不改**：改哪一侧都是动 restore 关键路径（Dart 改成逐节点还会撞上
  「浏览器会把超大文本节点拆开、Dart 的 html 包不会」这个新的不一致），而缺陷本身
  有界、被 clamp、且本轮无法真机验证。所以选择**把「它不可加」写成断言**：
  `study_char_count_parity_test.dart` 新增一组用例，正向钉住上述两个差异值与差异
  **方向**（逐节点 > 拼接，反了就不是「提前封顶」而是「永远到不了 100%」），反向钉住
  无空格文字 / 切在空白与标点上时可加性仍成立。将来谁再假设可加性，这里先红。

- **历史 `char_offset` 跨口径混算（复审 P3）**：`kChapterCharCountCaliber` 3→4 只让
  **每章 `characters`** 后台重算（`reader_fushi_page.dart`）；而
  `ReaderPositions.charOffset`（`packages/fushi_core/lib/src/database/tables.dart`）**没有
  任何 caliber 列**，库里存量值仍是旧口径，升级后会与 v4 的 `characters` 直接相加。
  对英文书：旧值 ≈ 字母数 ≈ 新值的 5 倍 → `charOffset.clamp(0, sectionSize)` 打满，
  升级后**首次打开时书架进度显到本章末尾**，`computeCharWatermark` 水位也播到章尾
  （`sessionWatermarkAfterRestore` 只升不降）→ **那一章的字数一个都不计**。
  是**一次性、单章封顶、可自愈**（用户一滚动就用新口径改写位置），不是永久压制；
  日文/中文书几乎无感（旧新口径在无空格文字上本就一致）。本轮**只记录不迁移**：
  要根治得给 `ReaderPositions` 加 caliber 列 + 迁移阶梯，属于 schema 变更，不应搭在
  这条 PR 里做。

- **已量测的性能变化（新口径每码点 3 次 `RegExp.hasMatch`）**：
  Dart 日文 320k 码点 195ms（旧 1ms）、英文 900k 码点 142ms（旧 3ms）；
  JS `count()` 48k 码点章 11ms（旧 2ms）。绝对值可接受（EPUB 重算是一次性后台任务），
  但 JS 侧 `buildNodeOffsets` 每次 restore / 重分页跑一遍整章，移动端 WebView 上是几十毫秒量级。

- **`kChapterCharCountCaliber` 不是守卫**：它的断言写的是 `>= 4`，改口径规则但不
  bump 版本号不会有任何测试变红（实测：删掉 Thai 只红行为测试和对拍，caliber
  测试照绿）。下次改口径必须手动 bump，别指望测试提醒。

- **备注**：**已有统计数据不重算**——`reading_statistics` / `study_segments` 里按旧口径
  记下的历史值留在原处，所以英文 / 非日语用户的图表在升级点会有一次不连续（数字变小
  约 5 倍，那是修正而非丢失）。日文 / 中文内容实测变化 <0.1%（只在夹杂西文串处）。
  合入前需真机复测阅读器续读与书架进度（改动触及 `charOffset` 坐标系）。
