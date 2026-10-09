## BUG-3087 · 对话框 hero 图标底板被撑成满宽横条（选择句子上下文顶部的 99）
- **报告**：2026-10-09（用户 Android 截图：「制卡前调整 / 选择句子上下文」面板顶部一块黄色波浪，中间写着 99）
- **真实性**：✅ 真 bug，widget test 真实像素渲染复现。「99」是 `FushiIcons.quote`（Material Symbols `format_quote`）引号图标；
  黄色波浪是 M3E 9 瓣饼干底板。`AlertDialog` 把 icon 槽放在 `CrossAxisAlignment.stretch` 的 Column 里（scrollable 与否都是），
  宽约束是紧的；`FushiDialogHeroIcon`（`fushi/lib/src/utils/components/fushi_m3e_overlays.dart` build 末尾）裸 `SizedBox.square`
  被撑成「满宽 × size 高」，饼干形被横向拉成波浪条、图标缩在正中。所有经 `FushiAlertDialog` / 确认模板带 hero 图标的 M3E 对话框同病。
- **[x] ① 已修复** — hero 外包 `Center` 放松紧约束，底板回到 `size` 见方并居中。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_m3e_overlays_test.dart`「对话框 hero 图标底板保持见方（scrollable: false/true）」断言底板 48×48 且水平居中。改前改后真实像素截图见 PR。
- **备注**：用户同时提到「上下文显示有问题」，截图里前文 2 句 / 当前句 / 后文（无）与计数一致，未能定位具体问题，需用户补充。
