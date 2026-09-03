## BUG-1864 · 视频字幕列表持焦后整张快捷键表失效

- **报告**：2026-08-25（用户：打开右侧字幕列表后快捷键用不了）
- **真实性**：✅ 真 bug。字幕列表、剧集轨和侧栏是 `AdaptiveVideoControls` 的兄弟子树；`PanelFocusScope` 把焦点领进面板后，挂在 media_kit controls 子树里的 `CallbackShortcuts` 不再位于事件祖先链上。原 PR #1007 只合入了裸空格兜底；完整的整表修复提交 `bd8701bb2c` 是在 PR 合并后才追加到原分支，因此从未进入 `develop`。
- **[x] ① 裸空格兜底已修复** — `f99c4bd1d0` / `3804f11820` 把空格处理上提到窗口与全屏共用的 `_wrapVideoGamepadControls`，并让文本输入框获得空格。
- **[x] ② 已加空格拓扑回归测试** — `f99c4bd1d0` / `34bdc5b74f` 覆盖独立全屏路由、真实 `PanelFocusScope` 抢焦和无路由级通道的负向对照。
- **[x] ③ 整张视频快捷键表改为页级 press-time 单通道** — 每次按键由 `resolveVideoKeyboardShortcut` 读取当前注册表，并在窗口/全屏唯一共同祖先 `_wrapVideoGamepadControls` 派发。media_kit controls 显式接收空表，避免同一按键双通道执行。文本框持焦时整条视频通道让位；面板持焦时裸方向键让位给焦点遍历，带修饰键的字幕/视频动作仍执行；Enter 在控制条或面板持焦时继续作为焦点确认键；按住倍速保留 key-up 边沿。
- **[x] ④ 已加整表与边界测试** — 覆盖视频/通用 scope 解析、IME 物理键回退、弹窗优先级、字幕光标优先级、面板方向键导航、全屏路由挂载点，以及 media_kit 内层快捷键表必须为空。
- **验收边界**：静态与定向测试不能替代 Windows 实机。真机应复验：窗口和全屏分别打开字幕列表，确认 Space、F、L、B、Ctrl+←/→ 等绑定生效；裸 ↑/↓ 仍移动列表焦点；Enter 激活列表行；文本框可以正常输入空格。
- **审查补修**（同一 PR 内，press-time 单通道之上）：
  - 判决补第四态 `VideoKeyboardDispatch.swallowRepeat`（消费但不执行）。原实现只有
    ignore / run / dismissPopup，表达不了旧 `PageSpaceOverrideDecision.swallowRepeat`
    的语义，于是**长按空格按 OS 重复率连点播放/暂停**。这不是把 playPause 塞进
    `kVideoPressEdgeOnlyActions` 能修的：那条分支返 ignored（不消费），事件会漏给
    WidgetsApp 默认的 space→ActivateIntent，长按空格变成连点激活当前焦点控件
    （全局 `_neutralizeBareSpace` 只中和按下沿，挡不住重复沿）。两个都不对，必须
    有第四个状态。
  - 补 BUG-962 文本框让位契约的覆盖。生产行为一直是对的，但保护它的四道防线随旧
    测试一起被删了，且三个新 harness 都把 `hasEditableFocus` 硬编码成 false，结构
    上不可能触发这条分支——删掉页面那个参数、或把判据挪到浮层判据之后，全套测试
    照绿。爆炸半径还变大了：旧的页级覆盖层只管空格（坏了最多打不出空格），现在
    整张表都过这条通道（坏了就是在 mpv.conf / 弹幕规则框里打 f 直接切全屏）。
    新增 `fushi/test/media/video/video_keyboard_editable_focus_test.dart` 咬住让位、
    重复沿让位、文本框优先于浮层、以及「让位的是整条通道不只是空格」四条；
    页面源码守卫补 `hasEditableFocus: focusedEditableText() != null` 与
    `if (controller == null) return false;` 两条锚点。
  - 三条新断言全部做了变异实测：退回 ignored → 长按那条红；页面不喂判据 → 源码
    守卫红；判据顺序反了 → 「文本框优先于浮层」红。
- **已知欠账**（本轮不修）：
  - `guardVideoShortcutsWithPopupDismiss` 仍被 `web_video_fushi_page.dart` 使用，但它
    原来的 4 条测试全被改写成新 resolver 的测试，网页视频页的 BUG-924 语义现在无守卫。
  - `panelHoldsFocusNavigation` 参数名与实参 `_videoNavigablePanelOpen`（面板**打开**，
    非持焦）不符；今天两者等价，reclaim 门控一改就会静默失效。
  - `shortcut_channel_wiring_guard_test` 的 `video.keyboard` / `universal.keyboard` /
    `dictionaryPopup.keyboard` 三条通道现在只剩 `video_player_shortcuts.dart` 一个证人。
  - `video_fushi/layout.part.dart:76-78,174` 的注释仍在描述已被本 PR 推翻的
    「经 media_kit `keyboardShortcuts` 整表安装」拓扑。
  - 加载态 Esc 不再走本页退出阶梯（`_controller == null` 早退），落到全局 universal
    兜底；已加守卫钉住这条早退，但行为本身待确认是否有意。
  - Windows 真机未复验（含长按空格）。
