## BUG-398 · 焦点高亮切界面残留+无导航键也出现

- **报告**：2026-06-22（用户：TODO-699）
- **真实性**：✅ 真 bug。两个根因都在 `hibiki/lib/src/shortcuts/gamepad_service.dart`：
  - **根因①（无导航键也出环）**：`_onKey`（原 `gamepad_service.dart:399-403`）对**任意**物理 `KeyEvent`（打字字母 / Esc / 快捷键 / 甚至 `KeyUp`）都调 `_setHighlightForHardwareNav()` → `FocusManager.highlightStrategy = alwaysTraditional`。焦点环可见性以 `highlightMode == traditional` 为判据，框架级 Material 焦点高亮（InkWell / ListTile / IconButton / `FocusableActionDetector` 回退）**不受** `experimentalFocusNavigationEnabled` gate，所以默认 build 第一次敲任意键就亮环。
  - **根因②（切界面残留）**：键事件只会把策略推成 `traditional`，从不复位；只有 pointer 事件（`_onPointerGlobal`）才复位 `alwaysTouch`。切到新页/新 tab 时落焦把上一页亮的环带到新页。
- **[x] ① 已修复** — 提交 `见分支 fix-699-focus-residue HEAD（合并 develop 后以入库哈希为准）`
  - 根因①：`_onKey`（`gamepad_service.dart:399-`）先判新增纯函数 `gamepadKeyDrivesFocusRing(event)`（`gamepad_service.dart:450`，`@visibleForTesting`）——只对方向键移动边（`arrowFocusMoveDirection != null`）或 Tab 按下边返回 true；其余键直接 `return false` 不翻 traditional。方向键若被聚焦文本框光标消费（`_arrowEditsTextCaret`，`gamepad_service.dart:459`，复用 `focusedEditableText()` + 左右键 / 多行上下键判据）也不翻——光标编辑不是焦点导航。
  - 根因②：新增 `GamepadService.resetHighlightForScreenSwitch()`（`gamepad_service.dart:417`）把策略复位 `alwaysTouch`。两条切界面入口接上它：
    - 路由 push/pop/replace：新增 `HighlightResetNavigatorObserver`（`gamepad_service.dart:477`），由 `AppModel.focusHighlightObserver`（`app_model.dart:537` 一带）实例化绑定 `gamepadService.resetHighlightForScreenSwitch`，挂进 `main.dart` 的 `MaterialApp.navigatorObservers`（`main.dart:838` 一带）。注：旧 `AppModel._routeObserver` 从未挂任何 Navigator（死代码），未复用以免改语义不明的字段。
    - 首页同 route 内切 tab（IndexedStack，无 push/pop，NavigatorObserver 看不到）：`HomePage._selectTab`（`home_page.dart:297`）在 `tab != _currentTab` 时直接调 `appModelNoUpdate.gamepadService.resetHighlightForScreenSwitch()`。
  - 未整体 gate `start()`：`start()` 里 `alwaysTouch` 初始化保留（抵消桌面默认 automatic），整体 gate 会改桌面默认行为。
- **[x] ② 已加自动化测试** — `hibiki/test/shortcuts/focus_highlight_residue_test.dart`（提交 `见分支 fix-699-focus-residue HEAD（合并 develop 后以入库哈希为准）`）
  - 纯函数 `gamepadKeyDrivesFocusRing`：字母 / 任意 KeyUp / Esc 返回 false（修前不存在=红）；方向键 KeyDown / KeyRepeat、Tab KeyDown 返回 true（防误杀导航出环能力）。
  - 端到端根因①：焦点落普通 Material 按钮，发字母 KeyDown 后断言 `highlightStrategy != alwaysTraditional`（修前红）；再发方向键断言变 `alwaysTraditional`（保留导航环）。
  - 根因②：`resetHighlightForScreenSwitch` 把 traditional 复位 touch；`HighlightResetNavigatorObserver` 在路由 push 与 pop 后都把 traditional 复位 touch（修前红）。
- **备注**：桌面真机焦点驱动复测建议补做（敲字母不出环、切 tab / 进退页环不残留、方向键 / Tab 仍正常出环）。Android 走原生 automatic 策略，本服务 no-op，不受影响。
