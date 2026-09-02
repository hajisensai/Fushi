## BUG-2056 · 英文缩合形/所有格查不到词：撇号被当扫描终点 + 撇号写法不归一
- **报告**：2026-09-02（用户：针对英语等类似语言优化字符与词）
- **真实性**：✅ 真 bug，而且是**两层**，只修一层等于没修。

  **第一层（扫描层，取词被截断）** — 根因
  `fushi/lib/src/reader/reader_selection_scripts.dart:388`（`scanDelimiters` 含
  ASCII `'`、左单引号 `‘` U+2018 与排版撇号 `’` U+2019）+ 前向扫描
  `if (this.isScanStop(char)) break;`。同一份逻辑另有三份逐字节相同的镜像：
  `fushi/assets/popup/selection.js:20`、
  `fushi/assets/browser_extension/vendor/selection.js`、
  `tools/browser-extension/vendor/selection.js`。

  症状：**EPUB 正文**里点 `don’t` 的 `don`，喂给引擎的查询串被截成 `don`；点 `t`
  只得到 `t`。`it’s` / `John’s` / `we’ve` / `they’re` 这类缩合形与所有格整类匹配
  不到词条。真实 EPUB 几乎一律用排版撇号 U+2019，所以覆盖面是英文内容的常见词。

  > **字幕路径不在症状范围内**（早期描述把它一并写进来了，是错的）：
  > `fushi/lib/src/pages/implementations/video_fushi_page.dart:374-386` 的
  > `subtitleLookupTerm` 只回退词首、**前向不截断**（`graphemes.skip(start).join()`
  > 一直取到句尾），字幕从来就把 `don’t` 整个送进引擎。字幕受影响的只有下面的
  > 第二层。

  根因不是「少了一个字符的白名单」，而是**撇号是否词边界取决于上下文，代码却把它
  建模成了字符本身的属性**：`isScanStop(char)` 只看单个字符，撇号在 `don’t` 里是
  词内字符、在 `‘hello’ world` 里是引号，同一个码点两种角色。

  **第二层（引擎层，整词送进去也查不到）** — 修好扫描层只是半条链。实测：
  - `fushi/assets/transforms/en.json`（11469 字节）里 U+2019 出现 **0 次**，
    五条撇号规则全是 ASCII U+0027：`"fromSuffix":"'s"` / `"s'"` / `"'d"` /
    `"in'"` / `"fromPrefix":"don't "`；绝大多数英文词典的条目键同样是 ASCII。
  - 引擎侧原本没有任何 `’ → '` 归一：`native/fushidicts/fushidicts_src/` 下
    `0x2019` / `u2019` 零命中；english 处理器链只有 lowercase 一项。
  - NFKC 救不了：**U+2019 没有兼容分解**，`utf8proc_NFKC("’")` 仍是 `"’"`。

  于是三级候选 `don’t` / `don’` / `don` 里前两级在 ASCII 词典与 ASCII 还原规则下
  全部落空，最终命中的还是 `don`——**与修复前同结果**。所以本 bug 必须两层一起修。
- **[x] ① 已修复** — 两层各一处，都是根因层面的模型修正：

  **第一层：给四份实现加上下文判据** `isIntraWordApostrophe(text, index)`——撇号两侧
  都是**空格分词类字母**时是词内字符，前向扫描跨过去、继续扫。字母集与
  `native/fushidicts/fushidicts_src/scan/word_scan.cpp` 的
  `is_space_delimited_letter` 逐区间对齐（拉丁/希腊/西里尔/亚美尼亚/希伯来/阿拉伯/
  格鲁吉亚），全仓一个模型，不新增语言开关——本 app **没有全局学习语言**，判据只能
  来自文本自身。

  撇号集 `['‘’ʼ]` 里四个码点角色不同，别当成一视同仁的白名单：`'` U+0027 /
  `‘` U+2018 / `’` U+2019 都在 `scanDelimiters` 里，是真正被这条判据救回来的三个
  （U+2018 是 OCR 把 `’` 认错的常见产物，`don‘t` 原本同样被截成 `don`）；
  `ʼ` U+02BC **不在** `scanDelimiters` 里，本来就不截断，列进来只为让「撇号类字符」
  在四份实现里是同一个集合。

  **刻意不改词首回退**（`while (startOffset > 0 && !this.isScanBoundary(...))`）：
  回退跨撇号会把法语/意大利语省音写法（`l’homme`、`dell’arte`）的锚点从 `homme`
  拖回 `l’`，反而查不到 `homme`。前向跨过是纯增益——C++ `scan_candidates` 会生成
  `don’t` / `don’` / `don` 三级前缀，短词不会被挤掉；回退跨过是零和的锚点搬家。

  **第二层：引擎侧撇号写法归一**
  （`native/fushidicts/fushidicts_src/text_processor/text_processor.cpp`，
  `get_english_processors()` 里新增一个 `{0,1,2}` 处理器）。option 0 保留原文，
  option 1 把 `' ‘ ’ ʼ` 全折成 ASCII `'`，option 2 全折成 U+2019，于是
  「文本写法 × 词典条目写法」四格全覆盖，且**既有命中一条不丢**。

  归一放在**查询串**这一侧而不是词典条目那一侧：已导入词典是只读二进制，改导入
  路径救不了存量库；而 text_processor 是变体扇出，一处双向出变体就同时盖住了
  「排版撇号文本 → ASCII 条目」和「ASCII 文本 → 排版撇号条目」。无撇号文本
  `processed == variant`，变体集原地折叠，零额外查询。

  需要说明的是：`text_processor::process()` **没有按语言装配**——
  `get_japanese_processors()` / `get_english_processors()` /
  `get_diacritic_removal_processors()` 是无条件串联的（`to_lowercase` 早就跑在日文
  文本上）。所以这条归一在架构上不可能「只挂在 english 上」；它安全的理由是别的：
  它是可选变体、不吞掉原文，且只对含撇号的文本产生额外候选。

  提交：见本分支 `fix/en-apostrophe-word-scan`。
