## BUG-4079 · 横幅（FushiInlineNotice）同行动作按钮停在横幅中间
- **报告**：2026-11-04（用户：应用内反馈 hIEGAdQjkL，同步与历史页「同步与备份 / Fushi 互联」按钮停在横幅中间；关联 3wg7wAlNZw）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_inline_notice.dart:247` 正文是 `Expanded`（flex 1），`:252-262` 动作组是 `Flexible`（flex 1，loose）包 `Wrap(alignment: end)`：Row 把剩余宽度对半分，Wrap 在 loose 约束下只撑到内容宽、`WrapAlignment.end` 不生效，正文被压到一半宽、按钮紧跟其后、右半边空着；是否同行只看写死的 `inlineActionsMinWidth = 600`（`:40`）。全仓约 53 处带 actions 的横幅都受影响。
- **[x] ① 已修复** — 组件层重写排布：新增 `_NoticeContentLayout`（自定义 RenderBox，图标 / 正文 / 动作组三槽）。同行时动作组按单行自然宽度（无界干布局量，RenderWrap 的 maxIntrinsicWidth 不计 spacing）封顶内容宽 45%（不窄于最宽按钮）贴右排，超出在该宽度内换行，正文吃掉其余全部宽度；自动模式按实测判断：让出动作组后正文还剩 ≥16em 才同行，否则落到正文下方。删掉 600 固定断点。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_inline_notice_layout_test.dart`：1560 宽按钮右边缘贴内边距、正文宽 > 一半；360 宽按钮落到正文下方；8 个按钮不溢出且全在横幅内；`actionsInline: true` 窄屏不溢出。
- **备注**：真机未复测（本轮不做）。
