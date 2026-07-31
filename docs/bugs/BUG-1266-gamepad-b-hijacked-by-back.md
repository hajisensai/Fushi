## BUG-1266 · 手柄 B 被 Android 系统返回兜底抢占，改键无效；视频页首帧就绪前手柄键全失灵

- **报告**：2026-07-31（用户：）
- **真实性**：✅ 真 bug（两个独立根因叠加，症状互相放大）

用户原话：「进视频一开始不论是我映射了上一句的 b 还是下一句的 x 都按了也不会有反应，必须先按一下暂停才能正常上下句」「就算全局里设置了 rb 才是返回键，b 也依旧在起作用」「进视频想先回退两句然后直接回退到手机桌面去了」。阅读器（小说）同源。

### 根因 A：手柄按钮分发被压在默认关闭的实验开关下

`lib/src/shortcuts/global_navigation.dart` 的 `wrapWithGlobalNavigation` 把
`dispatchNativeGamepadButtonIntent` 与注册表 `globalBack` 解析整块放进
`if (focusNavigationEnabled)`，而该开关读的是
`preferences_repository.dart:376` 的 `experimental_focus_navigation_enabled`，
**默认 `false`**。于是默认安装上注册表 `globalBack` 根本不参与解析。

手柄改键是正式功能（快捷键设置有完整 UI + 默认绑定表 `shortcut_defaults.dart:158`），
却被挂在一个实验性「方向键/摇杆移焦」开关上——这是错误耦合。

### 根因 B：Android 的 `BUTTON_B → fallback BACK` 是一条绕过注册表的隐形返回路径

Android `Generic.kcm` 为游戏手柄的 `BUTTON_B` 定义了 `fallback BACK`：app 的 view 层
不消费 `KEYCODE_BUTTON_B` 时，系统**另外合成一个 `KEYCODE_BACK`** 派发下来。

叠加根因 A，默认安装上「B = 返回」实际一直由这条系统兜底提供，而不是 Hibiki 的绑定。
所以用户把「返回」改绑到 RB 之后，B 依旧退出页面——改键在 B 上从来就是假的。

对照可验证该边界只在 B：`BUTTON_A` 的兜底是 `DPAD_CENTER`（确认焦点控件，有益，保留），
X/Y/LB/RB/扳机/Start/Select 在 `Generic.kcm` 里没有 fallback，D-pad 也没有。

### 根因 C：视频页慢路径挂载 `Video` 后没有补焦点回收

`_videoFocusNode` 挂在 `Video` 上（`video_hibiki/layout.part.dart:69`），而
`_buildScaffold`（`video_hibiki_page.dart:5961-5964`）用 `!_videoReadyToShow` 把
**首帧未就绪的首开**挡在 `_buildLoadingBody` 分支——此刻 `Video` 尚未挂载、节点未
attach 到焦点树。`_applyLoad` 结尾那次
`_focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady)`
（`video_hibiki_page.dart:2822`）正落在这个窗口里，对孤儿节点 `requestFocus()` 是
**静默 no-op**（请求丢失，无任何报错）。

随后 `_promoteVideoReady()`（`video_hibiki_page.dart:1826`）把 `Video` 挂上、节点终于
attach，却**没有人再请求一次焦点**。于是焦点整段滞留在页面之外：

- 手柄按键不冒泡经过 `_wrapVideoGamepadControls`，本页全部手柄绑定失灵
  → 「B（上一句）/ X（下一句）按了没反应」；
- 这段窗口里 B 没人消费 → 触发根因 B 的系统兜底 → 直接退页
  → 「想回退两句，结果一路退回桌面」；
- 用户点一下画面（暂停）触发 `FocusReclaimCause.gesture` 回收后一切正常
  → 「必须先按一下暂停才能正常上下句」。

快路径（`load()` 返回即出画）不进 `_promoteVideoReady`，其 contentReady 回收时
`Video` 已挂载、本就有效，行为不变。

- **[x] ① 已修复** — 提交 `e88c569e0`
  - A：手柄按钮分发 + 注册表 `globalBack` 移出 `focusNavigationEnabled` 门控，
    门控范围收窄到只剩方向键移焦（`global_navigation.dart`）。
  - B：新增 `gamepadBackMustBeSwallowed`，在最外层就地消费**没有任何处理器认领**的
    手柄 B（DOWN/UP/REPEAT 三个边沿都消费——Android 的返回动作发生在 ACTION_UP，
    只吞按下边沿等于没修）。只吞 B，A / D-pad / 其余键原样放行。
  - C：`_promoteVideoReady()` 补一次
    `_focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady)`。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/shortcuts/gamepad_back_not_gated_test.dart`（新增，9 例）：
    焦点导航关闭时 B 仍按注册表返回 / 改绑 RB 后 RB 返回且 B 绝不返回 /
    未绑定的 B 被就地消费 / 吞键边界（B 三边沿吞，A、手柄 D-pad 三种来源、
    键盘键、其余手柄键均不吞）。
  - `hibiki/test/pages/video_page_keyboard_focus_static_test.dart`（+1 例）：
    `_promoteVideoReady` 方法体必须补 contentReady 回收。
  - 三个变异实测均精确命中：删吞键调用 → 只有「未绑定的 B 被就地消费」红；
    把 globalBack 解析放回门控 → 根因 A 两例红；删真实回收调用但**保留注释**
    → 视频守卫红（证明守卫读的是代码不是注释）。
- **备注**：本轮取消真机验证（无设备）。判绿依据为 `flutter analyze` 全量 +
  `flutter_test_failures.dart` 全量 VERDICT。与 Windows 侧「国产手柄方向键以 HID 键盘
  身份到达、`deviceType` 在非 Android 恒为 keyboard 故永不被识别为 D-pad」是**另一个**
  独立问题，未在本 BUG 内处理。
