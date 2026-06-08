## BUG-123 · 竖排查词高亮溢出到振假名列(双重高亮)

- **报告**：2026-06-08（用户：截图显示竖排书查词时高亮“双重显示”）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/reader/reader_content_styles.dart:283`（`ruby.hoshi-selection-ruby-active` 把背景画在整个 `<ruby>` 元素上）。

### 根因

BUG-110 为消除竖排 `::highlight` 对 `<ruby>` 基字盒的“双绘深色带”，改成给 `<ruby>` 元素加
class `hoshi-selection-ruby-active`、背景画在元素上只画一遍。但 `<ruby>` 元素的盒子**同时
包含基字列与振假名(`<rt>`)列**：竖排下 `<rt>` 在基字右侧另起一列，横排下在基字上方另起一行。
于是高亮背景连振假名列/行一并涂上，使带 ruby 的字（如「颯爽」）高亮块比相邻无 ruby 的字
（如「と」）更宽/更高 → 视觉上像“双重高亮”。普通文字走 `::highlight(hoshi-selection)` 只涂
基字列，二者不一致。

无头 Chromium（同 Chromium 引擎）三栏对照复现确认：
- 现状（ruby 整块）：「颯爽」高亮带延伸进「さっそう」振假名列，比「と」宽（= 用户所见）。
- 修复（rt 遮罩）：「颯爽」高亮带只覆盖基字列，与「と」同宽。
- 横排同理：现状把振假名行也涂上（带更高），修复后与「と」同高。

### 修复

给选区高亮的 active `<ruby>` 的 `<rt>/<rp>` 子元素涂上**不透明阅读器背景色**
(`colors.backgroundColor`)，遮住从 `<ruby>` 元素背景透上来的高亮 tint，使高亮只剩基字列。
保留 BUG-110 的元素 class 方案（不回退到会双绘的 `::highlight`），不破坏其守卫。

只改查词选区高亮（`hoshi-selection-ruby-active`）；有声书跟随高亮
（`hoshi-sasayaki-ruby-active`）是整句长带，振假名留 tint 反而连续，不在本次范围。

- **[x] ① 已修复** — `reader_content_styles.dart` 新增 `ruby.hoshi-selection-ruby-active > rt/rp { background-color: <bg> }`（提交见下）。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/ruby_highlight_guard_test.dart` 追加守卫：选区 active ruby 的 rt/rp 必须用阅读器背景色遮罩。
- **备注**：采番 122 因 worktree 基于 origin/develop（缺本地未 push 的 BUG-122 PGS），改用 123 避撞。
