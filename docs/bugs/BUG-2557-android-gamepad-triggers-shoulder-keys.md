## BUG-2557 · Android 手柄 LT/RT 扳机永不到达 app、LB/RB 整屏滚动无执行体、未绑定 X/Y 被系统兜底成退格/空格
- **报告**：2026-09-16（用户：「安卓的 xbox 的肩键和 lt 键没识别到，检查一下还有没有其他键是有问题的」「好像是捕获阶段有问题」）
- **真实性**：✅ 真 bug（三个独立根因，Android 专有；桌面轮询路径不受影响）

### 根因 A：LT / RT 在 Android 上是模拟轴，Flutter 引擎把摇杆 MotionEvent 整个丢掉

Xbox 手柄在 Android 上的扳机不是按键：AOSP 全部 Xbox 键位布局
（`Vendor_045e_Product_{02fd,02e0,0b12,028e,02ea}.kl`）都把扳机映射成
`axis LTRIGGER / RTRIGGER`，无 vendor 布局时走 `Generic.kl`（`axis 0x0a LTRIGGER`、
`0x09 RTRIGGER`），从不产生 `KEYCODE_BUTTON_L2/R2`。而 Flutter Android 嵌入层
`AndroidTouchProcessor.onGenericMotionEvent`（引擎 jar 反编译核对）只处理
`SOURCE_CLASS_POINTER` 的 hover / scroll（action 7 / 8），摇杆轴事件直接返回 false、
不进 Dart。`MainActivity.java` 此前也没有 `dispatchGenericMotionEvent`。于是 LT/RT
在快捷键捕获区录不到、默认绑定的「首页上一 / 下一 tab」永远不触发。

D-pad 之所以能用，是框架自己的 `ViewRootImpl.SyntheticJoystickHandler` 在**没人消费**
摇杆 MotionEvent 时把 HAT 轴合成成 DPAD 键（source 沿用摇杆的）；因此新加的原生钩子
只能旁听、不能消费。

### 根因 B：Android 键事件链上 LB / RB 的整屏滚动没有执行体

默认表 `shortcut_defaults.dart` 把 `globalScrollPageUp/Down` 绑在 LB / RB。桌面轮询路径
有 `GamepadService._tryScrollPage` 兜底；Android 上手柄按钮由引擎送成 `gameButton*`
KeyEvent，走 `global_navigation.dart` 的 `wrapWithGlobalNavigation` 键链，其页面滚动
兜底 `_handleGlobalScroll`（`global_navigation.dart:396`）**只调
`_resolveGlobalKeyboardAction`**，从不按 global scope 解析手柄键。首页把 LB/RB 解析到
global scope 后 `_executeShortcutAction` 落 `default` 返回 ignored，冒泡到这里又被跳过——
首页 / 设置 / 统计页按 LB/RB 一律无反应。

### 根因 C：`Generic.kcm` 的手柄 fallback 不止 B 一个

BUG-1266 只吞了没人认领的 B（`gamepadBackMustBeSwallowed`，
`global_navigation.dart:329`），并写明「X/Y/LB/RB/扳机/Start/Select 没有 fallback」。
对照 AOSP `Generic.kcm` 原文这是错的：`BUTTON_X → fallback DEL`、`BUTTON_Y → SPACE`、
`BUTTON_START / THUMBL / THUMBR → DPAD_CENTER`、`BUTTON_SELECT → MENU`、
`BUTTON_MODE → HOME`；只有 L1/R1/L2/R2 与 D-pad 没有。没绑定的 X/Y 在聚焦的文本框里会
退格 / 打空格，Start / L3 / R3 会「确认」当前焦点控件。

- **[x] ① 已修复** — 提交 `66e6aa8e64`
  - A：新增 `fushi/android/app/src/main/java/app/fushi/reader/GamepadTriggerKeySynthesizer.java`：
    `MainActivity.dispatchGenericMotionEvent` 旁听摇杆 MotionEvent（返回值仍交给
    super，D-pad 合成不受影响），按设备解析扳机轴（LTRIGGER/RTRIGGER → BRAKE/GAS →
    仅单极的 Z/RZ；居中的 Z/RZ 是右摇杆，绝不当扳机），滞回阈值（按下 ≥ 0.5、抬起 ≤ 0.25）
    出边沿时经 `dispatchKeyEvent` 合成 `KEYCODE_BUTTON_L2/R2`（带手柄 deviceId、
    `SOURCE_GAMEPAD`、`BTN_TL2/TR2` 扫描码），走与物理 L2/R2 完全相同的键链；
    `onPause` 释放仍按住的扳机。
  - B：`_handleGlobalScroll` 在键盘未命中时按 global scope 解析手柄键（与
    `_handleGlobalToggleFullscreen` 同款），同一个 `executePageScroll`。
  - C：`gamepadBackMustBeSwallowed` → `gamepadSystemFallbackMustBeSwallowed`，吞
    B / X / Y / Start / Select / L3 / R3；A（DPAD_CENTER 确认）与 Mode（HOME）有意放行。
- **[x] ② 已加自动化测试** —
  - `fushi/android/app/src/test/kotlin/app/fushi/reader/GamepadTriggerKeySynthesizerTest.kt`
    （新增 7 例，JVM 单测）：五种 Xbox 布局的轴选择、BRAKE/GAS 别名、单极 Z 是扳机 /
    居中 Z 是右摇杆、滞回边沿、按下-保持-抬起恰一 DOWN 一 UP、无轴一侧静默。
  - `fushi/test/shortcuts/gamepad_android_shoulder_scroll_test.dart`（新增 5 例）：
    Android 键链 RB 下滚 / LB 上滚、按住重复沿继续滚、解绑后不滚、改绑到 RT 后
    `gameButtonRight2` 也滚、文本框聚焦时让位。
  - `fushi/test/shortcuts/shortcut_gamepad_capture_test.dart`（+1 例）：捕获区录得
    LB / RB / LT / RT 四个 `gameButton*` 键。
  - `fushi/test/shortcuts/gamepad_back_not_gated_test.dart`（改 2 例）：吞键边界改为
    B/X/Y/Start/Select/L3/R3 三边沿都吞，LB/RB/LT/RT/Mode 不吞。
- **备注**：模拟器（`hibiki_nav`，API 35 x86_64）端到端复测：用 uinput 建虚拟手柄
  （vendor 045e / product 0b13，系统落到 `Generic.kl`，Sources = KEYBOARD|GAMEPAD|JOYSTICK），
  从内核层发 `BTN_TL` 与 `ABS_BRAKE` 轴——见 PR 描述里的截图证据。用户真机
  （Xbox 手柄 + 手机）待用户复测。
