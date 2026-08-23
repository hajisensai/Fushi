## BUG-1775 · 资源语音待匹配全量轮询导致 Fushi 与浮窗冻结
- **报告**：2026-08-23（用户：游戏运行久后，浮窗与 Fushi 应用一起冻结）
- **真实性**：✅ 真 bug。现场 Fushi `pid=49808` 的主窗与浮窗同属 UI thread `2672`，该进程持续吃满约一个逻辑核；共享文本/截图内容静止时仍产生约 `10,736 IOOther/s`。`%TEMP%/fushi_gal_voice` 当时有 616 个资源文件，且至少一条台词永久待匹配。控制器 `gal_hook_session_controller.dart:4745` 每个 80 ms 文本 tick 重试全部 pending；基线 `b125671305` 的 `galgame_audio_source.dart:_findPairedVoiceFiles` 每次都在 UI isolate 执行 `Directory.listSync`，并在晚附着分支逐文件 `statSync`。两份现场 dump 的共同尾栈为 Dart `AllocateArray → Scavenge/GC → DartWorker/ThreadPool → Assert/abort`，与这条无界枚举/分配环一致。
- **[x] ① 已修复** — commit `2db5326598`：用会话级语音 dump 增量索引替换轮询全扫；正常 watcher 事件只异步读取变化路径，初扫/故障恢复才全量枚举，配对通过 tick/eventId/mtime 索引查询并缓存结果；stop 后的迟到 async consumer 不得复活 watcher，永久 watcher 故障按 250 ms→30 s 指数退避。
- **[x] ② 已加自动化测试** — commit `2db5326598`：`fushi/test/mining/gal_voice_dump_index_test.dart` 覆盖 64 路 singleflight、1000 次稳定 miss、扫描中事件、同数量 move 替换、1000 历史文件下单事件仅 stat 该路径、既有 WAV/OGG 配对语义、stop/restart epoch、跨 restart 的旧 synchronize 隔离、stop 后不得复活、watcher 故障恢复。
- **备注**：
  - 用户要求跳过剩余测试、直接构建。此前已完成：索引定向 10 tests、相关 galgame 128 tests、三文件 `dart analyze` 与全量 `flutter analyze`；整包 `flutter test` 跑到约 6094 个 `testDone` 且尚无失败时被主动取消，因此不记作全量通过。
  - Windows Debug 构建通过，产物为 worktree 下 `fushi/build/windows/x64/runner/Debug/fushi.exe`。本机只有 Flutter 3.44.0、未安装仓库钉定的 3.41.6；3.44.0 的 Release `gen_snapshot` 以 `0xC00000FD`（栈溢出）退出，降低内联深度重试仍失败，故 Release 构建未证明。
  - 本修复不改 native helper、注入协议、引擎二进制指纹或支持状态；SGRE 仍为 `implemented_unverified`。
  - 当前运行中的 Fushi 是修复前二进制，尚不能作为修复后真机证据；需新 Windows 构建在原游戏长时路径复测后，才能把“代码根因已修”升级为“现场冻结已消失”。
