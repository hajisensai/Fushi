## BUG-4127 · 竖排点「↓」符号查出列首「顔」（未复现，缺原书 DOM）
- **报告**：2026-10-28（反馈 B6v1fGHuVB，开发者本人在 QQ 群报，Windows 桌面，reader_fushi 竖排 EPUB《安達としまむら3》：点「顔の上が↓で、」这一列下部的「↓」符号本身，查词弹窗查出这一列开头的「顔」，「顔」被高亮。期望：点符号查不到词就不查，或按最近的可查字命中，绝不跳到列首）
- **真实性**：❌ 未复现（沿真实 JS 命中链在真 Chrome 里逐种构造 DOM 实测，没有一种「点符号本身」会落到列首；缺原书 XHTML，定不了「↓」的真实结构）。
- **[ ] ① 未修复** — 复现不了，不改代码。
- **[ ] ② 未加自动化测试** — 留了可复用探针 `tool/reader_pitch_headless/selection_symbol_hit_probe.mjs`，拿到原书 DOM 后直接喂给它。
- **备注**：

### 查过的命中链（`fushi/lib/src/reader/reader_selection_scripts.dart`）

点击 → `selectText`（:3290）→ `getCharacterAtPoint`（:2471，`isScanBoundary` 剔除）→
`getSelectableCharacterAtPoint`（:2478）→ `getCaretRange`（:2343：`caretPositionFromPoint` 只认文本节点；
否则 `elementFromPoint` 所在块内两遍逐字扫描，第二遍容差 = 半个字；都落空才回落 `caretRangeFromPoint`）→
**几何复核**（:2486-2507：caret 及其前后一字，字形矩形外扩 0 / 6px 必须盖住落点且可见，否则 null）→
`selectionStartFor`（:3361，查词起点归一）→ `selectFromPosition` 前向扫描 → 高亮。

关键点：几何复核是查词起点的唯一收口，caret API 不论把点 clamp 到哪个节点 / 偏移（含列首文本节点 offset 0），
只要那个字的矩形离落点超过 6px 就被丢弃。所以「caret 回落到父节点首个文本节点 offset 0」这条假设**本身不会**
让列首字成为起点。能把起点挪离被点字的只有 `selectionStartFor`：非日文字符回退到词首（遇日文即停），日文字符在
`<ruby>` 基字里吸附到该 ruby 段首（chj2rZn89F 的设计）。

### 实测（headless Chrome 156，`selection_symbol_hit_probe.mjs`，单栏与 `MC=1` 多栏结果逐项相同）

| 「↓」的构造 | 结果 |
|---|---|
| 纯文字（同一文本节点 / 自带元素 / text-combine-upright / text-orientation:upright / inline-block / ruby 基字 `<ruby>↓<rt>した</rt></ruby>`） | 起点 = 「↓」，查询串「↓で」 |
| gaiji `<img>`（裸放 / 包 span / 在 ruby 里）、inline `<svg>`、`::before` 生成内容、点在 `<rt>↓</rt>` 上 | 不查词（onTapEmpty）；点在 img 偏「が」「で」一侧的半格内命中最近的那个字 |
| **U+FFEC「￬」（半角下箭头，属 `FULLWIDTH_CHARACTER_RANGES` 判为日文）放在以「顔」开头的多字 ruby 基字里** | 起点 = 「顔」（ruby 段首吸附），查询串「顔の上が￬で」 |

唯一能复现症状的是最后一种，而那是 ruby 吸附的既定语义：同一列里点「上」「が」也会跳到「顔」，与开发者
「点普通字是否正常」尚未回答的问题对不上；原书是否真有这种 ruby 无从确认，所以不据此改 ruby 吸附。

### 缺什么

- 原书那一页的 XHTML（「顔の上が↓で、」所在段落，含外层 `<ruby>` / `<span class>` / gaiji `<img>` 及其 CSS），
  或在用户机器上对 WebView2 做 CDP：读 `document.caretPositionFromPoint(x,y)` 与 `fushiSelection.selection`。
- 点这一列普通文字是否正常（区分「符号特有」与「整列 ruby 吸附」）。
- 反馈机器人把截图里的红色标注箭头也可能读成了正文「↓」，需原书确认正文里到底有没有这个符号。

拿到后：`node tool/reader_pitch_headless/selection_symbol_hit_probe.mjs page.html`（被点元素标 `id="t"`），
看 `selectionStart` 是否为「顔」、经过的是哪一层，再按根因修并把该 DOM 写成回归测试，三种 view mode
（paginated / continuous / vn 共用同一份 `fushiSelection`）各跑一遍。
