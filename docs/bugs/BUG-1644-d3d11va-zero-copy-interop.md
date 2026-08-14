## BUG-1644 · Windows 视频硬解走 d3d11va-copy：ANGLE 用自己的隐藏 D3D11 device，mpv d3d11-egl interop 加载不了
- **报告**：2026-08-14（用户：「d3d11va 的零拷贝 interop（现在连 d3d11-egl 都没加载起来，每帧白走一次 GPU→内存→GPU）。那是 media_kit 建 ANGLE context 时没把 D3D11 device 暴露给 mpv」）
- **真实性**：✅ 真 bug。根因 `third_party/media_kit_video/windows/angle_surface_manager.cc:CreateEGLDisplay`（补前）——`EGLDisplay` 建自 `eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, …)`，ANGLE 因此自建一个**隐藏的** `ID3D11Device`，与 `CreateD3DTexture` 里 media_kit 自己那个（`D3D11CreateDevice(..., flags = 0)`）互不相干。
- **根因有两条，缺一条都到不了零拷贝**：
  - **根因 A（设备）**：ANGLE 自建隐藏 `ID3D11Device`，media_kit 无法把自己的设备交给 mpv。
  - **根因 B（libmpv 版本）**：vendored 的 `mpv-dev-x86_64-20260704-git-33111f3212` 早于 mpv `1d15686142`（2026-07-31，`hwdec_d3d11egl: fix EGL_EXT_device_query availability check`）。旧版只在 EGL **display** 扩展串里找 `EGL_EXT_device_query`，而 ANGLE 按规范把它放在 **client** 串里 → `init()` 在**看设备之前**就静默 `return -1`。这条与设备无关，换成 device-backed display 也照样卡住（实测两种 display 都是 `display: no / client: YES`）。
- **[x] ① 已修复** — 两条一起修：
  - A：改成 mpv `context_angle.c` 的做法：进程内唯一一个 `ID3D11Device`（`BGRA_SUPPORT | VIDEO_SUPPORT` + `SetMultithreadProtected(TRUE)`），用 `eglCreateDeviceANGLE(EGL_D3D11_DEVICE_ANGLE, dev)` + `eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, …)` 交给 ANGLE；失败原样退回上游四级 fallback 链。详见 `third_party/media_kit_video/PATCHES.md` 的 BUG-1644 段。
  - B：vendored libmpv 升到 `mpv-dev-x86_64-20260813-git-7b8915bc1d`（相对修复提交 ahead 5 / behind 0），并在 `third_party/media_kit_libs_windows_video/windows/CMakeLists.txt` 写死「不得早于 2026-07-31」的下限说明。
- **[x] ② 已加自动化测试** — `fushi/test/third_party/media_kit_video_angle_interop_guard_test.dart`（8 条源码扫描守卫，含「fallback 链必须还在」「共享 device 不得逐实例 Release」「libmpv pin 不得早于 2026-07-31 且必须是已提交的非 `-lgpl`/`-v3` 构建」）；变异实测全部转红（含「断言字面量只出现在注释里不算数」一条，守卫内置 `stripComments`；libmpv 那条另做三次变异——日期回退 / 换 `-lgpl` 变体 / 指向未提交归档，各自命中不同断言）。
- **备注**：与 BUG-1639（另一条分支，**尚未并入 develop**）是同一条链路的**上下游**，不是重复条目——1639 修的是「Windows 上 `auto-safe` 会选到 CUDA/nvdec 导致 `nvcuda64` 空指针崩」，落点是把 hwdec 值域收敛到 `d3d11va,d3d11va-copy`；本条修的是「收敛之后 `d3d11va` 为什么还是失败、只能落 `d3d11va-copy`」。

### 根因链（对着 mpv 源码逐段核过）

mpv 的 `d3d11-egl` interop（`video/out/opengl/hwdec_d3d11egl.c` 的 `init()`）**只有一条**途径拿到解码用的
D3D11 设备——从**当前 EGLDisplay** 反查：

