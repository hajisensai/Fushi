## BUG-278 · 退出阅读后有声书仍在播放（dispose 未先 stop 播放器）

- **报告**：2026-06-15（用户：现在退出阅读，有声书还在播放）
- **真实性**：✅ 真 bug（停止会话路径只 `pause` 不 `stop`，不释放 native 解码器）。
  - 根因 `hibiki/lib/src/media/audiobook/audiobook_session.dart:255`（`AudiobookSession.stop()`
    在 dispose 控制器前是 `await controller.pause(); controller.dispose();`）。
  - 关联 `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart:555`（`pause()`：
    just_audio 语义「保留解码器以便快速恢复」，**不释放 native 资源**）与
    `:1314` `dispose()`（`ChangeNotifier` 同步签名，`_player.dispose()` 是 fire-and-forget，
    异步的平台拆除抢不过紧随的 super.dispose）。
  - 架构事实（TODO-291 阶段2，`reader_hibiki_page.dart:1315`）：退出阅读器是 `detachReader`
    **不 dispose 控制器**（设计上后台继续听书 + 迷你条 + 悬浮窗 + 通知）。控制器归进程级
    `AudiobookSession` 持有，真正停止只走 `AudiobookSession.stop()`（关闭迷你条/悬浮窗 →
    `stopBackgroundListening()`）。该停止路径只 `pause` → Android(ExoPlayer) 解码器仍存活、
    仍占输出 → 用户感知「退出/停止后还在响」。
  - 即「退出阅读器本身后台续播」是设计，但**停止会话**必须真正止声/释放；当前没有。
- **[x] ① 已修复** — commit `9defa941a`
  - `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`：新增可 await 的
    `Future<void> stopPlayback()`——`await _player.stop()` + `_clipPlayer.stop()`（just_audio
    `stop()` 走 `_setPlatformActive(false)`，释放 native 解码器、置 playing=false），再
    `_maybeSavePosition(force: true)` 保留 `pause()` 的位置落库语义。`dispose()` 保持只做
    资源释放（不内联 unawaited stop，避免「stop 的异步平台切换」与「dispose 置 `_disposed`」
    交错触发 just_audio 状态机崩溃 `Cannot complete a future with itself`）。
  - `hibiki/lib/src/media/audiobook/audiobook_session.dart`：`stop()` 把
    `await controller.pause()` 改为 `await controller.stopPlayback()`（先 settle 平台切换=真止声，
    再 `dispose()`，不竞争）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/audiobook_dispose_stop_test.dart`
  - 行为测试（just_audio fake platform）：load+play 激活 native → `stopPlayback()` 后断言
    `disposePlayer` 计数相对基线 **+1**（stop 释放当前 native 解码器），并 `playing=false`。
    退回只 `pause` → 计数不增 → 红（TDD 红→绿已逐条验证）。
  - 竞争守卫测试：`stopPlayback()` 后 `dispose()` 不崩（无 just_audio 平台切换竞争）。
  - 源码守卫：钉住 `AudiobookSession.stop()` 用 `controller.stopPlayback()`、不退回
    `await controller.pause()`。
  - 回归校验：原 `audiobook_position_flush_test.dart` 全绿（早期把 stop 内联进 dispose 的方案
    触发竞争崩溃，已改为 await-then-dispose 避免）。
- **备注**：host 端无法真出声，行为层以 just_audio 公开播放态 + native player 释放（disposePlayer
  计数）为最强可落地证据。**真机 Android「关闭迷你条/悬浮窗后确认无声、退出阅读器后台续播仍正常」
  待用户复测**（reader/播放类按 CLAUDE.md 验证纪律需设备复测）。`flutter test --no-pub
  test/media/audiobook/` 409 绿；`dart analyze lib test`（hibiki）+ `dart analyze lib`
  （hibiki_audio）均 No issues。
