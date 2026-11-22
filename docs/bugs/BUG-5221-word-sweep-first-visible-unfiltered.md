## BUG-5221 · 只查日文时整句扫词卡在屏首英文段落，同屏日文扫不到
- **报告**：2026-11-22（2026-11-22 合并审查 HBK-AUDIT-232，PR #4130）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_word_sweep_scripts.dart:200` 的屏首回退 `_firstVisible` 直接拿光标的 `fushiCaret._firstVisibleStop()`（只排除空白）当锚，没过扫词自己的停靠点判据（`isScanBoundary`：空白 / 标点 / 「只扫日文」时的非日文字）。屏首是英文段落时锚落在英文上，建出的句子零停靠点；下次按键因「零停靠点」再走回退，又取到同一个英文字，永远扫不到同屏日文。
- **[x] ① 已修复** — `fushiCaret._firstVisibleStop(accept)` 接收可选过滤条件（`fushi/lib/src/reader/reader_caret_scripts.dart`），扫词把「可查字 + 可见」判据整个交给它，屏首第一个**可停靠**的字才是锚；无光标脚本时的自有遍历用同一个判据。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_word_sweep_behavior_test.js` ⑨（经 `reader_word_sweep_test.dart` 用 node 真执行 `source()`）：一屏英文段落在前、日文在后、无选区、只扫日文，连续两次取句都落在日文句并有 5 个停靠点；修复前断言失败（取到 `Hello world.`）。
- **备注**：真实 WebView 设备复测（paginated / continuous / vn）未做，待补。
- **后续**：2026-11-23 按拍板台 pr4141a 删除阅读器整句扫词（`reader_word_sweep_scripts.dart` 与其 JS 行为测试一并删除），`fushiCaret._firstVisibleStop` 的 `accept` 过滤参数只为扫词而加，随之去掉；本条不再适用。