```c
p_eglQueryDisplayAttribEXT(egl_display, EGL_DEVICE_EXT, &device);
p_eglQueryDeviceAttribEXT((EGLDeviceEXT)device, EGL_D3D11_DEVICE_ANGLE, &d3d_device);
p->d3d11_device = (ID3D11Device *)d3d_device;
...
p->hwctx = (struct mp_hwdec_ctx){ .av_device_ref = d3d11_wrap_device_ref(p->d3d11_device), ... };
if (!p->hwctx.av_device_ref) { MP_VERBOSE(hw, "Failed to create hwdevice_ctx\n"); return -1; }
```

也就是说：**谁建的 display，谁的 device 就是解码设备**。上游 media_kit 让 ANGLE 自建 device，于是：

1. mpv 拿到的是 ANGLE 的隐藏 device，而它是 ANGLE 用自己的 flags 建的（ANGLE `Renderer11.cpp`
   `callD3D11CreateDevice` 里写死 `debug ? D3D11_CREATE_DEVICE_DEBUG : 0`），**没有**
   `D3D11_CREATE_DEVICE_VIDEO_SUPPORT`，也没人给它 `SetMultithreadProtected`；
2. `d3d11_wrap_device_ref()` 走 FFmpeg 的 `d3d11va_device_init()`，那里对设备 QI `ID3D11VideoDevice`、
   对 immediate context QI `ID3D11VideoContext`。这个 QI 是 **D3D11 运行时级**的门而不是驱动的门：
   不带 video flag 建的设备返回 `E_NOINTERFACE 0x80004002`（WARP 实测）。**但代价随适配器而异——本机
   RTX 5090 上，对 ANGLE 那个不带 flag 的设备 QI `ID3D11VideoDevice` 反而 `hr=0x00000000` 成功**，
   所以在这台机器上根因 A 并不是卡点，修它是为了在「flag 真的起作用」的适配器上也正确；
3. **真正卡住本机的是更早一步**：`init()` 在看设备之前先查 `EGL_EXT_device_query`，而 pinned 的
   libmpv（2026-07-04）只查 **display** 扩展串，ANGLE 把它放在 **client** 串 → 静默 `return -1`。
   这就是 mpv 日志里 `Loading hwdec driver 'd3d11-egl'` 之后**一行原因都没有**的来源；upstream 在
   `1d15686142`（2026-07-31）修掉，提交信息原话即 "The display string check always failed, silently
   disabling native d3d11va interop."；
4. `d3d11va`（零拷贝）因此不可用，`hwdec` 落到 `d3d11va-copy`——每帧解码结果从 GPU 读回系统内存再上传。

### 复现证据（本机，独立 C++ 探针 + 真 libmpv）

探针原样复刻 media_kit 的 ANGLE 初始化后创建真的 `mpv_render_context`，`hwdec=auto-safe` 播真片源：

```
=== mode=legacy driver=WARP videoSupport=0 clientVersion=ES2 hwdec=auto-safe ===
[env] ANGLE ID3D11Device = 00000229B4D2E3C0 (ours = 00000229B4D85C10) -> DIFFERENT device
[env] QI ID3D11VideoDevice (ffmpeg d3d11va_device_init): hr=0x80004002 FAILED
[mpv:libmpv_render] Loading hwdec driver 'd3d11-egl'      <- 之后无任何输出 = 静默失败
[RESULT] mode=legacy WARP video=0 es2 hwdec-req=auto-safe -> hwdec-current=d3d11va-copy
```

同一探针切到本补丁的路径（`eglCreateDeviceANGLE` + `EGL_PLATFORM_DEVICE_EXT`）：

```
=== mode=interop driver=WARP videoSupport=0 clientVersion=ES2 hwdec=auto-safe ===
[env] ANGLE ID3D11Device = 0000016C2A914FA0 (ours = 0000016C2A914FA0) -> SAME device
[env] QI ID3D10Multithread: hr=0x00000000 protected=1
```

