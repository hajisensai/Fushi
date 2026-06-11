## BUG-196 · 焦点导航/音量键开关未真正 gate 输入（Tab 仍遍历 + 音量键出焦点框）
- **报告**：2026-06-11（用户：没开音量键功能、开了键盘/手柄焦点导航，进书查过一个词后按音量键仍出现焦点框；电脑端没开焦点导航，按 Tab 仍有动作）
- **真实性**：✅ 真 bug（两个独立症状，根因都是「开关没真正 gate 住对应输入 handler」）。

  **症状2（电脑 Tab）根因**：`LogicalKeyboardKey.tab` 在全 app 没有任何自定义处理——Tab 遍历是 Flutter `WidgetsApp` 内建的 `NextFocusIntent`/`PreviousFocusIntent`，与实验性「键盘/手柄焦点导航」总开关 `AppModel.experimentalFocusNavigationEnabled`（`hibiki/lib/src/models/preferences_repository.dart:175`）完全解耦。`hibiki/lib/main.dart:791-799` 在开关关闭时不挂 `HibikiFocusRoot`/`HibikiFocusRing`，但没有任何东西禁用 Flutter 内建 Tab → 关掉开关 Tab 照样在控件间跳焦点。

  **症状1（安卓音量键出焦点框）根因**：音量键经 native `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java:dispatchKeyEvent` 处理，旧实现仅当 `volumeKeyIntercept==true`（「音量键翻页」开启）才吞掉音量键，否则 `return super.dispatchKeyEvent(event)`。Android 的 `super.dispatchKeyEvent` 会**先**把 VOLUME_UP/DOWN 分发给 view 树（含 FlutterView），**再**由 `Activity.onKeyDown` 调音量。漏进 Flutter 的音量键 KeyEvent 进入 `FocusManager._HighlightModeManager.handleKeyMessage`（Flutter 框架 `focus_manager.dart:2206-2222`：除虚拟键盘 backspace 外，**任何** key message 都把 `_lastInteractionRequiresTraditionalHighlights=false` → `updateMode()` → automatic strategy 下切到 `FocusHighlightMode.traditional`）。highlightMode 一旦切到 traditional，阅读内容焦点环（`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1312-1316`，`show = _focusNavEnabled && _focusNode.hasPrimaryFocus && _caretSurface==none && highlightMode==traditional`）以及 app 级 `HibikiFocusRing`（`hibiki/lib/src/utils/components/hibiki_focus_ring.dart:152/169/176`）就画出焦点框。即「音量键翻页」关闭、用户纯触摸阅读，音量键也会污染 highlight mode 出现焦点框——音量键根本不是焦点导航输入。

  **为何不能在 Flutter 层吞**：`HardwareKeyboard.addHandler` return true **无法**阻止 `keyMessageHandler`（Flutter `hardware_keyboard.dart:1210` 无条件求值 `_dispatchKeyMessage`）；`addEarlyKeyEventHandler` 在 `handleKeyMessage` 内、切 mode 之后才跑（`focus_manager.dart:2210` 在 2233 之前）。唯一能阻止音量键切 highlight mode 的层是「不让音量键进 Flutter 引擎 key pipeline」= **native 层拦住**。
- **[x] ① 已修复** — 根因修，两处：

  **症状2**：`hibiki/lib/src/shortcuts/global_navigation.dart` `wrapWithGlobalNavigation` 的 shortcuts map 在 `focusNavigationEnabled==false` 时把 `Tab` / `Shift+Tab` 中和成 `DoNothingIntent`（与裸空格同范式）。本 `Shortcuts` 在 MaterialApp.builder child 内，比 `WidgetsApp` 默认 shortcuts 更靠近焦点节点，故先匹配、阻断内建 Tab 遍历冒泡。开启时不加，Flutter 原生 Tab 遍历照常。文本框输入不受影响（Tab 在文本框本就是焦点遍历键，不插入制表符）。

  **症状1**：`hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java` `dispatchKeyEvent` 把音量键判定提到最前，**拦截开/关两态都 return true、永不调 `super.dispatchKeyEvent`**——音量键永不进 FlutterView，highlight mode 不被污染。拦截 ON：ACTION_DOWN 转发 Dart 翻页、吞掉（行为不变）；拦截 OFF：新增 `adjustSystemVolume()` 用 `AudioManager.adjustSuggestedStreamVolume(USE_DEFAULT_STREAM_TYPE, FLAG_SHOW_UI)`（标准「等价硬件音量键」API：系统挑活动流 + 显示音量滑条）自行调音量。系统调音量行为对用户无差异。

  提交：`68926c9d6`
- **[x] ② 已加自动化测试** —
  - `hibiki/test/shortcuts/global_tab_gated_test.dart`（症状2 行为单测）：关闭焦点导航→Tab/Shift+Tab 不移动焦点（停在原控件）；开启→Tab 照常移到下一控件。撤修复（不中和 Tab）即红（实测红：关态 first→second）。
  - `hibiki/test/platform/android_volume_key_focus_guard_test.dart`（症状1 源码守卫，host 无法注入真实 Android 音量键 KeyEvent 到 FocusManager）：断言 native 关态用 `adjustSuggestedStreamVolume`/`USE_DEFAULT_STREAM_TYPE`/`FLAG_SHOW_UI` 自调音量、音量键分支在 `super.dispatchKeyEvent` 之前且吞掉事件。撤修复（恢复旧 native）即红（实测红）。
  - `flutter analyze` 0 issues；`flutter test test/shortcuts test/platform` 全绿（233+ 例）；`flutter build apk --debug --target-platform android-arm64` 成功（native Java 编译通过）。
- **备注**：开关**开**时不回归——症状2 开启 Tab 遍历测试绿；症状1 拦截 ON 路径（音量键翻页 / 有声书句子导航）转发 Dart 行为字面不变（仅把 `volumeKeyIntercept` 分支移到统一音量键判定内，ACTION_DOWN 转发逻辑一致）。**残留风险（真机未验，留用户）**：①安卓音量键关态自调音量需真机确认音量滑条与系统默认体验一致、且 reader 不再出焦点框；②安卓「音量键翻页」开启时翻页仍正常；③桌面 Tab 关态不动、开态正常。host 单测覆盖逻辑契约，真实 Android KeyEvent → FocusManager 链路与系统音量调整只能真机复测。
