## BUG-2040 · 字幕列表打开后方向键等视频快捷键失效

- **报告**：2026-09-02（用户：「字幕列表唤出来以后，视频快捷键用不了了。修复一下。砍掉字幕列表的焦点吧」）
- **真实性**：✅ 真 bug。不是 BUG-1864 那种「挂载点够不到」的漏接线，而是手柄重设计 P3 的**有意让位**打在了错误的面板上：
  - `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:1875` 字幕列表随打开挂载即包 `PanelFocusScope(visible: true)`，后帧把焦点领进列表；
  - `fushi/lib/src/pages/implementations/video_fushi_page.dart:3955` `_videoNavigablePanelOpen` 把 `_subtitleListVisible` 计入「可导航面板」；
  - 于是 `resolveVideoKeyboardShortcut`（`fushi/lib/src/media/video/video_player_shortcuts.dart:790`）在 `videoNavigablePanelOpen && !videoSurfaceHoldsFocus` 时把裸 ←/→/↑/↓（seek / 音量）让位给焦点遍历、`videoEnterCaret`（Enter）因画面不持焦也放行；`_handleVideoGamepadButton`（`video_fushi_page.dart:4929`）同样让位 D-pad/A；且 `_canOwnVideoFocus`（`video_fushi_page.dart:3888`）在列表开着时拒绝把焦点收回画面——用户点一下画面也拿不回方向键。
  - 字幕列表是 push-aside 侧栏、画面全程可见可点，与被遮住画面的侧栏 / 剧集轨不是一回事；用户决定砍掉它的焦点。
- **[x] ① 已修复** — 去掉 `subtitle.part.dart` 里字幕列表外那层 `PanelFocusScope`（列表不再领焦点，只由指针 / 触屏操作）；`_videoNavigablePanelOpen` 移出 `_subtitleListVisible`——该 getter 是键盘 resolver 让位、手柄 D-pad 让位、`_canOwnVideoFocus` 拒抢焦三条门的共同真相源，改一处三条门同时放开。剧集轨 / 侧栏与网页视频页（其 `CallbackShortcuts` 包住整页含列表，方向键本就到得了）不动。搜索框点开时仍自己 `requestFocus`（整条视频通道按 BUG-962 让位），关掉时 `FocusAttachment.detach` 的 `previouslyFocusedChild` 语义把焦点还给上一个持焦者（画面）。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/video_panel_focus_nav_test.dart`：「两类可导航面板都包了 PanelFocusScope」改成剧集轨 / 侧栏两项，并新增「字幕列表不领焦点，且不在 `_videoNavigablePanelOpen` 集内」源码守卫，两半各自负向断言（只砍其一都是红）；已变异实测。
- **备注**：
  - Windows 真机未复验（窗口 + 全屏各开字幕列表按 ←/→/↑/↓/Space/Enter）。
  - 代价：手柄 D-pad 不再能在字幕列表行间移焦（P3 那条能力对字幕列表撤销）；列表行仍可 Tab 到达。
