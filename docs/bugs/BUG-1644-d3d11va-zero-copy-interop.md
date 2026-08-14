## BUG-1644 · Windows 视频硬解走 d3d11va-copy：ANGLE 用自己的隐藏 D3D11 device，mpv d3d11-egl interop 加载不了
- **报告**：2026-08-14（用户：「d3d11va 的零拷贝 interop（现在连 d3d11-egl 都没加载起来，每帧白走一次 GPU→内存→GPU）。那是 media_kit 建 ANGLE context 时没把 D3D11 device 暴露给 mpv」）
- **真实性**：✅ 真 bug。根因 `third_party/media_kit_video/windows/angle_surface_manager.cc:CreateEGLDisplay`（补前）——`EGLDisplay` 建自 `eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, …)`，ANGLE 因此自建一个**隐藏的** `ID3D11Device`，与 `CreateD3DTexture` 里 media_kit 自己那个（`D3D11CreateDevice(..., flags = 0)`）互不相干。
- **[x] ① 已修复** — 改成 mpv `context_angle.c` 的做法：进程内唯一一个 `ID3D11Device`（`BGRA_SUPPORT | VIDEO_SUPPORT` + `SetMultithreadProtected(TRUE)`），用 `eglCreateDeviceANGLE(EGL_D3D11_DEVICE_ANGLE, dev)` + `eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, …)` 交给 ANGLE；失败原样退回上游四级 fallback 链。详见 `third_party/media_kit_video/PATCHES.md` 的 BUG-1644 段。
- **[x] ② 已加自动化测试** — `fushi/test/third_party/media_kit_video_angle_interop_guard_test.dart`（7 条源码扫描守卫，含「fallback 链必须还在」与「共享 device 不得逐实例 Release」）；变异实测 6 条全部转红（含「断言字面量只出现在注释里不算数」一条，守卫内置 `stripComments`）。
- **备注**：与 BUG-1639 是同一条链路的**上下游**，不是重复条目——1639 修的是「Windows 上 `auto-safe` 会选到 CUDA/nvdec 导致 `nvcuda64` 空指针崩」，落点是把 hwdec 值域收敛到 `d3d11va,d3d11va-copy`；本条修的是「收敛之后 `d3d11va` 为什么还是失败、只能落 `d3d11va-copy`」。

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

1. mpv 拿到的是 ANGLE 的隐藏 device，而它是 ANGLE 用自己的 flags 建的，**没有**
   `D3D11_CREATE_DEVICE_VIDEO_SUPPORT`，也没人给它 `SetMultithreadProtected`；
2. `d3d11_wrap_device_ref()` 走 FFmpeg 的 `d3d11va_device_init()`，那里对设备 QI `ID3D11VideoDevice`、
   对 immediate context QI `ID3D11VideoContext`；没有 video flag 的设备可能两者之一失败
   （本机实测：WARP 上 `QI ID3D11VideoDevice` = `E_NOINTERFACE 0x80004002`）；
3. `init()` 于是 `return -1`，而且是**静默**的（`goto fail` 前的分支都不打日志），mpv 日志里只看得到
   `Loading hwdec driver 'd3d11-egl'` 后面什么都没有；
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

BUG-1639 用另一条独立路径（ctypes 直驱安装目录的 libmpv、GL 上下文）得到一致结论：
`d3d11va,d3d11va-copy` → 「`d3d11va` 失败 → `Using hardware decoding (d3d11va-copy)`」。

### 未闭环项（真机门）

「NVIDIA 真硬件 + ANGLE D3D11 display 下 `hwdec-current` 从 `d3d11va-copy` 变成 `d3d11va`」这一条
**尚未取到**：本机当前 `D3D11CreateDevice(D3D_DRIVER_TYPE_HARDWARE)` 对三块 5090 适配器一律返回
`E_OUTOFMEMORY 0x8007000E`（`nvidia-smi` 显示 67 个 GPU 客户端进程、显存却还剩 25GB，属驱动并发 D3D
上下文打满），ANGLE 的 D3D11 display 随之 `EGL_NOT_INITIALIZED` 退到 D3D9。探针与一键复跑脚本见
`docs/agent/` 未收录的临时目录，命令：

```
angle_probe.exe legacy  hw novideo es2 <video> auto-safe   # 期望 hwdec-current=d3d11va-copy
angle_probe.exe interop hw video   es2 <video> auto-safe   # 期望 hwdec-current=d3d11va
```

GPU 空闲时跑这两条即可闭环；`VideoOutput` 现在也会在启动日志里直接打
`libmpv d3d11-egl zero-copy interop: available/unavailable`。
