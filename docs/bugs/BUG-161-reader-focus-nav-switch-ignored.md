## BUG-161 · 阅读器键盘/手柄焦点导航不跟随「键盘/手柄焦点导航」开关
- **报告**：2026-06-08（用户：书籍里面的焦点没跟随设置的键盘/手柄焦点导航开关）
- **真实性**：✅ 真 bug。`experimentalFocusNavigationEnabled`（默认关闭）只在 `hibiki/lib/main.dart:680-684`（挂 `HibikiFocusRoot`/`HibikiFocusRing` + 全局 `wrapWithGlobalNavigation`）和 `hibiki/lib/src/shortcuts/global_navigation.dart:148-169`（全局手柄分发/方向键移焦/手柄 B 返回）被消费。但阅读器页面 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 全程不读这个开关：它自带的 WebView 字符光标焦点导航（hoshiCaret）挂在自己的 `Focus`（`:1228-1231 onKeyEvent: _handleKeyEvent`）+ `GamepadButtonIntent` action（`:1218-1227`）上，与开关解耦——
  - `_handleKeyEvent`（键盘 + 安卓手柄键事件 `:3689-3853`）：Enter/A 进 caret（`:3770-3773`、`_handleGamepadAKeyEvent :3855-3881`）、方向↓ 跳底栏焦点域（`:3780-3791`）全部无条件执行。
  - `_handleGamepadButton`（桌面轮询手柄 `:3894-3978`）：同样无条件做 caret 进入 + dpadDown 跳底栏。
  - 阅读器焦点环（`:1264-1298`）：不看开关。

  结果：开关关闭（默认）时，全局焦点导航没挂，唯独书里仍能用键盘/手柄字符光标查词 + 显示焦点环 + 方向键跳底栏。
- **[x] ① 已修复** — 根因修：新增 `_focusNavEnabled => appModel.experimentalFocusNavigationEnabled` getter（`reader_hibiki_page.dart`），把阅读器全部焦点导航分支门控在它上面：①手柄 A 处理 `_focusNavEnabled ? _handleGamepadAKeyEvent(event) : null`；②光标激活分支键盘/手柄两处 `if (_focusNavEnabled && _caretActive)`；③进光标 enter-trigger 把开关透传纯函数 `ReaderCaretRouter.isEnterTrigger{Keyboard,Gamepad}(…, focusNavEnabled: _focusNavEnabled)`（router 同步加 `focusNavEnabled` 参数，默认 true 不动旧调用）；④方向键↓/手柄 D-pad↓ 跳底栏均加 `_focusNavEnabled &&`；⑤阅读内容焦点环 `show = _focusNavEnabled && …`。关闭时回退到翻页/快捷键（阅读控制类不受影响），与全局 `wrapWithGlobalNavigation` 语义对齐。提交：`b0474fa22`
- **[x] ② 已加自动化测试** — `hibiki/test/shortcuts/reader_caret_router_test.dart` 新增行为单测（`focusNavEnabled:false → Enter/A 不进光标`，撤修复即红）；`hibiki/test/pages/reader_focus_nav_switch_static_test.dart` 新增源码守卫锁住 inline 焦点环/跳底栏/手柄 A/光标激活分支均门控在 `_focusNavEnabled`（焦点树/WebView 无法脱设备单测行为）。`flutter analyze` 0 issues，shortcuts 全套 181 绿 + reader caret 静态/wiring 绿。
- **备注**：用户裁定（2026-06-08）——开关关闭时只停焦点导航（光标查词/焦点环/方向键移焦/跳底栏/手柄移焦），保留翻页/快捷键等阅读控制类。**reader/WebView 类改完需真机/模拟器肉眼复测原始失败路径（开关关→进书→键盘/手柄不再进光标、无焦点环）——待用户设备验证。** 残留：桌面手柄轮询 `GamepadService.start()` 仍无条件启动，其 directional-focus 兜底在 dpad 无绑定时仍可能移焦（次要，且属「原生遍历」语义）；安卓手柄走 key-event 路径已完整门控。
