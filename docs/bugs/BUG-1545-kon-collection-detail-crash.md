## BUG-1545 · 视频起播时 hwdec=auto 抢先下发，CUDA 硬解初始化崩溃整个进程（Windows/NVIDIA）
- **报告**：2026-08-11（用户：打开 K-ON 番剧合集就闪退，别的番正常）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/media/video/video_player_controller.dart:1104`（裸 `VideoController(player)`）+ `third_party/media_kit_video/lib/src/video_controller/native_video_controller/real.dart:121,159`（把 `hwdec` 兜底成 `'auto'` 并立刻下发）
- **[x] ① 已修复** — 给 `VideoController` 传 `VideoControllerConfiguration(hwdec: resolveAndroidHwdec(mpvConfig.hwdec))`，让 app 的 hwdec 策略在**第一次属性下发**就生效，`auto` 不再有机会到达 libmpv（`video_player_controller.dart:1104` 附近）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_hwdec_controller_config_guard_test.dart`（8 条：源码守卫 4 + 值域行为 4；已做变异实测——把修复还原成裸 `VideoController(player)` 后 2 条断言转红、退出码 1）
- **备注**：

### 崩溃证据（本机真实 minidump，非推断）

`C:\Users\wrds\AppData\Local\Fushi\crashdumps\` 下 2026-08-11 的三份 dump（21:11 / 21:15 / 21:23，对应用户三次「开 K-ON 就闪退」）：

| dump | 异常 | 崩溃指令 |
|---|---|---|
| `hibiki-114628-360483968.dmp` | `c0000005` 访问违例 | `nvcuda64!cuProfilerStop+0x136d8f`：`mov rbx,[rax+8]`，`rax=0` |
| `hibiki-153076-360725984.dmp` | `c0000005` 访问违例 | `nvcuda64!cuProfilerStop+0x12b831`：`mov byte ptr [rax+293Ch],0`，`rax=0` |
| `hibiki-160912-361160875.dmp` | `c0000005` 访问违例 | 同上 |

三份栈形状完全一致，自底向上（`hibiki-160912`）：

```
libmpv_2!mpv_create+0x1ae                 <- mpv 核心线程入口
libmpv_2!mpv_stream_cb_add_ro+0x24c60     <- 播放循环 / play_current_file
libmpv_2!mpv_stream_cb_add_ro+0x2698f
libmpv_2!mpv_stream_cb_add_ro+0x387e9     <- reinit_video_chain（视频解码链初始化）
libmpv_2+0xfcbcb5 / +0xfcbf89             <- vd_lavc + hwdec 探测
libmpv_2!mpv_stream_cb_add_ro+0x57c20 / +0x59355 / +0x5ad45
libmpv_2!mpv_render_context_get_info+0x84930
libmpv_2!sixel_output_set_encode_policy+0x563743   <- cuda hwdec 初始化
nvcuda!cuInit+0x75  →  nvcuda64!cuInit+0x25  →  ★ 空指针解引用
```

`hibiki-114628` 那份停在 `nvcuda64!cuCtxCreate_v2+0x25` → `cuCtxCreate` 内部，同一条 CUDA 路径的下一步。

**关键：这是原生访问违例，不是 Dart 异常** —— 进程直接被杀，`ErrorLogService` 捕不到，所以 `Documents/error_log.txt` 里只剩崩溃前无关的 `extractVideoFrameViaFfmpeg` / `NetworkImage` 条目，看日志会误判成「没有崩溃记录」。

### 根因

1. `VideoPlayerController.load()` 在 `fushi/lib/src/media/video/video_player_controller.dart:1104` 用**裸** `VideoController(player)` 建控制器（不传 configuration）。
2. vendored 的 `third_party/media_kit_video/lib/src/video_controller/native_video_controller/real.dart:121` 把 `configuration.hwdec == null` 兜底成 **`'auto'`**，并在 `:159` 立刻 `setProperties({'vo', 'hwdec', 'vid'})` 下发给 libmpv。
3. 本类真正应用用户/默认策略的 `applyMpvConfigToPlayer` 排在 `player.open`（`:1160`）**之后**（`:1220`）。于是**首个文件的视频解码链是拿 `auto` 初始化的**。
4. `auto` 是 mpv 的**全量**硬解列表，含非 copy 的 `cuda` / `nvdec`；而 `VideoMpvConfig` 的合法值域只有 `{no, auto-safe, auto-copy}`（`video_mpv_config.dart` 的 `hwdecs` 白名单），默认 `auto-safe` —— **app 从来就不允许 `auto`，`auto` 完全是 media_kit 兜底塞进来的**。
5. Windows + NVIDIA 上 libmpv 走到 CUDA 分支即 `cuInit()` / `cuCtxCreate_v2()`，在 `nvcuda64.dll` 内部空指针解引用 → 整进程 `0xC0000005` 闪退。

即：**用户配置的 `auto-safe` 在解码器初始化那一刻还没生效，生效的是被禁止的 `auto`。** 修复不是「事后再覆盖一次」，而是让策略在构造时就随 configuration 进去，时间窗本身消失。

### 关于「只有 K-ON 崩、别的番不崩」

已核实**不是** K-ON 标题里的 `!` / `!!` 打爆解析（沿 `filename_parser.dart` 逐条正则核过，`!` 全程安全透传），也**不是**每集建一个 Player（全仓 media_kit `Player(` 构造点只有 2 处，均单实例复用）。

也**不是**编解码格式差异：本机 27 个番剧目录里 hevc/yuv420p10le 有 14 个，K-ON 只是其中之一。

真正的差异是**时序窗口宽度**：K-ON 是本机最大的合集（59 集 / 3 季：S00=18、S01=14、S02=27，m3u8 播放列表导入），打开它时 Dart 侧 DB 读取与 UI 构建负载显著更重，`open` 之后那串 `await`（网络缓存 → 字幕轨 → 字幕抑制 → 着色器 → mpv 配置）落地更晚，libmpv 解码链在 `auto` 下已经跑到 CUDA 探测。小合集下策略往往赶在解码器初始化前落地，于是「碰巧不崩」。**这是竞态，不是 K-ON 专属**——同一台机器上任何让主 isolate 变忙的场景都可能中招，修掉时间窗才是根治。

崩溃时进程内另有 14 个 `mpv_wait_event` 线程（正常的播放器/音频 mpv 实例），不构成实例泄漏证据。

### 影响范围与验证缺口

- 影响：Windows + NVIDIA（CUDA 可用）用户起播视频时的随机整进程闪退；Android 侧 `resolveAndroidHwdec` 仍产出 `auto-copy`，与 `buildMpvProperties` 取值同源，BUG-465 不回归。
- 已验证：`flutter analyze` 零问题；定向 + 相邻测试 67 通过（退出码 0）；守卫已变异实测。
- **未验证**：真机复测「打开 K-ON 起播不再闪退」需要 Windows + NVIDIA 真机跑发行版 app，本轮未做——驱动级崩溃只能在真机确认。静态与行为层面根因已闭合。
