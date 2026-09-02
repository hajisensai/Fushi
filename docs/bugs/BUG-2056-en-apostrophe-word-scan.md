## BUG-2056 · 英文缩合形/所有格查不到词：撇号被当扫描终点
- **报告**：2026-09-02（用户：针对英语等类似语言优化字符与词）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_selection_scripts.dart:388`
  （`scanDelimiters` 含 ASCII `'` 与排版撇号 `’` U+2019）+ `:1173` 前向扫描
  `if (this.isScanStop(char)) break;`。同一份逻辑另有三份逐字节相同的镜像：
  `fushi/assets/popup/selection.js:20/402`、`fushi/assets/browser_extension/vendor/selection.js`、
  `tools/browser-extension/vendor/selection.js`。

  症状：英文正文/字幕里点 `don’t` 的 `don`，喂给引擎的查询串被截成 `don`；点 `t`
  只得到 `t`。`it’s` / `John’s` / `we’ve` / `they’re` 这类**缩合形与所有格**整类
  匹配不到词条——而 `fushi/assets/transforms/en.json` 的词形还原表里本来就有这些
  形态。真实 EPUB 几乎一律用排版撇号 U+2019，所以覆盖面是英文内容的常见词。

  根因不是「少了一个字符的白名单」，而是**撇号是否词边界取决于上下文，代码却把它
  建模成了字符本身的属性**：`isScanStop(char)` 只看单个字符，撇号在 `don’t` 里是
  词内字符、在 `‘hello’ world` 里是引号，同一个码点两种角色。
- **[x] ① 已修复** — 给四份实现加上下文判据 `isIntraWordApostrophe(text, index)`：
  撇号（`'` / `’` U+2019 / `ʼ` U+02BC）两侧都是**空格分词类字母**时是词内字符，
  前向扫描跨过去、继续扫。字母集与
  `native/fushidicts/fushidicts_src/scan/word_scan.cpp` 的
  `is_space_delimited_letter` 逐区间对齐（拉丁/希腊/西里尔/亚美尼亚/希伯来/阿拉伯/
  格鲁吉亚），全仓一个模型，不新增语言开关——本 app **没有全局学习语言**，判据只能
  来自文本自身。

  **刻意不改词首回退**（`while (startOffset > 0 && !this.isScanBoundary(...))`）：
  回退跨撇号会把法语/意大利语省音写法（`l’homme`、`dell’arte`）的锚点从 `homme`
  拖回 `l’`，反而查不到 `homme`。前向跨过是纯增益——C++ `scan_candidates` 会生成
  `don’t` / `don’` / `don` 三级前缀，短词不会被挤掉；回退跨过是零和的锚点搬家。

  提交：见本分支 `fix/en-apostrophe-word-scan`。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/apostrophe_word_scan_bug2056_test.dart`
  + `.js`（沿用 BUG-1773 的 node:vm fake DOM 装置，**真执行**浮窗版
  `assets/popup/selection.js` 与阅读器注入脚本 `ReaderSelectionScripts.source()`
  两份实现）。12 条行为断言：三种撇号、所有格与空格桥接叠加、引号语义不变、
  法语省音锚点不回归、跨文本节点不粘、`rock 'n' roll` 左侧非字母不跨、maxLength
  仍截断、日文逐字扫描不变；外加源码守卫钉「桥接必须先于 `isScanStop`」与
  「词首回退整条 while 条件逐字不变」。

  变异实测（两次，均按唯一锚点还原并校验 sha256 复原）：
  ① 桥接改成 `if (false && ...)` → 行为测试红，报 `'don' !== 'don’t'`（正是本 bug 症状）；
  ② 桥接挪到 `isScanStop` 之后 → 顺序守卫红，报「撇号桥接必须**先于** isScanStop」。
- **备注**：本轮排查同时发现**统计域字数口径**对英语类语言的更大问题（英文按字母计、
  俄/韩/希腊/阿拉伯/泰整script计 0、带变音的拉丁字母不计），那是独立议题、独立改动面，
  未包含在本 bug 内。
