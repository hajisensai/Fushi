## BUG-4761 · 跨应用语音缓存停止时清不干净：清扫后还能落下新快照，句子音频临时目录在进程被杀后留在缓存里
- **报告**：2026-11-17（提交安全审查，针对 #3621 / 拍板台 oqk37s3QFL 的跨应用语音缓存）
- **真实性**：✅ 真 bug，两处。
  - 竞态：`fushi/android/app/src/main/java/app/fushi/reader/CrossAppAudioService.java:266`（修前）`releaseCapture` 先删快照、后把 `capturing` 置假；`CrossAppAudioProvider.snapshot`（binder 线程）在这之间通过了「还在录」的检查，就会在清扫之后把其他 app 的最近一段声音写进缓存目录，用户关掉开关后仍留着。
  - 清不全：`CrossAppAudioProvider.java:139`（修前）只删 `*.pcm`；Dart 侧 `prepareCrossAppSentenceAudio`（`fushi/lib/src/mining/cross_app_audio/cross_app_audio_clip.dart`）把截出的句子音频编码进 `systemTemp/fushi_cross_app_audio_*`，只靠调用方制卡后删，进程在这之间被杀就没人删。
- **[x] ① 已修复** — 原生：`releaseCapture` 先置假（`capturing` / `instance`）再清扫；provider 的「确认在录 → 取环 → 写文件」与 `deleteSnapshots` 持同一把 `SNAPSHOT_LOCK`，所以一次快照要么在清扫前写完被扫掉，要么在清扫后看到「没在录」不写；`deleteSnapshots` 删目录里所有文件，不按扩展名挑。Dart：新增 `sweepStaleCrossAppAudioDirs`，主引擎 `CrossAppAudioCapture.init()` 与原生推「停止」时各扫一遍 `fushi_cross_app_audio_*`，只删 10 分钟前建的（查词窗进程可能正在用刚建的那个，编码 + 制卡是秒级）。
- **[x] ② 已加自动化测试** — `fushi/test/mining/cross_app_audio_clip_test.dart` 的 `sweepStaleCrossAppAudioDirs` 两条：过期目录被删、保留期内的目录 / 无关目录 / 同前缀的文件不动。原生的加锁顺序没有可落地的单测层（需要设备上的前台服务 + provider 并发），靠 `:app:compileDebugJavaWithJavac` 编译与代码审查。
- **备注**：未做真机验证。
