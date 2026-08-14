## BUG-1645 · 嵌套查词查不了英语单词（跨节点粘连成拉丁串）
- **报告**：2026-08-14（用户：截图两张——顶层查词框输入 `acrid` 正常出 Oxford/CED24/LDOCE5；在 エグい 的 Jitendex 释义里点同一个 `acrid` 触发嵌套查词，子卡「未找到搜索结果。」）
- **真实性**：✅ 真 bug。两侧规则叠加导致，均已实证：
  - `fushi/assets/popup/selection.js:385`（`selectFromPosition` 的续扫循环）跨文本节点续扫时**不认元素边界**，把相邻释义 `<li>acrid</li><li>pungent</li>` 粘成 `acridpungent`。用 node 在 fake DOM 里真跑该函数复现：`scanned text = "acridpungent"`。
  - `native/fushidicts/fushidicts_src/scan/word_scan.cpp:68`（`scan_candidates` 的 `boundary_ok`）出于「不在单词中间切」的**正确**规则，拒绝在两个空格分词类字母之间切分。用 MSVC 真编译该文件跑一遍：
    - `scan_candidates("acrid")` → `[acrid]`（顶层输入路径，命中）
    - `scan_candidates("acrid pungent")` → `[acrid pungent] [acrid]`
    - `scan_candidates("acridpungent")` → `[acridpungent]`（**切不出 `acrid`** → 词典无命中 → 未找到搜索结果）
  - 日语不受影响：CJK 不是空格分词脚本，任意码点处都可切，粘多了会被自然切掉——所以症状只在拉丁语系的注释文字上出现。
  - 同理，若某词典把多条释义渲染在**同一个文本节点**里（`;`/`,` 是 `scanDelimiters`），扫描会正常停住，所以「有的词典能点、有的不能」也解释得通。
- **[x] ① 已修复** — 修在 JS 侧（C++ 的「不在单词中间切」是对的，不能动）：新增 `crossesRenderBoundary(from, to)`，跨节点行走前判断两个文本节点之间有没有**渲染断点**——块盒/列表项等非 inline 盒边界，或 compact 释义模式下 `li::after { content: " | " }` 这种只存在于渲染树的生成内容分隔符。判据刻意用渲染盒而不是「两侧都是字母就断」：后者会打坏 `<b>ac</b>rid` 这类行内标记拆开的单词。
  **落点是全部两套取词引擎、四条行走**（app 里再没有第三套：扩展 content.js、漫画覆盖层、歌词模式、键盘手柄 caret 全部复用这两套的 `selectFromPosition`）：
  - `fushi/assets/popup/selection.js`（+ 两份扩展 vendor 镜像，共 3 份逐字节同步）：`selectFromPosition` 取词扫描、`getSentence` 前后两个方向的取句行走。
  - `fushi/lib/src/reader/reader_selection_scripts.dart`（阅读器正文引擎，独立维护的同构实现）：`selectFromPosition` 取词扫描、`getSentenceContext` 前后两个方向的取句行走。
  取句侧的语义：渲染断点等价于撞上换行符（而换行符本就在 `sentenceDelimiters` 里）——所以这不是新规则，是把已有规则补到 DOM 里没有换行文本节点的那些位置。
  `textBetween`（用户长按拖选跨句合并）**有意不加**边界：那是用户显式拖出来的范围，不该被块边界截断。
  提交：`worktree-fix-nested-latin-lookup` / PR #836。
- **[x] ② 已加自动化测试** — 两套引擎各一个 node 行为 harness + Dart wrapper（无 node 时 skip）+ 源码守卫：
  - `fushi/test/lookup/nested_latin_lookup_bug1645_test.{js,dart}`：真执行 `selection.js`，六个场景——相邻释义断开、compact `::after` 分隔符断开、`<b>ac</b>rid` 行内拆词仍能拼回、日语跨行内节点续扫不回归、取句不跨块粘连、行内拆开的句子仍能拼完整；外加三镜像源码守卫。
  - `fushi/test/reader/reader_selection_render_boundary_bug1645_test.{js,dart}`：把 `ReaderSelectionScripts.source()` **真实注入脚本**dump 到临时文件再用 node 执行（不是复制粘贴的副本），三个场景——嵌套块边界收手、行内连排仍拼接、句子提取在断点处收句。
  变异实测（两套各做一次）：摘掉 `crossesRenderBoundary` 调用后立刻红成 `actual: 'acridpungent'`，还原后 sha256 与变异前逐字节一致。
- **备注**：句子提取（`getSentence` / `getSentenceContext`）本轮已一并修（首轮曾留作缺口）。副作用是**制卡句子字段的行为变化**：此前一句话没有终止标点时会一路粘到下一个块里去，现在在块边界收住——这是修正不是回归，但值得在真机制卡时留意一眼。
