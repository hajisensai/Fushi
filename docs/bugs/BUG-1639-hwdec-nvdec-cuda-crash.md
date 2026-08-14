## BUG-1639 · Windows+NVIDIA 起播闪退：hwdec=auto-safe 在 GL 渲染路径下必然回退 nvdec(CUDA)，nvcuda64 空指针整进程崩（BUG-1545 未根治）
- **报告**：2026-08-14（用户：打开 K-ON 就闪退——与 BUG-1545 同一句报告，装了含 BUG-1545 修复的构建后仍复发）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/media/video/video_mpv_config.dart` 的平台 hwdec 解析（原 `resolveAndroidHwdec`）在 Windows 上原样透传 `auto-safe`，而 `auto-safe` 的 mpv 白名单里 `nvdec` 就是 CUDA
- **[x] ① 已修复** — `resolveAndroidHwdec` → `resolvePlatformHwdec`，Windows 上把 `auto-safe`/`auto-copy` 解析成不含 CUDA 的显式候选（`d3d11va,d3d11va-copy` / `d3d11va-copy`），`no` 透传；两个调用点（`VideoController` 构造与 `buildMpvProperties`）同源取值
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_hwdec_controller_config_guard_test.dart` 新增 BUG-1639 组 6 条（值域不含 nvdec/cuda、两档语义、常量自校验、no 透传、非 Windows 零变化、端到端 `buildMpvProperties`）；已做变异实测两轮（常量掺 `nvdec` → 3 条转红；Windows 分支退化成透传 → 2 条转红，均退出码 1）
- **备注**：本条是 BUG-1545 的**未尽根因**，不是重复条目——1545 修的是「谁下发」，本条修的是「下发什么值」

### 崩溃证据（本机真实 minidump）

`C:\Users\wrds\AppData\Local\CrashDumps\fushi.exe.160512.dmp`（2026-08-14 16:14，进程版本 `2.0.0.11553`，
该构建产于 08-14 05:51，**已包含** BUG-1545 的修复 commit `538c2e847e`（08-11 22:26））：

```
ExceptionCode: c0000005 (Access violation), AV.Dereference=NullClassPtr, AV.Fault=Read
nvcuda64!cuProfilerStop+0x136d8f:  mov rbx,qword ptr [rax+8]   ds:0000000000000008   (rax=0)

libmpv_2!mpv_create+0x1ae                        <- mpv 核心线程入口
libmpv_2!mpv_stream_cb_add_ro+0x24c60            <- 播放循环
libmpv_2!mpv_stream_cb_add_ro+0x59e68 / +0x5a389 / +0x5ad45
libmpv_2!mpv_render_context_get_info+0x84930
libmpv_2!sixel_output_set_encode_policy+0x563743 <- cuda hwdec 初始化
nvcuda64!cuCtxCreate_v2+0x25  ->  nvcuda64!cuCtxCreate+0x10b  ->  空指针解引用
```

与 BUG-1545 记录的三份 08-11 dump 栈形状完全一致 → **同一条崩溃路径在修复后复发**。

### 根因：修掉了「谁下发」，没修掉「下发什么」

BUG-1545 的结论是「media_kit 把 `configuration.hwdec == null` 兜底成 `auto`，抢在 app 策略之前下发，
`auto` 含非 copy 的 `cuda`/`nvdec`」，修法是把 app 策略 `auto-safe` 随 `VideoControllerConfiguration`
传进去。**但 `auto-safe` 通往的是同一个 CUDA 后端**：

1. media_kit 的 `NativeVideoController` 在 Windows 走**纹理渲染**（libmpv render API + ANGLE/OpenGL），
   libmpv 拿不到宿主的 D3D11 device；
2. 于是 hwdec 探测里 `d3d11va`（需 D3D11 interop）**必然**失败：`[vd] Could not create device.`；
3. mpv 的 `auto-safe` 白名单里紧跟其后的是 `nvdec`——它是 CUDA API（cuvid）的封装，
   NVIDIA 机器上必然被选中：`[vo/gpu] Loading hwdec driver 'cuda'` → `Using hardware decoding (nvdec)`；
