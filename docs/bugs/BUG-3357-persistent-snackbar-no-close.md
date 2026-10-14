## BUG-3357 · 带动作的提示条常驻且没有关闭按钮，只能横滑关
- **报告**：2026-10-14（用户：反馈 9WaqDjw84y，Windows，「这个提示没办法关闭，滑动关闭一般人想不到」，截图是反馈中心底部「开发者更新了 19 条你的反馈 / 查看」）
- **真实性**：✅ 真 bug。`material_ui` 的 `SnackBar` 构造里 `persist = persist ?? action != null`（带动作即常驻、不自动消失），而 `showCloseIcon` 默认 false；共享组件 `FushiSnackBar`（`fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart:3555`）没有补关闭入口，于是所有带动作的提示条（如 `feedback_common.dart` 的 `showFeedbackReplyNotice`）都只能横滑关掉。
- **[x] ① 已修复** — 组件层修：`FushiSnackBar` 判 `persist && showCloseIcon != true` 时自动补关闭按钮（MD3 画在动作槽里动作之后，Apple/玻璃画在胶囊内动作之后），点了 `hideCurrentSnackBar(reason: dismiss)`。提交 d8830baef6（分支 `cc/fb-misc-ui`）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_glass_overlays_test.dart`（两套设计各一条：关闭按钮存在、玻璃下在胶囊内、点了收起；`persist: false` 不加按钮）。
- **备注**：
