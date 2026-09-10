## BUG-2441 · video-reopen-black-screen
- **报告**：2026-09-10（用户：本机 Windows 桌面版，`D:\APP\Hibiki\fushi.exe` 2.3.0-debug.14373）
- **真实性**：✅ 真 bug（现场取证，非复现推断）

### 现场事实（实测，非推断）

同一个 app 进程会话内（PID 117636，14:22 启动，全程未重启）：

| 时刻 | 事实 | 证据来源 |
|---|---|---|
| 18:21:30–18:26:07 | 打开 `Teasing Master Takagi-san - S01E01.mkv` 并**真实播放 135 秒**，期间查词 52 字符 | `study_segments` 行 `32e9fa11…`（`duration_ms=135403`, `chars=52`） |
| 18:26:07 | 退出播放页 | 同上 `end_at` |
| 18:30:48 | 再次打开**同一集** → 故障 | `video_books.last_played_at=1789036248714` |
| 故障态 | 画面全黑、整套控件正常、进度条空、**`00:00 / 00:00`**、播放键显示为「播放中」 | 真实像素截图（前台抓取，非 PrintWindow） |
| 故障态 | 进程 4 秒内**读盘 0 字节** | `Win32_Process.ReadTransferCount` 前后差 |
| 故障态 | `error_log.txt` 18:30 之后**无任何新条目** | `%USERPROFILE%\Documents\error_log.txt` 末条停在 16:40 |
| 故障后 | `video_books.last_position_ms` 被改写成 **0**（135 秒进度丢失） | Drift 只读查询 |

排除项：
- **媒体本身完好**——随包 `ffprobe` 秒开：23分36秒 / h264 1080p / 16 条流（flac + truehd + ac3 + ass×2 + PGS×2 + 8 个字体附件）/ 6.7GB。
- **不是卡在内嵌字幕枚举**——该集字幕缓存 18:21 已抽好（`%TEMP%\hibiki_vsub_cache\Teasing_..._S01E01_7197675896_…\sub_0.ass` / `sub_2.ass`），18:30 那次是缓存命中。
- **不是 `_init` 抛异常**——异常会经 `runZonedGuarded` 落 `error_log.txt`，而该文件无新条目。
- **不是本地代理端点起不来**——`ensureAppNativeProxyEndpoint()` 幂等且验活，失败会 `throw StateError` 并被页面 catch 显示错误；进程侧也确有 4 个 127.0.0.1 监听口。

### 根因

分三层，互相独立，缺一条都不足以产生现场的那个形状。

**① 失败被伪装成就绪（直接可见成因）**
`fushi/lib/src/pages/implementations/video_fushi_page.dart:2186` 的首帧兜底定时器 2500ms 到点后**无条件**调 `_promoteVideoReady()`，不检查 `load` 到底成没成功。libmpv 没打开成功 → 永远不会有首帧 → 2.5 秒一到照样挂载 `Video` → 黑屏 ＋ 整套控件 ＋ `00:00 / 00:00`。

**② mpv 错误没有任何归宿**
全仓库**零处**订阅 `player.stream.error`（唯一的 `stream.log` 订阅在 `video_player_controller.dart:1509`，只用于把 Lua 脚本报错归因到脚本）。libmpv 层的 open 失败因此既不抛异常、也不置任何失败态，用户与日志两头都拿不到线索。

**③ 位置写入把「没打开」当成「用户在片头」（数据损坏）**
三个位置写入点 `_maybeSavePosition` / `flushPosition` / `_forceSavePositionSync`（`video_player_controller.dart:2402 / 2425 / 3422`，行号为修复前）都只防「恢复 seek 未落地」，**没有一个检查媒体是否真被打开**。open 失败时 position 恒 0，第一个 125ms tick 就把 0 写库 —— 这就是 135 秒进度被抹成 0 的那一下。根子是 `0` 这个值背了两种互斥含义：「用户确实停在片头」与「根本没东西可播」。