4. 进而 `cuInit()` / `cuCtxCreate_v2()` 在 `nvcuda64.dll` 内部空指针解引用 → 整进程 `0xC0000005`。

### 本机确定性复现（ctypes 直驱安装目录的 libmpv，非推断）

用 `D:\APP\Hibiki\libmpv-2.dll` + 本次崩溃的片源（`D:\video\K-ON!\Season 01\K-ON! - S01E01.mkv`，
HEVC **Main 10** / yuv420p10le / 1080p / Opus / ASS）在 **GL 上下文**（`gpu-context=win`，对齐 app 的
GL 纹理渲染而非 d3d11 直渲）下逐档实测：

| 下发的 hwdec | libmpv 实际选择 | 是否触碰 CUDA |
|---|---|---|
| `auto-safe`（app 默认，也是用户当前设置） | `Using hardware decoding (nvdec)` | 是，崩溃路径 |
| `auto-copy` | `Using hardware decoding (d3d11va-copy)` | 否（但无 d3d11va 的机器会落 `cuda-copy`） |
| `d3d11va-copy` | `Using hardware decoding (d3d11va-copy)` | 否 |
| `d3d11va,d3d11va-copy` | `d3d11va` 失败 → `Using hardware decoding (d3d11va-copy)` | 否 |

注：同一档 `auto-safe` 在 `vo=gpu` **d3d11 直渲**上下文下选的是 d3d11va、不碰 CUDA——所以「用 mpv.exe
播同一个文件不崩」不能证伪本条，渲染上下文才是分叉点。

### 关于「只有 K-ON 崩」

与 BUG-1545 的结论一致：不是 K-ON 专属，也不是标题里的 `!`、不是每集新建 Player。
本机 27 个番剧目录里 hevc/yuv420p10le 有 14 个。K-ON 是最大的合集（59 集 / 3 季），
打开它时主 isolate 负载最重，最容易走到会崩的那条初始化路径；修掉值域后与合集大小无关。

### 修复

`resolveAndroidHwdec` → `resolvePlatformHwdec(hwdec, {isAndroid, isWindows})`：一个函数决定「实际下发值」，
平台是它的输入（原来 Android 一个特例函数，Windows 再加一个就是两个特例）。Windows 分支：

- `auto-safe` → `d3d11va,d3d11va-copy`（`kWindowsAutoHwdec`）：先试 interop 直渲（media_kit 将来能共享
  D3D11 device 就直接受益），失败静默回落 copy-back；
- `auto-copy` → `d3d11va-copy`（`kWindowsCopyHwdec`）：用户显式要 copy-back，只给 copy 变体；
- `no` 原样透传。

`d3d11va` 是 Windows 8+ 通用硬解（Intel/AMD/NVIDIA 全支持），两档都失败时 libmpv 自行回落软解，不会无画面。
Android 分支行为一字未改（`auto-safe`/`auto` → `auto-copy`，BUG-465 不回归）；macOS/Linux/iOS 原样透传。

### 影响范围与验证缺口

- 影响：Windows + NVIDIA 用户起播视频时的整进程闪退（无 Dart 异常，`ErrorLogService` 捕不到）。
- 已验证：`flutter analyze` 零问题；定向 + 相邻 `test/media/video/` 全域 2572 通过（退出码 0）；
  守卫两轮变异实测；libmpv 层逐档实测见上表。
- **未验证**：真机复测「装上含本修复的构建后打开 K-ON 起播不再闪退」需要新出一版 Windows 包再走一遍原始路径。
  libmpv 层已确定性证明修复后的值域不会加载 `nvcuda64.dll`，但 app 内端到端仍待下一版验收。

### 用户侧即时缓解（无需等新版）

设置 → 视频 → 硬件解码 改成「自动（复制）」：本机实测该档在同一 GL 路径下选 `d3d11va-copy`，不碰 CUDA。
或改成「关闭」走软解（10-bit 1080p HEVC 软解在该机 CPU 上完全够）。
