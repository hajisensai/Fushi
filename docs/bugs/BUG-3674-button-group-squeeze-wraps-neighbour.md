## BUG-3674 · button-group-squeeze-wraps-neighbour
- **报告**：2026-10-22（用户：反馈 orCq_DE1i7「选中右边按钮的时候，左边的按钮竟然会被挤小，类似的问题全修复」，Windows 两张截图：自定义主题 hero 按下「⋯」时「分享主题」折成两行）
- **真实性**：✅ 真 bug。MD3 标准按钮组 `FushiButtonGroup` 的排布 `_RenderFushiSqueeze._widths`（`fushi/lib/src/utils/components/glass/fushi_expressive.dart`）把被按下按钮的增宽 `growFactor * base * p` **无条件**从相邻按钮扣除；按自然宽排布的组（基准宽 = 各自 max intrinsic width，零富余）里邻居因此被压到比单行宽还窄，文字折行、按钮高度跳变。全仓所有 `FushiButtonGroup` 用法（自定义主题、设置行、播放器、下载、texthooker、番剧日历等 11 处）同源。
- **[x] ① 已修复** — 邻居只让出「当前宽 − 单行固有宽」的富余，按下按钮的增宽取 min(期望增宽, 邻居富余之和)、按富余比例分摊：自然宽的组按下不再挤压邻居（只剩按钮自身形变），撑满整行 / 有富余的组照常挤压但永不折行。组件层一处修，全部用法受益。提交 `6d18da515e`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_button_group_squeeze_test.dart`：自然宽组按下右键左键尺寸不变；撑满组邻居让宽但 ≥ 单行宽且不折行；恰好撑满的组不挤。
- **备注**：Apple 设计系统下本就不挤压（growFactor 0），不受影响。
