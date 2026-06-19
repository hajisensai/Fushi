## BUG-343 · Windows 桌面本地音频/查词自动发音偶发没声 Player already exists

- **报告**：2026-06-20（用户：桌面快速连续查词/自动发音后偶发整进程没声，重启才好）
- **真实性**：✅ 真 bug — 根因在 `hibiki/lib/src/utils/misc/desktop_audio_playback.dart`（`DesktopAudioPlayback._play` / `stop` 在共享单例 `AudioPlayer` 上的活动未串行化），触发链穿过 `just_audio-0.9.42/lib/just_audio.dart`。

### 根因（沿真实代码路径坐实）

- 桌面用 `DesktopAudioPlayback` 的**单例 `AudioPlayer`**（`desktop_audio_playback.dart:65`，固定 player id 整进程从不 dispose）。
- just_audio 用 `_setPlatformActive(active)` 切换该 id 下的 native（media_kit）平台开/关：激活路径在 `just_audio.dart:1411` 经 `_pluginPlatform.init(InitRequest(id: _id, ...))` 把 id 注册到 media_kit，**注册发生在 `checkInterruption()`（`just_audio.dart:1428`）之前**。
- abort 路径只 `throw`（`just_audio.dart:1314-1317`）不清理已注册 id：被打断的那次激活在已经 `init(id)` 之后才抛 `PlatformException(code:'abort')`，留下一个 id 未 dispose 的孤儿 native player。
- 之后任何激活再 `init` 同一 id，just_audio_media_kit 抛 `Player <id> already exists!` → 此后所有桌面预览/自动发音都静音，直到重启进程。
- **触发条件**：快速连点发音 / 异词自动发音。`popup.js:1610` onclick 无 disabled 节流；`audioPlaybackMode` 默认 interrupt；`LookupAutoReadCoordinator` 只防同词不防异词并发/手动连点。两个 `stop→load→play` 周期重叠时，cycle A 在 `await player.ready()` 缺口注册 id，cycle B 自增 `_activationCount` 使 A `wasInterrupted()` 为真 → A 抛 abort（已泄漏 id）。

### 第一轮（被复核退回）的命门

第一轮（分支 `worktree-agent-ae8fa07c8bed9b8e6` commit `b56056fa1`）新增 `AudioActivationQueue` 把 `stop→setVolume→load` 串行化是对的，但把 `play()` 留在串行队列**外**（`unawaited(_player.play())`），并断言「play() 不改 activation」。**该论断错误**：just_audio 的 `play()` 在 `_active==false` 分支会调 `_setPlatformActive(true)`（`just_audio.dart:960-965` 的 `else` 分支），这是**第二个 activation 触发器**。逸出队列的 `play()` 触发的 `init(id)` 仍能与下一周期的 stop/activation 交错，重现 `already exists` / 孤儿 id 泄漏。

### 本轮修复

把会触发 `_setPlatformActive(true)` 的 `play()` 也纳入同一串行边界：`_play` 的 run 体内 `await _player.play()`（不再 `unawaited`）。

- **最小正确等待点（不阻塞整 clip）**：just_audio 的 `play()` 在 `await playCompleter.future`（`just_audio.dart:971`）处返回；`playCompleter` 由 `_sendPlayRequest` 在 `await platform.play(PlayRequest())`（`just_audio.dart:997`）后立即 complete —— 即原生 mpv **收到并接受** play 请求即返回，**不等 clip 播完**。`await play()` 因此把 activation 决策（`just_audio.dart:954` 的 `if(_active)` 发 play 请求 / `:963` 的 `_setPlatformActive(true)`）整段纳入串行边界，run 体 settle 时 `_active==true` 且 playing 已稳定，而音频继续后台播放，弹窗音频按钮不被阻塞。
- **stop 抢占语义**（防未来 dismiss-stop 回归）：`stop()` 先同步 `_activation.preempt()` 自增代际，再排队真正的 `_player.stop()`；`_play` 的 run 体在提交时捕获 `submittedGeneration`，在每个 yield 点（stop 后、load 后）重检 `_activation.generation != submittedGeneration`，被 stop 超越则提前 `return false`，不再启动新激活去和 incoming stop 抢同一 id。
- **鲁棒源码守卫**：守卫把源码 `\s+` 折叠后用分段 `contains` + 正则匹配（`await _player.play()` 存在、`unawaited(_player.play())` 不存在、`_activation.preempt()` 存在、`_activation.generation != submittedGeneration` 正则），防 dart format 折行脆断。

- **[x] ① 已修复** — `hibiki/lib/src/utils/misc/desktop_audio_playback.dart`（`AudioActivationQueue` 串行化 stop/load/**play** + preempt 代际；`_play` 内 `await _player.play()` + 代际重检；`stop()` 先 preempt 后排队）。提交：`dfed67ebb`。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/desktop_audio_playback_serial_guard_test.dart`（11 条）：严格串行不交错 / 失败不卡链 / caller 观察自身结果 / **play 逸出竞态**（建模「run 体外仍有未完成异步操作时下一 run 体已开始」→ 断言逸出会交错、awaited 不交错）/ stop 抢占代际 / 鲁棒源码守卫（含「play 必须 awaited 在体内、禁止 fire-and-forget」断言）。
- **备注**：media_kit 不能 headless，真机复测（Windows 快速连点发音不再 `already exists`、不再静音）待用户。`flutter analyze` 0；`flutter test test/utils/misc/` 235 条全绿（并行模式偶发的 `update_checker_mirror_fallback_test` 失败为计时/网络相关，与本改动无关，`--concurrency=1` 全绿）。
