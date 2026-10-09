## BUG-3087 · 对话框 hero 图标底板被撑成满宽横条（选择句子上下文顶部的 99）
- **报告**：2026-10-09（用户 Android 截图：「制卡前调整 / 选择句子上下文」面板顶部一块黄色波浪，中间写着 99）
- **真实性**：✅ 真 bug，widget test 真实像素渲染复现。「99」是 `FushiIcons.quote`（Material Symbols `format_quote`）引号图标；
  黄色波浪是 M3E 9 瓣饼干底板。`AlertDialog` 把 icon 槽放在 `CrossAxisAlignment.stretch` 的 Column 里（scrollable 与否都是），
  宽约束是紧的；`FushiDialogHeroIcon`（`fushi/lib/src/utils/components/fushi_m3e_overlays.dart` build 末尾）裸 `SizedBox.square`
  被撑成「满宽 × size 高」，饼干形被横向拉成波浪条、图标缩在正中。所有经 `FushiAlertDialog` / 确认模板带 hero 图标的 M3E 对话框同病。
- **[x] ① 已修复** — hero 外包 `Center` 放松紧约束，底板回到 `size` 见方并居中。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_m3e_overlays_test.dart`「对话框 hero 图标底板保持见方（scrollable: false/true）」断言底板 48×48 且水平居中。改前改后真实像素截图见 PR。
- **[x] ③ 续（同 PR 追加）** — 底板变正后中间仍是像「99」的引号字形，用户照样看不懂。M3 对话框的顶部图标是可选项，只建议用于需要强调的提醒类对话框，而且有图标时标题要居中；这个对话框的标题区是「小标题 + 大标题 + 关闭 X」左对齐、正文是一叠句子卡，图标既不提供信息，又会把大标题拉成居中、和左对齐的小标题错位。所以**去掉**顶部 hero 图标，不换成别的图标。
  ±上下文四颗按钮在 360dp 宽时文字被截：前文 / 后文以前各占半宽，每半区再挤两颗，英文「Remove previous」等折成两行后，第二行被 XS 档固定 32 高的胶囊裁掉。改成每个方向一行、两颗等宽（`IntrinsicHeight` 同高），并放开 XS 档的最大高度：放得下时单行，放不下时在按钮里折行、按钮跟着长高，不截字。
  测试：`fushi/test/pages/sentence_context_dialog_layout_test.dart` 在 360dp 宽下，中英两种语言分别断言四颗按钮的文字都在按钮框内、没有 maxLines 截断，且没有 hero 图标。
- **备注**：用户同时提到「上下文显示有问题」，截图里前文 2 句 / 当前句 / 后文（无）与计数一致，未能定位具体问题，需用户补充。
