## BUG-175 · 视频句子快进打回原点 / 进度条圆点闪开头 / 控制条不保持
- **报告**：2026-06-11（用户：飞书巡检表第109行 / TODO-096）
- **真实性**：✅ 真 bug，三个症状两处根因。

### ① 进度条小圆点闪开头 + ③ 句子快进有概率打回原点（同一根因）
- **根因**：`hibiki/lib/src/media/video/video_player_controller.dart` 的 `skipToNextCue` / `skipToPrevCue` 旧实现裸用 `_currentCueIndex ± 1`。但视频底部字幕是「时间窗结束就消失」语义（BUG-074）：`updateCueForPosition` 在两条字幕之间的**静音 gap** 里把 `_currentCueIndex` 清成 **-1**（与有声书「gap 保留上一句索引」不同）。于是用户在 gap 里按句快进时：
  - `skipToNextCue`：`next = -1 + 1 = 0` → `skipToCue(_cues[0])` → seek 到首句 `startMs` = **视频最开头**。播放态下下一拍 position 又往前走 → 进度条 thumb 闪到 0 再回来（症状①「圆点闪开头」）；暂停态 / 连续在 gap 里按 → 卡在原点（症状③「打回原点」）。落不落在 gap 取决于按键瞬间 position 是否正好在某条 cue 的时间窗内 → 用户感知为「有概率」。
  - `skipToPrevCue`：`prev = -1 - 1 = -2` → 越界 no-op，gap 里句子后退完全失灵（顺带修）。
- **[x] ① 已修复** — 抽纯函数 `nextCueIndexFor` / `prevCueIndexFor`（+ floor 二分助手 `_floorCueIndexByPosition`）做目标索引决策：`currentCueIndex` 合法时取相邻句；落在 gap（-1）时按**真实 `positionMs` 二分**定位「起点 <= 当前位置的最后一条 cue」再取下/上一条，永不返回负值/越界/原点。**不能**复用 `JsonAlignmentParser.findCueIndex`（gap 内含「末句之后」「首句之前」一律返回 -1，无法区分 → 会把「某句之后的 gap」误当首句之前打回 0）。`skipToNextCue`/`skipToPrevCue` 改调这两个纯函数。根因 `file:line`：`video_player_controller.dart:730-815`（修复后）。提交：见分支 `codex/todo-096-seek-progress`。

### ② 控制条不保持 / 任何操作都不刷新自动隐藏计时
- **根因**：media_kit 的 `MaterialDesktopVideoControls` / `MaterialVideoControls` 把控制条可见性与隐藏 `Timer`（`controlsHoverDuration`，本仓库 TODO-056 设 2 秒）藏在私有 State 里，**只**在鼠标 `MouseRegion.onHover`/`onEnter` 或拖动进度条时 `_timer?.cancel()` 重置；键盘快进/跳句、底部按钮 tap、编程 seek 都不触发重置（`material_desktop.dart:475-507`，无任何公开「重置计时」API）。于是桌面用户用键盘一直快进，控制条仍只活 2 秒就消失，得反复呼出。
- **[x] ① 已修复** — 新增 `_pokeControlsVisible()`（`video_hibiki_page.dart`）：往控制条子树（`_videoControlsContext` 的 RenderBox）中心经 `GestureBinding.instance.handlePointerEvent` 派发一个合成 `PointerHoverEvent`，命中 media_kit 自己的 `MouseRegion.onHover` → 它重置隐藏 `Timer` 并翻可见。**不绕开症状、而是驱动 media_kit 设计好的重置路径**（等价「鼠标移到了控制条上」）。仅桌面（`_isDesktopVideoControls` 门控；移动端 controls 走 tap 唤起、无此问题，合成 hover 也无意义）。接线：键盘 `previousSubtitle`/`nextSubtitle`/`seekBackward`/`seekForward` 四个回调；`_seekRelative`（底部 ±10 按钮共用）；底部「上/下一句」按钮经新 `_skipCueAndPokeControls`。根因 `file:line`：media_kit `material_desktop.dart:475-507`（隐藏计时只在 hover 重置）；修复入口 `video_hibiki_page.dart:1127`（`_pokeControlsVisible`）。

### 测试
- **[x] ② 已加自动化测试**
  - `hibiki/test/media/video/video_player_controller_test.dart` 新增 group「BUG-175 句子跳转目标索引（gap 不打回原点）」：`nextCueIndexFor`/`prevCueIndexFor` 在「定位到 cue / 已在首末句 / 各 gap（cue0-cue1、cue1-cue2、末句之后、首句之前）/ 空列表」全分支断言目标索引；+ 回归用例「进句到 cue0 → update 到 gap 清 -1 → next 必须按 position 回 cue1 不回 0」。这套用例对旧 `±1` 实现红（gap 时 next 给 0、prev 给 -2 no-op）。
  - `hibiki/test/pages/video_controls_poke_guard_test.dart`（源码守卫，media_kit headless 不可跑视频 widget）：钉住 `_pokeControlsVisible` 经 `GestureBinding.handlePointerEvent` 派发 `PointerHoverEvent`、桌面门控、四个键盘入口 + `_seekRelative` + 底部跳句按钮都接了 poke。
- **备注**：纯函数与源码守卫覆盖根因，但**真机/真模拟器播放快进**（gap 里按句不打回原点、控制条持续快进时不消失）需用户复测留证据（焦点驱动，见 docs/agent/integration-testing.md）。合成 hover 唤醒依赖 media_kit MouseRegion 在桌面对程序派发的 hover 事件正常响应（与真实鼠标移动同管线），桌面三端通用。
