## BUG-934 · 前加一句制卡把当前句重复采集两遍
- **报告**：2026-07-20（用户：制卡时同一句原文出现两遍，怀疑「前加一句」导致）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/reader/reader_selection_scripts.dart:750`（`getSurroundingSentences` 往前取句的偏移 off-by-one）
- **[x] ① 已修复** — `getSentenceContext(before.node, before.offset + 1)` → `before.offset`（提交 <PENDING>）
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/reader/prev_sentence_context_offset_guard_test.dart`（提交 <PENDING>）
- **备注**：

### 根因

阅读器制卡的「调整上下文 → 前加一句」走 JS `hoshiSelection.getSurroundingSentences(prevCount, nextCount)`
（`reader_selection_scripts.dart:725`）。往前逐句采集时：

```js
var anchorOffset = current.sStartOffset;          // 当前句句首
var before = this.charBefore(anchorNode, anchorOffset);  // → offset = sStartOffset - 1
var ctx = this.getSentenceContext(before.node, before.offset + 1);  // ← BUG
```

`charBefore(node, offset)` 返回 `offset - 1`（`:957`），所以 `before.offset` 正好是「当前句首的前
一个字符」——即前一句末尾的分隔符（或 trailing）。但取句时又 `+ 1`，把起点推回到 `sStartOffset`
（当前句句首）。`getSentenceContext` 从当前句首往前立刻撞到分隔符（partsBefore 为空）、往后取到当前
句末尾，于是**返回的「前一句」其实是当前句本身**。

`MiningSentenceDraft.composeText`（`hibiki/lib/src/media/audiobook/mining_sentence_draft.dart:80`）
按 `prev + current + next` 合成，于是 `prev=[当前句] + current=当前句` → sentence 字段里同一句出现两遍。
`describe()` 计算的音频 normOffset 也一并取成当前句，导致合并音频区间同样重复当前句。

对照「后加一句」（`:768`）用 `getSentenceContext(after.node, after.offset)`（**不加 1**），对称且正确
——故只有用「前加一句」才复现，「后加一句」不会。这也和用户「怀疑是前加一句」的观察吻合。

与已归档的 BUG-660（重复两遍归因为浏览器扩展旧制卡队列残留）**不是同一根因**：BUG-660 是外部残留
队列，本 bug 是阅读器 JS 采句的 off-by-one，凡在 app 内用「前加一句」制卡即稳定复现。

### 修复

`reader_selection_scripts.dart:750`：`before.offset + 1` → `before.offset`。两种 `charBefore` 分支
（句内 `offset>0` / 跨节点跨段 `offset==0`）均验证过 `before.offset` 正确落在前一句内。

### 测试

`hibiki/test/reader/prev_sentence_context_offset_guard_test.dart`：源码守卫，断言
`getSurroundingSentences` 往前取句用 `getSentenceContext(before.node, before.offset)` 且不含
`before.offset + 1`，防止 off-by-one 回归（JS 逻辑内嵌在 Dart 字符串、无 JS 测试运行时，源码扫描是
最强可落地层）。
