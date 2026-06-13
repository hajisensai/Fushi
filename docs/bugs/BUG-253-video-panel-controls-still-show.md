## BUG-253 · 视频侧栏面板打开后背景控制条 / 右侧 rail 仍冒出来

- **报告**：2026-06-14（TODO-300：视频侧栏面板（设置 / 字幕列表 / 音轨 / 倍速 / 收藏句 / 字幕源）打开后，背景的 media_kit 控制条和右侧操作 rail 仍会反复冒出来盖在面板后面）。
- **真实性**：✅ 真 bug（UX 缺陷，桌面尤其明显）。
  - 控制条显隐镜像 `_videoControlsVisible` 此前**只**被 `_immersiveLocked` 抑制，从未被 `_videoSidePanel` 抑制；media_kit 自己的控制条由其内部 `MouseRegion` 在视频区任意 hover 时唤起，也不看面板状态。

### 根因（file:line）

`hibiki/lib/src/pages/implementations/video_hibiki_page.dart`，三条触发路径在面板打开时仍活跃：

1. `_showVideoSidePanel`（旧 :3916）打开面板时主动调 `_pokeControlsVisible()` → 派发合成 hover 把背景 media_kit 控制条点亮。
2. `_videoControlsHoverWrap`（:5039）是 `opaque: false` 的全屏 `MouseRegion`，鼠标在面板上方移动仍 `onHover → _handleVideoControlsHover → _markControlsVisible(true)` → 背景控制条 + rail 反复冒；同时 media_kit 自己 controls 子树的 `MouseRegion`（包在只看 `_immersiveLocked` 的 `IgnorePointer` 里）也照样收到 hover。
3. 右侧 rail gate（旧 :5184 `if (!controlsVisible || _immersiveLocked.value)`）也不看 `_videoSidePanel`。

`_pokeControlsVisible`（:1711）与 `_markControlsVisible`（:1753）的门控只有 `_immersiveLocked`，缺 `_videoSidePanel`。

### [x] ① 根因修复

把「面板开则抑制」扩展到控制条**显隐 / hover / rail 可见性 / media_kit 指针**全部路径，与沉浸锁同源门控（`_videoSidePanel` 是 `ValueNotifier`）：

- `_pokeControlsVisible`：`_immersiveLocked` 早返回之后加 `if (_videoSidePanel.value != null) return;`。
- `_markControlsVisible`：强制不可见分支改为 `if (_immersiveLocked.value || _videoSidePanel.value != null)`（取消隐藏定时 + 置 false）；`_handleVideoControlsHover` 经此自洽（无需单独门控）。
- 右侧 rail gate：`if (!controlsVisible || _immersiveLocked.value || _videoSidePanel.value != null)` 双保险（`controlsVisible` 在面板期间已被强制 false，再显式门控）。
- media_kit controls 的 `IgnorePointer`（旧只绑 `_immersiveLocked`）改用 `Listenable.merge([_immersiveLocked, _videoSidePanel])`，`ignoring: _immersiveLocked.value || _videoSidePanel.value != null` —— 面板期间 media_kit 收不到 hover，背景控制条不再被它自己唤起。键盘仍不受影响（`IgnorePointer` 只过滤指针）。
- `_showVideoSidePanel`：打开时不再 `_pokeControlsVisible()`，改 `_markControlsVisible(false)` 立刻把已显示的镜像收起；`_hideVideoSidePanel`：关闭（`_videoSidePanel.value = null` 之后）调一次 `_pokeControlsVisible()` 唤回控制条，给「面板已关、控制条回来了」的即时反馈。

提交：见本轮 `fix(video): suppress background controls + tap-outside-to-close side panels`。

### [x] ② 自动化测试

`hibiki/test/pages/video_side_panel_suppress_controls_guard_test.dart`（源码守卫）：
- `_pokeControlsVisible` / `_markControlsVisible` 门控含 `_videoSidePanel.value != null`；
- `_markControlsVisible` 的强制隐藏分支同时含 `_immersiveLocked` 与 `_videoSidePanel`；
- 右侧 rail gate 含 `_videoSidePanel.value != null`；
- media_kit controls 的 `IgnorePointer` 经 `Listenable.merge` 绑 `_videoSidePanel`、`ignoring` 含 `_videoSidePanel.value != null`；
- `_showVideoSidePanel` 不再调 `_pokeControlsVisible`、`_hideVideoSidePanel` 调 `_pokeControlsVisible` 唤回。

（media_kit controls + hover 时序跑不了 headless，故锁源码结构不变量，与既有 `video_mouse_autohide_guard_test.dart` / `video_settings_panel_no_fullscreen_guard_test.dart` 同范式。）

### 不回归

- 沉浸锁路径（`_immersiveLocked`）行为不变，只是 gate 多了一个并列条件。
- 键盘 / seek 唤起字幕避让、解锁按钮可见性、双击 seek 等都不动。
- 关闭面板后控制条照常可被 hover / 键盘唤回（`_hideVideoSidePanel` 末尾 `_pokeControlsVisible`）。

### 残留风险

- **真机待验**：host 跑不了 media_kit 渲染 + 真实 hover 时序，需桌面真机打开各侧栏面板、移动鼠标确认背景控制条 / rail 不再冒，关面板后控制条能正常唤回。
