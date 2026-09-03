## BUG-1773 · 点英文单词查词把查询串截到词尾导致短语词条永不匹配
- **报告**：2026-08-22（用户：查 `listen to` 时鼠标点 `listen` 只出 listen 的条目；把鼠标往前挪一点、不在 listen 上面时，反而能查出 `listen to` 短语）
- **真实性**：✅ 真 bug。两条独立的取词路径犯了同一个错——把「查询串该在哪停」和「词的边界在哪」当成了同一个问题。

  **① 视频字幕** `fushi/lib/src/pages/implementations/video_fushi_page.dart:331` `subtitleLookupTerm()`
  ```dart
  if (!_isLatinWordGrapheme(graphemes[graphemeIndex])) {
    return graphemes.skip(graphemeIndex).join();   // 非拉丁：取到句尾
  }
  return graphemes.sublist(start, end + 1).join(); // 拉丁：只返回这一个单词
  ```
  TODO-916 症状③（点 `hello` 的 `e` 得到 `ello` 查不到）当初只需要修**起点**（回退到词首），却顺手把**终点**也钉死在词尾。于是点 `listen` 喂给引擎的查询串是 `"listen"`，`listen to` 这条词条根本没机会被匹配；而点它前面的空格走的是非拉丁分支「取到句尾」，查询串成了 `" listen to music…"`，引擎最长匹配当场命中短语——用户看到的不对称正是这个特例的照妖镜。

  **② 阅读器 / 浮窗 / 浏览器扩展**（前向扫描一遇空白即 break）
  - `fushi/lib/src/reader/reader_selection_scripts.dart:1057`
  - `fushi/assets/popup/selection.js:382`（与 `assets/browser_extension/vendor/`、`tools/browser-extension/vendor/` 三份镜像同形）

  `isScanBoundary` 把三件事混成一坨——空白、句读标点、「只扫日文」门控——而前向扫描直接拿它当 break 条件，查询串被截在第一个空格前。这两个界面因此**英文短语根本查不出来**，而且点空格时 `getCharacterAtPoint` 返回 null（连弹窗都不出），所以看不到视频端那种「移开鼠标就好了」的现象。

  引擎侧从一开始就支持：`native/fushidicts/fushidicts_src/scan/word_scan.cpp:52` `scan_candidates` 按空格分词生成 `listen to music` / `listen to` / `listen` 三级候选，并明确禁止在空格分词语言的单词中间切。缺的一直是喂给它的那个空格。

- **[x] ① 已修复** — commit `5bb1a1d136`
  - `subtitleLookupTerm`：消除拉丁特例的终点分支，查询串**只由起点决定**，终点恒为句尾。引擎按查询串最长匹配并回报 `bestLength`（弹窗 / 字幕据此高亮整词跨度），多喂的后文超出 `FushiDicts.defaultScanLength`（16 码点）自然丢弃，性能无差别。
  - 四份 JS 取词引擎：把 `isScanBoundary` 拆成两个语义不同的谓词——
    - `isScanBoundary`（**词边界**：点击命中判定 + 词首回退用，含空白，语义不变）
    - `isScanStop`（**扫描终点**：标点 / 门控，**不含空白**）

    空白能否跨过去由桥接规则单独决定：只在**同一文本节点内部**跨、且只跨一个（左边必须已有本节点扫入的内容 `scanOffset === start`，右边必须紧跟一个可扫字符）。于是本节点开头/末尾的空白、连续空白、空白后接标点一律终止，跨节点续扫时新节点开头的空白同样不吃——「跨块级空白把两段正文粘成一个词」不会发生。
  - 已知取舍：`<b>listen</b> to` 这种被行内标签劈开的短语仍查不到短语（空白落在新节点开头）。真实 EPUB 里罕见，换来的是零跨块粘连风险。

- **[x] ② 已加自动化测试** — commit `5bb1a1d136`
  - `fushi/test/media/video/subtitle_lookup_term_test.dart`（重写）：拆成「起点」与「终点」两组不变式。起点组断言拉丁命中回退到词首，终点组断言点 `listen` 任意字母查询串都保留后续 ` to`、且与点前面空格给出同样的短语可达性。
  - `fushi/test/lookup/phrase_lookup_whitespace_bridge_bug1773_test.{dart,js}`（新增）：用 `node:vm` 在最小 fake DOM 里**真执行两份实现**的 `selectFromPosition`——浮窗/扩展的 `assets/popup/selection.js`，以及阅读器注入脚本的**真值** `ReaderSelectionScripts.source()`（落到临时文件交给 harness，不是手抄副本）。9 条断言覆盖跨空格短语、词首回退、连续空白 / 末尾空白 / 空白接标点 / 跨节点开头空白四条终止规则、行内标签劈开单词的向后兼容、日文行为不变、`maxLength` 硬上限。外加源码级守卫禁止前向扫描退回 `isScanBoundary`。
  - **变异实测**（守卫是 load-bearing）：
    | 变异 | 结果 |
    |---|---|
    | popup 前向扫描退回 `isScanBoundary` | 行为 + 源码 2 条红 |
    | 阅读器前向扫描退回 `isScanBoundary` | 行为 + 源码 2 条红 |
    | 桥接条件 `scanOffset === start` 放宽成 `!text` | 行为红；**源码断言最初假绿** |
    | `subtitleLookupTerm` 终点钉回词尾 | 5 条红 |

    第三行是这轮最值钱的发现：源码守卫原本写 `src.contains('scanOffset === start')`，而**修复自己的注释里就有这句话**，裸标识符断言被注释文本假阳性满足。已改为锚在完整可执行条件表达式 `if (scanOffset === start || nextChar === undefined ||` 上，重跑变异后转红。

- **备注**：
  - 未做真机复测（视频端点 `listen` / 阅读器点英文词）。
  - 制卡词面不受影响：卡片 word 取的是结果条目的词头（`autoReadWord(first.word, ...)` 同源），不是 query 串；中日文本来就在传「到句尾」的整段 query。
  - 同族但**未动**：`getCharacterAtPoint` 仍在点到空白时返回 null（点空格不查词）。修好前向扫描后，点 `listen` 就能查出 `listen to`，不再需要「点空格才出短语」那个巧合。
