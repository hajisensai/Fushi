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
  - 代价（审查复核后据实改写，原措辞把它说轻了）：字幕列表变成**纯指针 / 触屏表面**。
    - **手柄实际上完全操作不了这个列表**：dpad 四向与 A 在 `ShortcutScope.video` 里绑到音量/seek/播放暂停
      （`shortcut_defaults.dart:246-277`、`:221-227`），而 `_handleVideoGamepadButton` 的让位闸门现在恒假，
      于是 `GamepadService` 的 dpad 移焦兜底（`gamepad_service.dart:474-491`）和 A→`ActivateIntent`（`:459-461`）
      永远到不了。唯一残存通道是左摇杆（`_dispatchStickMove:526-533` 不查注册表、页面拦不住），
      但**焦点挪进列表之后 A 仍是播放暂停、行激活不了**。不要写成「仍有手柄办法」。
    - 键盘：列表行确实还在焦点树上（`InkWell`，`video_subtitle_jump_panel.dart:1801`），Tab 到得了；
      但 `ListView.builder`（`:1470`）懒构建，离屏 cue 没有焦点节点，Tab 到底就到头、不会带着滚动加载，
      且每行 4 个节点，穿越成本很高。方向键既不遍历也不滚（列表不是 primary、未进 `PageScrollRegistry`）。
    - 面板自带的 Ctrl+F 副本（`:1519-1525`）在纯键盘场景下不再可达（要焦点先在面板内），
      但页面通道 `_requestSubtitleListSearch` → `searchRequests`（`subtitle.part.dart:91-96`）还在，功能不丢。
    - 搜索框关闭后的焦点归还是**隐式的**：`_toggleSearch` 关闭分支只清 controller、不 requestFocus
      （`video_subtitle_jump_panel.dart:1166-1170`），靠 `FocusScopeNode` 历史栈回到画面，**无测试钉住**。
  - 未钉住的分叉：`web_video_fushi_page.dart:1809` 仍把**同一个** `VideoSubtitleJumpPanel` 包在
    `PanelFocusScope` 里。网页页因整页 `CallbackShortcuts`（`:1569`）吃掉方向键而没有本 bug 的症状，
    但那边的 P3「D-pad 进面板」同样是死的，而新守卫只扫 `subtitle.part.dart`——两个宿主的策略分叉没有守卫。
