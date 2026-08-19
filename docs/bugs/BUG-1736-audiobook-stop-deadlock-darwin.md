## BUG-1736 · 播放中退出有声书音频永不停止且无法手动关闭
- **报告**：2026-08-19（用户：macOS 26.6.1）
- **真实性**：✅ 真 bug（**循环等待死锁**，非竞态）。根因链：
  - `packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart:1739`（修前）
    `_stopPlaybackOnce()` 第一步 `await _playActivationTail`；
  - `audiobook_controller.dart:907-909` `_activateMainPlayer()` 把 `_player.play()`
    返回的 Future 挂上 `_playActivationTail`；
  - `just_audio-0.9.42/darwin/Classes/AudioPlayer.m:1019-1032` —— `play:` 只把
    `FlutterResult` 存进 `_playResult` **不回调**，仅由 `pause`（`:1051`
    "PLAY FINISHED DUE TO PAUSE"）/ `complete`（`:1062`）/ `stop`（`:1338`）释放。
  - 于是 stop 等 play、而唯一能解开 play 的正是 stop → `_player.stop()` 永不执行，
    AVQueuePlayer 一路播到整本结束。
  - 平台归属：`fushi/lib/main.dart:225` 调的是无参 `JustAudioMediaKit.ensureInitialized()`，
    而该 API 的 `macOS` 形参默认 **false**（`just_audio_media_kit-2.1.0/lib/just_audio_media_kit.dart:66`），
    所以 macOS 走 just_audio 原生 Darwin 后端而非 media_kit。**Android 的 ExoPlayer
    同样是延迟回调**，同样中招；Windows/Linux 走 media_kit（`play()` 立即返回）故无此问题。
  - 「无法手动关闭」是同一根因的下半段：`fushi/lib/src/sync/../media/audiobook/audiobook_session.dart:307-316`
    的 `_stopInternal` **同步首段**（TODO-831 为消除退出闪帧而刻意前置）先把 `_book`/
    `_controller` 置 null 并 `notifyListeners()`，首页迷你条（唯一的 stop 入口，
    `now_listening_mini_bar.dart:68-72` / `:134-138`）随即收起；reader 内无 stop 控件、
    macOS 无悬浮字幕窗（`floating_lyric_channel.dart:35` 只认 Android/Windows）。
    controller 沦为孤儿，用户除杀进程外没有任何停止入口。`_enqueueLifecycle`
    （`audiobook_session.dart:106-118`）还被卡死的 `_stopInternal` 永久堵住，重开本书也救不回来。
  - **复现判别式**：播放中退出必现；**暂停后再退出不现**（`pause` 已消费 `_playResult`）。
- **[x] ① 已修复** — `packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart`：
  `_stopPlaybackOnce()` 顺序由「await 激活 → flush → stop」改为
  **「同步采样位置 → 先 stop 止声 → 再落库」**。BUG-1240 的不变式（落库值取自 stop
  归零**之前**）由同步采样 `_player.position` 保证，与等待无关；`_player.stop()` 反过来
  成为解开在途 play 的一方。`_playActivationTail` 保留但**降级为纯 play 串行化**，其文档
  钉死「停止路径禁止 await 它」并写明后端语义差异。**未**改动 `main.dart` 的后端选择
  （换后端不修根因：Android 照样中招，且会整体替换 macOS 音频栈，风险与本修复无关）。
- **[x] ② 已加自动化测试** —
  - 新增 `fushi/test/media/audiobook/audiobook_stop_darwin_play_semantics_test.dart`：
    假播放器复现 Darwin 的 `_playResult` 挂起语义（`play()` 的 Future 只在 pause/stop
    时 complete），断言 ① 播放中 `stopPlayback()` 能返回且平台 stop 真被调用、
    ② 落库值是 stop 之前的位置。带 `Timeout`——死锁的表现是永不返回，没有超时会把整个
    suite 挂死而不是给出清晰的红。**此前全部有声书测试的假播放器都只模拟 media_kit
    语义（`play()` 立即返回），这条语义差异零覆盖，正是本 bug 长期潜伏的原因。**
  - 改写 `fushi/test/media/audiobook/audiobook_position_flush_test.dart` 的守卫：原来钉
    **源码行顺序**（`await flushPosition()` 必须早于两个 stop），那是把实现顺序误当不变式，
    而且正是这条守卫让 `await _playActivationTail` 长期存活。改为钉真不变式：停止路径
    **不得** `await _playActivationTail`，且位置采样必须早于 `_player.stop()`。
  - 改写 `fushi/test/media/audiobook/audiobook_dispose_stop_test.dart` 中
    `'BUG-1240 immediate play then stop waits for platform activation'`：该用例断言的
    「play 在途时 stop 不得停平台」就是死锁契约本身，反转为「play 在途照样必须止声」，
    并用不打开的 gate + `timeout` 把死锁钉成红。
- **备注**：两条守卫测试在编写时都被**自己的解释性注释**误触发（注释里必然要写出被禁的
  `await _playActivationTail` / `grid-lanes` 字样），故均先剥掉整行 `//` 注释再匹配可执行代码。
  未做真机验收（用户侧仍在使用旧构建）。