- **[x] ② 已加自动化测试** — 两层各自在**最强可落地层**：

  **扫描层**：`fushi/test/lookup/apostrophe_word_scan_bug2056_test.dart` + `.js`
  （沿用 BUG-1773 的 node:vm fake DOM 装置，**真执行**浮窗版
  `assets/popup/selection.js` 与阅读器注入脚本 `ReaderSelectionScripts.source()`
  两份实现）。行为断言：三种终点撇号（`'` / `‘` / `’`）、所有格与空格桥接叠加、
  引号语义不变、法语省音锚点不回归、跨文本节点不粘、`rock 'n' roll` 左侧非字母
  不跨、maxLength 仍截断、日文逐字扫描不变；**外加字母集逐区间覆盖**——
  `LETTER_RANGE_SAMPLES` 每条对应 `spaceDelimitedLetterPattern` 的一个区间代表
  码点，`LETTER_GAP_SAMPLES` 覆盖区间之间必须仍是空隙的码点（×、÷、tatweel、
  阿拉伯数字、格鲁吉亚段分隔符、泰文…），`REAL_WORLD_SAMPLES` 是 `café’s` /
  `п’ять` / `α’β` / `א’ב` 这类跨区间真实形状。源码守卫钉「桥接必须先于
  `isScanStop`」「词首回退整条 while 条件逐字不变」，以及
  `apostropheClassInvariant`——撇号类四个码点必须都在 pattern 里、三个真终点必须
  仍在 `scanDelimiters` 里、U+02BC 必须仍**不**在里面。

  **引擎层**：`native/fushidicts/tests/text_processor_test.cpp` 加 8 条变体断言；
  新增 `native/fushidicts/tests/en_apostrophe_lookup_test.cpp`（已注册进
  `tests/CMakeLists.txt`）走 app 真正调用的 `Lookup::lookup()` 全链
  （`scan_candidates` → `text_processor::process` → `deinflect` → `query_raw`），
  词典是真的 `write_simple_dict` 产物，还原表是**仓库里那份真的 en.json**（路径经
  argv 传入）。四格全查：`don’t`→`don't` 条目、`John’s`→经 en.json possessive 落到
  `john`（且必须 `matched == 整个查询串`，短前缀命中不算）、`y'all`→U+2019 建键的
  条目、`canʼt`→ASCII 条目。

  **变异实测**（每条：改坏 → 跑 → 确认真红 → 唯一锚点还原 → sha256 对基线）：

  | # | 改坏哪一行 | 红？ | 报错文案（截断） |
  |---|---|---|---|
  | A1 | text_processor 撇号处理器 `options {0,1,2}` → `{0}` | 🔴 | `text_processor_test` 6 条 FAIL；`en_apostrophe_lookup_test` 4 条 FAIL，case 2 报 `did not surface "john" matched on the WHOLE query; got [john <- John]` |
  | B1 | popup 字母集砍掉 `Ø-öø-ʯ` | 🔴 | `[popup/extension] 拉丁-1 段二起点 Ø (Ø-ö)（U+00D8） 必须算空格分词类字母` |
  | B2 | popup 字母集塌缩成 `/[A-Za-z]/` | 🔴 | `[popup/extension] 序数指示符 ª (ª)（U+00AA） 必须算空格分词类字母` |
  | B3 | reader 字母集塌缩成 `/[A-Za-z]/` | 🔴 | `[reader] 序数指示符 ª (ª)（U+00AA） 必须算空格分词类字母` |
  | B4 | 字母集放宽 `À-ÖØ-ö` → `À-ö` | 🔴 | `[popup/extension] 乘号 × …（U+00D7） 不得算字母，撇号必须仍是终点` |
  | C1 | 把 `ʼ` 加进 `scanDelimiters` | 🔴 | `apostropheClassInvariant`：`U+02BC 不得进 scanDelimiters`（**注意**：JS 行为断言 ③ 在这条下仍绿——桥接接住了它，所以行为层探测不到，只有源码守卫拦得住） |
  | C2 | 从 pattern 删掉 `ʼ` | 🔴 | `apostropheClassInvariant`：`intraWordApostrophePattern 必须含 U+02BC` |
  | E1 | 从 popup pattern 删掉 `‘` | 🔴 | `[popup/extension] U+2018（OCR 误识的 ’）也必须被跨过` |
  | E2 | 从 reader pattern 删掉 `‘` | 🔴 | `[reader] U+2018（OCR 误识的 ’）也必须被跨过` |
- **备注一（早期版本的两条错误陈述，已在本文件更正）**：
  ① 症状里写的「字幕」不成立，字幕路径前向不截断（见上）；
  ② 「en.json 词形还原表里本来就有这些形态」会让人以为扫描层修好就闭环了，
  实际上那些规则是 ASCII 的，U+2019 走不进去——这正是第二层存在的理由。
- **备注二**：本轮排查同时发现**统计域字数口径**对英语类语言的更大问题（英文按字母计、
  俄/韩/希腊/阿拉伯/泰整script计 0、带变音的拉丁字母不计），那是独立议题、独立改动面，
  未包含在本 bug 内。
