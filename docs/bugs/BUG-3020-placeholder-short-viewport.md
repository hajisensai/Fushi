## BUG-3020 · 紧凑错误状态图标与说明高度超过可用视口
- **报告**：2026-10-06（PR #1984 审查 W1-006；CI Nyaa 420×280 原始失败）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_placeholder_message.dart:149` 的固定图标与文本 Column 直接接受窗口剩余高度；多段错误说明、操作按钮和 padding 的总高度大于可用空间时 RenderFlex 溢出。
- **[x] ① 已修复** — 保留居中与最大文本宽度，外层改为纵向 SingleChildScrollView；小窗口和大字体可滚动查看完整说明与操作按钮，MD3/Apple 共用同一约束策略。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/fushi_placeholder_short_viewport_test.dart`：420×280、1/2 倍文本、MD3/Apple，检查无 Flutter 异常、滚动到重试且可真实点击。执行结果待定向运行。
- **备注**：未复测设备端 Nyaa 原始路径；不以 widget 覆盖代替真实设备验证。原 CI 证据在外部 pr-m3e-wave-1-unit-0-job.log。

- **PR #1984 本轮验证边界**：本机定向测试因 SDK 编译与租约排队过慢，按 integration owner 指令取消并交 CI 验证；本轮实际执行 0 项，无通过结论。未进行设备端布局复测。
