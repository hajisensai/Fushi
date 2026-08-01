## BUG-1347 · 关词典的鼠标键/快捷键在查词弹窗表面无效（Windows 指针与焦点所有权）

- **报告**：2026-08-01（用户转述其用户反馈：「关词典快捷键鼠标键无效，键盘键第一层有效嵌套窗口无效」）
- **真实性**：✅ 真 bug（两半都是）。**鼠标那一半**的根因不在 BUG-1269 那座 JS 桥的逻辑，而在**指针根本没到过弹窗 DOM**：
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

- **[x] ② 已加自动化测试** — `hibiki/test/pages/dictionary_popup_pointer_input_test.dart`（共 18 例，鼠标 12 + 键盘 6）：
  token 折叠（侧键命中 / 未绑 / 左键永不可绑 / 空 spec）、注入脚本与所有权互斥（宿主拥有指针时
  既无 `mousedown` 监听、按钮表也空；WebView 拥有指针时两者都在）、以及 widget 级真指针注入
  （`DictionaryPopupLayer` 上按侧键 → 宿主收到 `Mouse3`；所有权翻转 → 一个 token 都不收）。
  平台判据经 `debugHostOwnsPointer` 注入，**不读运行平台**——否则同一份守卫在 Windows 与
  Linux CI 上测的不是同一件事。已两次变异实测：翻转所有权门（红 2 例）、`installMouseListeners`
  恒 true（红 1 例），各自还原后复绿。
  连带修：`test/focus/webview_key_bridge_behavior_test.dart` 显式声明 `hostOwnsPointer: false`
  （它验的是弹窗内 JS 桥本身），否则在 Windows 上会随新默认值变红、在 CI 上却绿。

### 键盘那一半（「第一层有效、嵌套窗口无效」）—— 同一条 token 通道补齐

用户补充平台是 Windows 后定位到根因，**与鼠标那半同构**：Windows 上弹窗 DOM 永远收不到
`keydown`（fork 全仓没有 `SendKeyboardInput` / `MoveFocus`，BUG-1269 的键盘桥在该平台是**死代码**；
`reader_hibiki/caret.part.dart:134` 的 BUG-402 注释早写明「fork 只转发鼠标不转发键盘」），
所以键盘只能走 Flutter 焦点链——而**焦点链在浮层这里是断的**：

- 视频页（以及走 `dictionary_page_mixin` 的首页查词 / texthooker）把整棵浮层挂在**根 Overlay**
  （`video_hibiki_page.dart:188` / `:3943`，为了盖过 media_kit 全屏路由），而宿主的快捷键入口是
  **页面自己那层** `Focus(onKeyEvent:)`（`video_hibiki_page.dart:4592`）。
- 用户点弹窗里的词唤出嵌套层时，平台视图会把 Flutter 焦点请求过去
  （`custom_platform_view.dart` 的 `onPointerDown` → `requestFocus`）。此后 `KeyEvent` 沿
  根 Overlay → Navigator → App 冒泡，**永远到不了**宿主页面的 `Focus`。
- 第一层之所以有效，只是因为它是从页面里点出来的、焦点还留在页面上。
- 断的不只是关词典：焦点进浮层后**整条**宿主快捷键通道都失效（内层 media_kit 的 activator 表
  同样不在链上）。

**修复**：`DictionaryPopupLayer` 自己挂一层 `Focus(canRequestFocus: false, skipTraversal: true)`，
命中 `inputSpec.keyTokens` 就折成与 JS 桥**同形**的 token 交回宿主并消费，未命中返回 `ignored`
继续冒泡（弹窗在页面 `Stack` 里的宿主——如阅读器——照旧走原本那条链，不双触发）。折 token 用的是
与生成键表**同一个** `InputBinding.serialize`，不存在「表里写 A、运行时折出 B」的漂移。
与 JS 桥天然**互斥**、故不需要平台判据：按键只会到达其中一个——DOM 收得到 keydown 的平台
（Android 等原生 WebView），Flutter 这边根本收不到 `KeyEvent`。

守卫（同一测试文件，共 18 例）用「页面 `Focus` 在浮层子树**之外** + 焦点落在浮层子树内」精确重建
断链拓扑，并断言宿主页面那层 `Focus` **确实一个键都没收到**——证明修复靠的是浮层交回而不是冒泡。
第三次变异实测（关掉键盘通道）转红后还原复绿。
