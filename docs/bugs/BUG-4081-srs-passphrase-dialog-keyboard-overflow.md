## BUG-4081 · 复习数据位置「开启加密」口令弹窗键盘弹出后内容被裁
- **报告**：2026-11-04（用户：应用内反馈 TfvowyuJ15，Android，键盘弹出后弹窗下半部分没跟着动）
- **真实性**：✅ 真 bug（溢出路径由测试坐实；截图不含键盘，重绘残影这一支未能排除）。`fushi/lib/src/pages/implementations/srs/srs_history_page.dart` 的口令弹窗说明很长、加两个口令框，`FushiAlertDialog` 未传 `scrollable`（默认 false，`fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart:533/572`），键盘占掉一半高度后不可滚的内容区溢出，第二个口令框与确认按钮被挤出可见区。
- **[x] ① 已修复** — 弹窗改 `scrollable: true`（标题与内容一起滚，聚焦框由 EditableText 滚进视野，动作固定在底部）；类改为公开的 `SrsPassphraseDialog` 以便测试。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_passphrase_dialog_keyboard_test.dart`：360×740、键盘 320 下打开加密弹窗，无溢出异常，聚焦第二个口令框后它与确认按钮都在键盘上方。
- **备注**：Android 真机 / 模拟器未复测（本轮不做）。全仓其它带输入框的 FushiAlertDialog 是否统一默认 scrollable 未在本次处理。