**触发侧（未在本轮修复，见下）**：第二次 `open` 为何失败，指向 vendored media_kit_video 的 Windows 原生侧三处进程级共享状态，触发者都是 `video_player_controller.dart:3449` 的 `unawaited(_player?.dispose())`（Dart 侧不等原生拆完就返回）：
- `third_party/media_kit_video/windows/video_output.cc:131-171`：`~VideoOutput` 的 `promise.get_future().wait()` 是**无条件等待**，只有 `texture_id_ != 0` 分支才 `set_value()`；等不到就**永久持有** `VideoOutputManager::mutex_`（`video_output_manager.cc:19/42`），之后每一次 `Create` 都停在 `lock_guard`，而全进程只有 `ThreadPool(1)` 一根工作线程（`video_output_manager.h:80`）。
- `third_party/media_kit_video/lib/src/video_controller/native_video_controller/real.dart:127-128/243/254`：`_controllers` 按 **mpv handle 地址**索引，而旧 ctx 要 `Future.delayed(5s)` 才 `mpv_terminate_destroy`；新 `mpv_create()` 拿到同一地址时会复用绑在已死 Player 上的旧 controller。
- `third_party/media_kit_video/windows/angle_surface_manager.cc:25-33/136-140/304-402`：共享 D3D11 device / EGL display 是 `static`，销毁最后一个 VideoOutput 时 `eglTerminate` 整个释放、下次从零重建；`shared_interop_display_disabled_` 一旦置真**永不复位**。用户 18:20–18:21 连开 4 集，每次进出都跑一轮销毁/重建。

### 修复

- **[x] ① 已修复** — 三层全部落地，commit 见下。
  - 引入显式状态 `VideoPlayerController.mediaOpened`（`video_player_controller.dart`）：判据「曾观测到 duration > 0 **或** position > 0」（点播 open 即报 duration；直播流 duration 恒 0 但 position 会推进，两条缺一不可）。由 `load` 复位、`_markMediaOpenedIfEvident` 在 open 后快照与 125ms tick 两处翻真、`dispose` / `_releaseMediaHandles` 复位。这把 `position == 0` 的双义性拆成了两个可判定的状态，而不是给写入点加特例分支。
  - 三个位置写入点一律以 `mediaOpened` 为前提，媒体没打开就不写 —— 真实进度不再被一次失败的打开抹掉。
  - 订阅 `player.stream.error` → `onPlaybackError` → 页面 `_handlePlaybackError`：**媒体从未打开**时进失败态（给原因 + 重试/返回入口），**已打开后才报错**只落日志不掀页（画面与进度都还在，掀掉更糟）。
  - 首帧兜底改为分流 `_promoteVideoReadyOrDiagnose`：媒体活着照旧 promote（慢解码、纯音频容器不受影响）；没打开则再给 12.5 秒宽限，到点仍没打开才判失败并落 `VideoFushi.mediaNeverOpened` 日志。
  - 新 i18n key `video_load_failed_not_opened`（经 `tool/i18n_sync.dart --add`，17 语言齐全，`dart run slang` 重生成）。

  **code review 返工（同一 PR 内）**：首版把 `player.stream.error` 直接接到「置失败态」上，是错的——media_kit 把 mpv 里 level == error 且 prefix ∈ `{file, ffmpeg(tcp:), vd, ad, cplayer, stream}` 的日志**全部**灌进这条流，而 hwdec 候选试错（`[vd] Could not open codec.`）、外挂音轨/字幕打不开（`[cplayer] Can not open external file …`）在**完全正常**的播放里必然出现；`load()` 刚返回那一段 `mediaOpened` 尚未被观测到翻真（`open()` 先 `stop()` 清 state、`loadfile` 只下发不等解析完，重容器上窗口有一秒以上），于是正常起播会被打成失败页、而播放器不停、音频在失败页背后继续响。已改为：
  - mpv error **只留证不判决**（落日志 + 记一条诊断文本），判决权收归纯函数 `VideoPlayerController.shouldDiagnoseMediaNeverOpened`；
  - 超时判失败**只对本地文件**（网络流/直播 open 耗时受链路支配、直播 duration 恒 0，15 秒硬线是行为倒退）；
  - 失败态**可自愈**（判失败后媒体真打开了就反向清 `_failed`，不把用户钉在失败页而背后已在播）；
  - 判失败分支收干净定时器并校验 controller 仍是当前那个；
  - 失败文案不再过 `_describeLoadFailure`（裸子串匹配遇上带路径的 mpv 文本会把 `\\NAS\Network Share\…` 判成网络故障、文件名含 `Private` 判成「受限」）。

- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_test.dart` 新增 group「BUG-2441 媒体未打开时禁止位置写入」6 条：4 条否定（tick 的 0 / 非零位置 / `flushPosition` / `dispose` 强制写都不落库）＋ 2 条正向对照（媒体已打开时 tick 与 flush 照常落库），对照是为了防止「门永远关着」也能全绿的空壳。配套测试钩子 `debugPrimeUnopenedMediaForTesting`（与既有 `debugPrimeRestoreGuardForTesting` 刻意分开：两者驱动的是位置写入的两道**不同**的门）。
  - `shouldDiagnoseMediaNeverOpened` 真值表 4 条（含「媒体已打开不判死」「非本地文件不判死」两个方向）。
  - 源码守卫 `fushi/test/pages/video_playback_error_not_a_verdict_guard_test.dart`：钉死 `_handlePlaybackError` 不触碰失败态（这个错极易重犯，读起来太像「播放器报错 → 就是打不开」），并带反向断言防「方法体被删空也恒绿」。**变异实测**：把 `_failed = true` 加回该方法 → 守卫红；恢复 → 绿。
  - 另有真机复现用例 `fushi/integration_test/video_reopen_same_episode_itest.dart`（同一集播放→退出→重开，断言第二次 `debugDurationMs > 0` 且能真实前进），用故障现场那部素材。其中「进度不被抹」一条最初写成了空壳（fixture 播种就是 0，`expect(row, isNotNull)` 恒真），已改为由第一次退出建立非零基线再核对。

### 备注 / 未尽事项

- **真机复现未跑通，原因是本机构建环境缺件**：`flutter test -d windows` 构建失败于 `flutter_local_notifications_windows` 的 `atlbase.h: No such file or directory`。本机装了两个 VS 2022，flutter 选中的 **Community 缺 ATL 组件**，而 BuildTools（`14.44.35207\atlmfc`）有。给 Community 补装 ATL 组件即可恢复本机 Windows 构建/集成测试能力。上面 ① ② 的修复经单元测试与静态检查验证，**未经真机复测**。
- **触发侧（media_kit_video 原生三处）本轮未动**。它们在 vendored 的 `third_party/` 内，改动爆炸半径覆盖全部视频播放路径，且必须有真机复现才能验证是哪一条、以及改完是否真的解决。本轮修复的效果是：同样的故障再发生时，用户会看到**明确的失败提示 + 重试/返回入口**，且**已看进度不会被抹掉**，而不是对着黑屏和 `00:00 / 00:00`。建议按上一条恢复本机构建能力后单开一条 bug 追触发侧。
- 顺带发现、与本 bug 无关的两项：`%TEMP%` 下有 **1424 个 `hbk_client_vid*` 测试 fixture 残留目录**（9/6–9/8，测试泄漏）；另有一个 360MB 的 `<GUID>.tmp`（JFIF 头），命名形态属 Chromium/WebView2，**未能归因到本仓任何写入方**（本仓抽帧链恒带 `-frames:v 1 -update 1`，且命名一律 `hibiki_*` / `fushi_*` 前缀）。
