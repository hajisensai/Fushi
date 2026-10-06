## BUG-3037 · 共享尺寸动画在减弱动态效果下布局重入且切换偏好可能丢子树状态
- **报告**：2026-10-06（PR #1984，CC 提示共享零时长尺寸动画调用点）
- **真实性**：✅ 真 bug（静态路径确认）。`fushi/lib/src/media/audiobook/asr_models_settings_section.dart:438`、`fushi/lib/src/media/manga/extension_management_tile.dart:174` 等把减弱动态效果后的零时长传给 SDK `AnimatedSize`；尺寸变更时 `RenderAnimatedSize._layoutStable` → `_restartAnimation` → `forward(from: 0)` 在布局中同步 `markNeedsLayout`，与 BUG-3022 / BUG-3025 / BUG-3031 同根因。简单在 SDK 动画与裸 child 间切换还会更换 child 的 Element，丢失未保存输入等 State。
- **[x] ① 已修复** — 新增 `FushiAnimatedSize`：零时长直接对齐布局，正常动画交 SDK；共享 GlobalKey 只包 child，在动效分支切换时保留同一 Element / State。迁移 ASR 模型、扩展管理行、settings_shared、settings_kit、floating_chrome 五文件七处。提交见本文件 Git 历史。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_animated_size_test.dart` 验零时长即时扩缩 / 无异常、非零中间帧 / onEnd、动画中切换及恢复时保留 Element / State / TextEditingController；`fushi/test/build/animated_size_guard_test.dart` 验源码扫描词法与精确 owner + duration 表达式 + 次数棘轮。
- **备注**：本轮并未迁移全部调用；基线 a9576e38506 扣掉七处后仍有 58 处裸调用（包含已有保护的调用），明确作为存量记录，不声称全清。零时长分支没有动画完成事件，不调用 onEnd；正常动画保留 SDK 完成回调。按用户决定验证交 CI，无本地 heavy 测试；新增测试尚待执行、设备复测待补。未放宽已有断言或添加 skip。
