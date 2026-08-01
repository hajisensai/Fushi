## BUG-1347 · 关词典鼠标键在查词弹窗表面无效（Windows 指针所有权）

- **报告**：2026-08-01（用户转述其用户反馈：「关词典快捷键鼠标键无效，键盘键第一层有效嵌套窗口无效」）
- **真实性**：✅ 真 bug（鼠标那一半）。根因不在 BUG-1269 那座 JS 桥的逻辑，而在**指针根本没到过弹窗 DOM**：
  - `packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart:54`
    `enum PointerButton { none, primary, secondary, tertiary }` —— **没有侧键**。
  - 同文件 `_getButton()`（:62）把 `kBackMouseButton` / `kForwardMouseButton` 落进 `default` → `PointerButton.none`。
  - `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:2005`
    native 侧 `setPointerButtonState` 的 `default` 合成 `kind = 0`（不是任何合法的
    `COREWEBVIEW2_MOUSE_EVENT_KIND`）再照发不误。
  - 于是 Windows 上鼠标**侧键**在到达 WebView2 之前就被整条丢弃：弹窗 DOM 里根本不会发生
    `mousedown`，BUG-1269 装的桥永远拿不到 `Mouse3`/`Mouse4`。绑到侧键的「关闭词典」在弹窗表面
    **从来没有可能**生效——而点词后弹窗恰好贴在光标旁，那正是用户按键时指针所在的位置。

  为什么不是「把侧键补进 fork 让它进 WebView2」：那会顺带打开 Chromium 的「侧键 = 历史后退」
  默认行为，而阅读器正文 WebView 换章有真实历史，会乱跳（拿一个回归换一个修复）。真正的
  不变量是**指针所有权**：Windows 的 WebView2 是无窗口 composition 模式，指针本来就先到
  Flutter、再由 fork 逐个转发进去——第一手拥有者是宿主，那就由宿主分发，不必送进 WebView 再绕回来。

- **[x] ① 已修复** — 按指针所有权分流，两条路径互斥：
  - `hostOwnsDictionaryPopupPointerInput`（Windows）为真时，`DictionaryPopupLayer` 在整层最外层挂
    只旁听不消费的 `Listener`，把命中 `inputSpec` 的鼠标按下折成与 JS 桥**完全同形**的 token
    （`Mouse<n>`），汇进同一个 `onHostInputToken` → 同一个 `resolveDictionaryPopupInputToken` →
    同一个宿主落地入口（没有第二套语义）。
  - 同一平台下 `dictionaryPopupInputBridgeScript` **不装**鼠标监听、连按钮表也下发空的，
    否则中键/右键会被两条路各触发一次（关词典幂等看不出来，漫画翻页会翻两页）。
  - Android / iOS / macOS / Linux 的 WebView 是真原生视图、指针被它直接吃掉，Flutter 收不到，
    故仍走弹窗内的 JS 桥（行为零变化）。
  - 按钮折叠规则（`buttons` 位掩码 → 单个 DOM `MouseEvent.button`）从设置页录制那份私有实现
    提升为共享的 `domMouseButtonFromPointerButtons`（`shortcuts/input_binding.dart`），录制与
    运行时分发共用一份，杜绝「录到侧键、运行时按另一个号解析」。
  - `webViewKeyBridgeScript` 的断言放宽：空键表 + 不装鼠标监听是**合法**的清表注入
    （热槽 WebView 跨查词长期存活，靠注入空 spec 清掉残留旧表），原断言会把它打成断言失败。
  - 提交：见本分支 `worktree-dismiss-dict-input-windows`。

- **[x] ② 已加自动化测试** — `hibiki/test/pages/dictionary_popup_pointer_input_test.dart`（12 例）：
  token 折叠（侧键命中 / 未绑 / 左键永不可绑 / 空 spec）、注入脚本与所有权互斥（宿主拥有指针时
  既无 `mousedown` 监听、按钮表也空；WebView 拥有指针时两者都在）、以及 widget 级真指针注入
  （`DictionaryPopupLayer` 上按侧键 → 宿主收到 `Mouse3`；所有权翻转 → 一个 token 都不收）。
  平台判据经 `debugHostOwnsPointer` 注入，**不读运行平台**——否则同一份守卫在 Windows 与
  Linux CI 上测的不是同一件事。已两次变异实测：翻转所有权门（红 2 例）、`installMouseListeners`
  恒 true（红 1 例），各自还原后复绿。
  连带修：`test/focus/webview_key_bridge_behavior_test.dart` 显式声明 `hostOwnsPointer: false`
  （它验的是弹窗内 JS 桥本身），否则在 Windows 上会随新默认值变红、在 CI 上却绿。

- **备注**：用户报告的**键盘那一半**（「第一层有效、嵌套窗口无效」）**本条未修**，只查清了边界：
  Windows 上 WebView2 是无窗口 composition 模式，且 fork 全仓**没有任何 `SendKeyboardInput` /
  `MoveFocus` 调用——弹窗 DOM 永远收不到 `keydown`，即 BUG-1269 键盘桥在 Windows 上是死代码
  （`reader_hibiki/caret.part.dart:134` 的 BUG-402 注释早就写明「fork 只转发鼠标不转发键盘」）。
  那里的键盘只能走 Flutter 焦点链（`Focus(onKeyEvent: _handleKeyEvent)` 在弹窗层的祖先，
  KeyEvent 理应冒泡到达），所以「第一层有效、嵌套无效」的断点尚未定位，需要真机/离屏复现
  才能确定是焦点链被谁消费、还是报告来自 Android（那里桥是活的）。反馈里没有平台与绑定信息。
