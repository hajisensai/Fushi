## BUG-1690 · 启动静音预热在音频设备上开流,打断其他应用正在播放的音乐
- **报告**：2026-08-16（用户：「启动的时候会打断音乐」——启动 app 时其他应用正在播的音乐被打断）
- **真实性**：✅ 真 bug。沿启动路径逐个排除后，启动期唯一主动接触音频输出设备的调用是
  BUG-1015 引入的查词播放器静音预热：`main.dart`（`MediaKit.ensureInitialized()` 之后）
  `unawaited(TtsChannel.instance.warmUpLookupAudioPlayer())` → `tts_channel.dart:62`（仅对
  Android 短路）→ `desktop_audio_playback.dart:117 warmUp()`：在真实音频输出设备上走完整
  `stop→load→play` 周期播放 0.1s 全零 WAV。「静音」只保证听不见，**不能**保证不打断——
  打断音乐的是「开流」这个动作本身，与音量/采样内容无关：
  - iOS：just_audio 播放会激活 AVAudioSession（非 mixable 类别），系统立即暂停其他 app
    正在播的音频 → 每次启动都打断音乐（`warmUp` 的门控只排除了 Android，iOS 明明走原生
    just_audio、根本没有 media_kit 冷启动问题，却被顺带拉进预热）。
  - Windows/桌面：新开的渲染流会让蓝牙多点连接耳机把活跃源切到本机、并与独占模式输出
    设备争抢，同样表现为「一启动 Fushi，正在播的音乐断了」。
  - 其余启动路径已排除：Android `warmUpLookupAudioPlayer` no-op；`AudioService.init` 懒加载
    （openMedia 才起跑，`audio_controller.dart:58`）；原生 `TtsChannelHandler` 的 MediaPlayer
    懒创建（`TtsChannelHandler.java:256`）；有声书 `_configureAudioSession` 在装载时才调用。
- **[x] ① 已修复** — 根因修法：**启动路径彻底不碰音频设备**，预热改为惰性。
  `desktop_audio_playback.dart`：删除 `warmUp()`，新增同步方法 `_ensureWarmUpQueued()`——
  首次真实播放（`playUrl`/`playFile` → `_play`）在入队自己的播放周期**之前**，同步把静音
  预热周期排进同一条 `_activation` FIFO 串行队列（临时文件创建挪进队列 body；body 末尾等
  静音片 `ProcessingState.completed`（2s 兜底超时）再放行，防止真实周期开头的 `stop()` 把
  尚未完成的冷激活掐掉、空窗漏给可听播放）。FIFO 保证预热仍先于首个真实播放完成冷激活，
  BUG-1015 的保护逐周期不变；`tts_channel.dart` 删除 `warmUpLookupAudioPlayer()`（唯一消费
  者是启动路径，留口子=API 层面允许再接回启动）；`main.dart` 删除启动预热调用，注释改为
  「启动路径不得新增任何打开音频输出流的调用」。提交：见本分支。
- **[x] ② 已加自动化测试** — 重写 `fushi/test/utils/misc/desktop_lookup_audio_warmup_test.dart`
  （原 BUG-1015 守卫钉的正是「main 启动必须调用预热」这条错误接线，随根因一起翻转）：
  ① 预热 WAV 仍为合法全零 16-bit PCM；② 惰性接线——`_play` 在捕获 generation 前同步调用
  `_ensureWarmUpQueued`，且该方法在 `_activation.run` 之前无 await（FIFO 顺序不可破坏）、
  预热 volume 0；③ 负向守卫——`main.dart` 不得出现 `warmUpLookupAudioPlayer` /
  `DesktopAudioPlayback.` / `_ensureWarmUpQueued`，`TtsChannel` 不得再暴露启动预热入口。
  三条守卫均做过变异实测（删 `_ensureWarmUpQueued()` 调用 / 往 main.dart 塞回调用 → 红）。
- **备注**：「首次查词自动发音」比原先多等一次静音预热周期（~0.1-0.3s，仅本次启动第一次），
  换来启动零音频副作用。BUG-1015 的「首查即出声」行为需桌面真机复测原始路径确认无回归；
  BUG-1690 本身的「启动不再打断音乐」在 iOS/蓝牙多点场景真机验证待用户。BUG-1015 档案已
  补交叉引用。
