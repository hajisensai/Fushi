## BUG-839 · 全屏连播换集漏栈致ESC逐层回退

- **报告**：2026-07-15（用户：全屏看本地视频，连播下一集后按 ESC 回到上一集而非退出；连播 N 集要按 N 次 ESC）
- **真实性**：✅ 真 bug（仅桌面全屏下复现）。根因 `hibiki/lib/src/pages/implementations/video_hibiki/episode.part.dart:130`
- **[x] ① 已修复** — 见下「根因 + 修复」（分支 `worktree-fix-fullscreen-autoplay-esc-stack`）
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_fullscreen_switch_flatten_guard_test.dart`（源码守卫：本地换集 pushReplacement 前必先退全屏路由）；提交 `<pending>`
- **备注**：窗口模式不复现；远端播放列表原地换流不受影响。

### 根因

连播链路（全在 `video_hibiki/episode.part.dart`）：
`_handlePlaybackCompleted`(:18) → 5s 倒计时(:40) → `_runAutoAdvance`(:72) → `_switchEpisode`(:94)
→ 本地分支 `navigator.pushReplacement(...)`(:130)。

`pushReplacement` 的语义是**替换该 navigator 的栈顶路由**，而非「替换本集页」。全 app 只有一个 root
navigator（`hibiki/lib/src/models/app_model.dart:525`，home 无嵌套 Navigator），视频页与全屏路由同栈：

- **窗口播放**：栈顶就是剧集页，`pushReplacement` 正确替换本集 → 栈平，ESC 一次退出。**不复现**。
- **全屏播放**：进全屏时 app 往 root navigator **压了独立全屏路由**（`video_hibiki/fullscreen.part.dart:177`
  `rootNavigator: true`）。此刻栈 = `[书架, 第N集页, 全屏路由]`。连播触发 `pushReplacement` → 替换掉
  **栈顶的全屏路由**、把第N+1集页 push 上来 → 栈变 `[书架, 第N集页, 第N+1集页]`，**旧集页漏在下面**。
  ESC 只 `nav.pop()` 一层（`video_hibiki_page.dart:3423`）→ 回到旧集页而非退出。`_switchEpisode` 全程
  未与全屏路由协调，是漏栈的根。

引入提交 `07a1f9dee`（Phase 3 pushReplacement 低风险架构）——低风险架构未覆盖「全屏时栈顶不是剧集页」。

### 修复

`episode.part.dart` 本地换集分支：
1. `pushReplacement` 前若在全屏路由（`_videoFullscreenRoute != null`），先经既有汇聚点
   `_exitVideoFullscreen(_videoControlsContext)` 退全屏路由，让剧集页回到栈顶 → `pushReplacement`
   正确替换本集页（栈恒平）。
2. 记录 `wasFullscreen`，给新页 `VideoHibikiPage.neutralized(initialFullscreen: wasFullscreen)`；
   新页 `_promoteVideoReady`(:1608) 首帧就绪后若 `initialFullscreen && 桌面` 重进全屏 → 连播保持全屏沉浸。
3. 窗口模式（`wasFullscreen=false`）走原路径零变化；远端原地换流不受影响。

### 验证

- `flutter analyze`（lib+test）clean、`flutter test`
- Windows 离屏真机：全屏连播 → ESC 一次退出到书架 + 下一集仍全屏
