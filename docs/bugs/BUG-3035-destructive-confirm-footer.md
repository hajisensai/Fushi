## BUG-3035 · 通用删除确认框勾选披露后动作区滚出矮窗口
- **报告**：2026-10-06（PR #1984 CC reader 提交 `51130cb22a5` 明确记录 800×600 下展开删除披露后 footer 滚出确认框；Codex 独立审查调用链确认遗漏）
- **真实性**：✅ 真 bug（CC 记录的运行现象与静态路径交叉确认；本轮未自行运行复现）。`fushi/lib/src/utils/components/fushi_destructive_confirm_dialog.dart:169` 原为默认可滚的外层 `FushiDialogFrame(maxHeightFactor: 0.74)` 包默认不滚的 `FushiModalSheetFrame`，勾选展开披露说明后，动作随整个框滚到视口外。合集详情经 `collection_detail_shared.dart:141` 调用此组件，视频 BUG-3028 所修的 `showDeleteScopeConfirm` 不覆盖它；仅把合集功能测试窗口增高到 1200 不能修复生产矮窗口。
- **[x] ① 根因修复** — `8eb4e10efe4`：外层 `scrollable: false`，内层 sheet `scrollable: true`，仅正文滚动，取消/确认固定在面板内。
- **[x] ② 自动化测试已加入** — 同提交 `fushi/test/widgets/fushi_destructive_confirm_dialog_test.dart` 新增 800×600 用例，真实勾选“连同其中的书一起删除”展开生产披露正文；确认正文确有滚动范围，滚动前后 DELETE 均可命中且矩形位置不变，最后真实点击并断言返回 checked=true、deleteLocalFiles/deleteStatistics=false。旧业务断言未放宽。
- **备注**：format 与 `git diff --cached --check` 已完成。用户要求收尾验证交 CI，本轮不排本机 heavy 队列；测试和全量 analyze 等待合入后的 CI，未宣称新测试已运行通过。