即：**ANGLE 确实接受了我们的设备**，多线程保护保留，共享句柄 pbuffer 与 mpv 渲染均正常。
（这一轮是 WARP，因为 WARP 拒绝 `VIDEO_SUPPORT` 标志，所以 QI 仍失败、`hwdec-current` 仍是
`d3d11va-copy`——它验证的是**接线**，不是最终 hwdec 值。）

真 NVIDIA 硬件那一轮（GPU 还能建设备时抓到的）证明根因 A 在本机不是卡点：

```
[env] GL_RENDERER = ANGLE (NVIDIA, NVIDIA GeForce RTX 5090 Direct3D11 vs_5_0 ps_5_0, D3D11-32.0.15.9649)
[env] display ext EGL_EXT_device_query                          no      <- 卡在这里
[env] client  ext EGL_EXT_device_query                          YES
[env] ANGLE ID3D11Device = 0000025126012860 (ours = 000002516C676360) -> DIFFERENT device
[env] QI ID3D11VideoDevice (ffmpeg d3d11va_device_init): hr=0x00000000 OK   <- N 卡上并不失败
```

### 根因 B 的 A/B 证据（同一探针、同一 WARP、只换 libmpv DLL）

旧 pin `mpv-dev-x86_64-20260704-git-33111f3212`：

```
[   0.004][v][libmpv_render] Loading hwdec driver 'd3d11-egl'
[   0.004][v][libmpv_render] Loading failed.                      <- 静默，无任何原因
```

新 pin `mpv-dev-x86_64-20260813-git-7b8915bc1d`：

```
[   0.005][v][libmpv_render] Loading hwdec driver 'd3d11-egl'
[   0.005][v][libmpv_render/d3d11-egl] Failed to create hwdevice_ctx   <- 已越过 device_query 门
[   0.005][v][libmpv_render] Loading failed.
```

新版已经推进到「用设备建 hwdevice_ctx」这一步；WARP 上仍失败是因为 Basic Render Driver 根本没有
`ID3D11VideoDevice`（同轮实测 `D3D11CreateDevice(WARP, VIDEO_SUPPORT)` = `DXGI_ERROR_UNSUPPORTED
0x887A0004`），而真 N 卡上该 QI 已实测成功。

BUG-1639 用另一条独立路径（ctypes 直驱安装目录的 libmpv、GL 上下文）得到一致结论：
`d3d11va,d3d11va-copy` → 「`d3d11va` 失败 → `Using hardware decoding (d3d11va-copy)`」。

### 未闭环项（真机门）

「NVIDIA 真硬件 + 新 libmpv + device-backed display 下 `hwdec-current` 从 `d3d11va-copy` 变成
`d3d11va`」这一条**尚未取到**：本机 `D3D11CreateDevice(D3D_DRIVER_TYPE_HARDWARE)` 对三块 5090 适配器
一律返回 `E_OUTOFMEMORY 0x8007000E`（`D3D12CreateDevice` 同样失败，WARP / Basic Render Driver /
D3D9Ex 正常；显存 6.4G/32G、提交内存充足、驱动 2026-05-05 已开机 7 天，是 1014 个进程 / 68 个 GPU
客户端把 WDDM 侧资源打满），ANGLE 的 D3D11 display 随之 `EGL_NOT_INITIALIZED` 退到 D3D9。新 libmpv
自己也照出了同一条件：`[vd] Failed to create D3D11 Device: 内存资源不足 (0x8007000e)`。

GPU 恢复后跑这两条即可闭环（探针在临时目录，未入库）：

```
angle_probe.exe legacy  es2 auto-safe <video>   # 期望 hwdec-current=d3d11va-copy
angle_probe.exe interop es2 auto-safe <video>   # 期望 hwdec-current=d3d11va
```

也可以直接看 app：`VideoOutput` 现在在启动日志里打
`libmpv d3d11-egl zero-copy interop: available/unavailable`，播放中 `hwdec-current` 应为 `d3d11va`
而非 `d3d11va-copy`。
