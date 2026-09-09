## BUG-2363 · 小说长按必须额外拖动才进入文本选择
- **报告**：2026-09-09（用户：「fushi小说长按选择有点太难按了，hoshi就很好按」）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/reader/reader_selection_scripts.dart:63-151, 1450-1490`。Hoshi Android 直接使用 WebView 原生文本选择，达到系统长按阈值便建立选区；Fushi 的自绘选择虽在 500ms 后定锚，却把「是否真的选择」继续绑定到额外位移：原地松手时 `endRangeSelection` 返回 false，手势层再调用 `selectText` 退回普通查词。用户必须按住后再拖过隐藏门槛才能得到选区，故明显比 Hoshi 难触发。
- **[x] ① 已修复** —— 长按阈值调为 400ms；`beginRangeSelection` 达阈值即建立并绘制锚点单字选区；`endRangeSelection` 对原地与拖动长按统一保留选区、显示起止手柄并弹「复制 / 查词」菜单，不再退回单击查词。继续拖动仍扩展自绘选区，阈值前移动超过 slop 仍交给滚动/翻页，图片、多指和手柄触摸边界不变。
- **[x] ② 已加自动化测试** —— 更新 `fushi/test/reader/reader_longpress_drag_select_guard_test.dart`、`reader_longpress_selection_menu_guard_test.dart`、`reader_selection_handles_guard_test.dart`，覆盖 400ms 默认阈值、达阈值即画选区、原地松手不回退查词、统一进入选区菜单，以及不复活原生双选区；连同 `reader_script_compactor_test.dart` 共 78 例通过，并由 Node 真解析压缩前后的注入 JS。
- **备注**：Android/iOS 真触屏 WebView 的原始长按体感与菜单位置仍需设备复测；自动化已验证生成脚本、注入装配与语义契约，但不能代替系统触摸栈 E2E。
