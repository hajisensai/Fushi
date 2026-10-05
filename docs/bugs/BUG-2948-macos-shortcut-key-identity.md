## BUG-2948 · macOS 上 Shift+符号键与系统保留默认键导致快捷键无法识别
- **报告**：2026-10-04（用户：在 macOS 上有些快捷键没有生效（无法识别））
- **真实性**：✅ 真 bug（Mac 真机 macOS 27.0 用真实 NSEvent 复现，见备注的取证）。两条独立成因：

  **成因 ①：Shift+符号键在 macOS 上被识别成另一个键。** macOS 嵌入层对符号键按「当前修饰下产出的字符」定逻辑键：Shift+/ 报 `question`、Shift+[ 报 `braceLeft`（Windows 同一按键报 `slash` / `bracketLeft`；Shift+数字仍是 `digitN`，字母恒为小写 `keyX`）。而本仓的绑定契约只认 `_knownKeys` 表内的键：
  - 录入：`fushi/lib/src/shortcuts/input_binding.dart` 的 `normalizeCapturedKey`（原实现只在 `logicalKey == process` 时按物理键回退——那条前提在原生平台不成立，BUG-1432）→ 录成表外键，只能存成 `#<keyId>`；
  - WebView 键盘桥按 DOM `code` 拼 token（`Shift+Slash`），与 `Shift+#63` 永远对不上；跨设备同步过去也换了一个键；
  - 运行时 `FushiShortcutRegistry.resolveKeyboard`（`shortcut_registry.dart`）与 `InputBinding.toActivator`（裸 `SingleActivator`，`triggers` 只有 `slash`，`CallbackShortcuts` 先按 triggers 过滤）都只做逻辑键精确匹配 → 在 Windows 录的 Shift+/ 同步到 Mac、或任何渠道得到的表内键绑定，在 Mac 上按了都不响应。
  - 另：`Quote`（'）与 `Backslash`（\）不在 `_knownKeys` 表里，同样只能存成 `#<keyId>`。

  **成因 ②：两个 macOS 默认键被系统先截走，app 永远收不到。** `fushi/lib/src/shortcuts/shortcut_defaults.dart` 的 `_macOS` 只把桌面默认的 Ctrl 换成 Cmd：
  - `audiobookPlayPause`：桌面 Ctrl+Space → macOS Cmd+Space = Spotlight（Ctrl+Space 本身又是「切换输入法」）；
  - `globalToggleFullscreen`：F11 = macOS「显示桌面」，且笔记本 F 行默认是媒体键。

  **已排除**（同一套真机取证）：Cmd / Option / Ctrl 组合都能到达 Flutter；Runner 菜单栏（Cmd+F/H/M/W/, 等）不抢键；点击阅读器正文后 first responder 仍是 `FlutterView`（不是 WKWebView 抢焦点）；Option+字母（含 dead key Option+E/N）逻辑键仍是 `keyX`。

- **[x] ① 已修复** —
  - `input_binding.dart` `normalizeCapturedKey`：引擎给出的逻辑键不在 `_knownKeys` 里、而物理键在覆盖表里时，按物理键取逻辑键（`question` + 物理 `slash` → `slash`）。表内键原样返回（AZERTY 的 A/Q 等布局字母语义不受影响）。录入、运行时共用这一条契约。
  - `shortcut_registry.dart` `resolveKeyboard`：先按原始逻辑键精确匹配（存量 `#<keyId>` 绑定照旧命中），不中再按归一后的键匹配；替换原先只认 `process` 的死分支（等价且更广）。漫画页 Flutter 键盘路径 `_resolveMangaKeyAction` 补传 `physicalKey`。
  - `input_binding.dart` `toActivator` 改返 `InputBindingActivator`：`triggers == null`，先走内层 `SingleActivator`，不中再按归一后的键 + 修饰键集合比一次。视频页 activator 表、查词弹窗制卡键、字幕列表搜索键一并受益。
  - `_knownKeys` / `_logicalToPhysical` 补 `quoteSingle`（'Quote'）与 `backslash`（'Backslash'），与 DOM `code` 同名；老快照的 `#<keyId>` 仍读回同一个键。
  - `shortcut_defaults.dart` 新增 `_macOSKeyboardOverrides`：macOS 上 `audiobookPlayPause` = Option+Space、`globalToggleFullscreen` = Ctrl+Cmd+F（macOS 标准全屏键）。用户 2026-10-04 选定。
  - `shortcut_registry.dart` schema v12 → v13 迁移（仅 macOS）：键盘绑定恰等于旧默认（Cmd+Space / F11）才换成新默认，且**只换键盘**（`_replaceKeyboardIfUntouched`），用户改过的键与手柄键原样保留。
- **[x] ② 已加自动化测试** —
  - `fushi/test/shortcuts/macos_shortcut_key_identity_test.dart`：归一规则（question→slash、braceLeft→bracketLeft、`"`→Quote、表内键不改、表外物理键不猜）；`resolveKeyboard` 对 macOS 形态事件命中、文本框 composing（physicalKey=null）不回退、存量 `#<keyId>` 精确命中；`toActivator` 认 macOS 的 Shift+/ 且修饰不符 / 抬起沿不触发；macOS 默认不含 Cmd+Space / Ctrl+Space / F11、其它平台默认不变；v13 迁移只换没动过的键盘、保留手柄、非 macOS 不迁移。
  - `fushi/test/shortcuts/global_toggle_fullscreen_test.dart`：F11 默认断言收窄到 Windows / Linux，新增 macOS = Ctrl+Cmd+F。
  - `fushi/test/media/video/video_hold_speed_key_test.dart`、`video_player_shortcuts_dispatch_test.dart`、`fushi/test/shortcuts/video_shortcut_registry_test.dart`：原先 `whereType<SingleActivator>` / `is! SingleActivator` 内省 activator 表，换类型后会空转成假绿，改为透视 `InputBindingActivator.exact` 并断言表非空。
  - Mac 真机 itest `fushi/integration_test/macos_keyboard_shortcuts_itest.dart`（Runner 测试钩子 `app.fushi.test/input` 新增 `key` 方法投真实 keyDown/keyUp NSEvent）：① 阅读器菜单改绑 Shift+/，真 NSEvent Shift+/ 打开外观面板；② Ctrl+Cmd+F 真进 / 出窗口全屏；③ Option+Space 真事件解析到 `audiobookPlayPause`。
- **备注**：
  - **真机取证（Mac，macOS 27.0，2026-10-04）**：修复后 itest 全绿（`① Shift+/ logical=Question physical=Slash sheetOpened=true`、`② fullscreen=true → false`、`③ resolved=audiobookPlayPause`）；把 `fushi/lib` 恢复成修复前（`9a790a68f65`）跑同一 itest 红在 ①（`sheetOpened=false`）。
  - 投递经 `NSApp.postEvent`，绕过了 WindowServer 的系统热键层，所以「Cmd+Space 被 Spotlight 截走 / F11 是显示桌面」这一环**不是**这套装置测出来的，依据是 macOS 系统默认快捷键表；装置只证明新键位在 app 内真的生效。
  - ② 进出全屏后，合成输入从不投 Ctrl/Cmd 松开的 `flagsChanged`，Flutter 会留着陈旧的 Ctrl/Meta 按下态、下一个键被同步吃掉一次（真机键盘松开修饰键会产生 flagsChanged，不受影响）。itest 因此把 ② 放在最后。
  - 已知限制（沿用 `_logicalToPhysical` 的既有限制）：物理位↔逻辑键按 US 布局对应。非美式布局上表外字符（如德语 ü）新录入时会存成它所在的物理键名（`BracketLeft`），运行时按同一规则匹配，行为自洽；只是设置页显示的是物理键名而非键帽字符。
