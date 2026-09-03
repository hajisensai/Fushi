## BUG-1657 · 画质增强/超分静默失效：ANGLE device-backed display 之后任一步失败即掉软件渲染，而 SW 路径下 glsl-shaders 完全不生效
- **报告**：2026-08-15（用户：「我感觉画质增强，也就是超分好像不生效了」）
- **真实性**：✅ 真 bug（健壮性缺陷 + 可观测性缺失）。根因两层，见下。
- **[x] ① 已修复** — ① `third_party/media_kit_video/windows/angle_surface_manager.cc:Create()` 在 `CreateAndBindEGLSurface()` 失败时先调 `RetryOnUpstreamEGLDisplay()`：拆掉 device-backed display、latch `shared_interop_display_disabled_`、在上游 `EGL_DEFAULT_DISPLAY` 链上重建 context/surface；只有它也失败才抛异常。② `video_output.cc` 在 S/W 回落分支多打一行，明说 `glsl-shaders & scale filters are INERT`。
- **[x] ② 已加自动化测试** — `fushi/test/third_party/media_kit_video_angle_interop_guard_test.dart` 新增 2 条（`Create()` 必须走 retry 且必须 latch；S/W 分支必须打出 INERT 警告），共 10 条；两条各做变异实测转红，文件按 sha256 逐字节还原。

### 为什么「掉软件渲染」等于「超分没了」

media_kit 的 `VideoOutput` 在 `ANGLESurfaceManager` 抛异常时回落到
`MPV_RENDER_PARAM_API_TYPE = MPV_RENDER_API_TYPE_SW`（`video_output.cc:100`）。那条路**不是
`vo=gpu`**，libmpv 的 `glsl-shaders`（Anime4K 等超分）与 `scale`/`cscale`（画质增强下发的
`ewa_lanczossharp`）都不会被应用，而且**不报任何错**——用户只看到「开了跟没开一样」。

实测（同一份 libmpv、同一套用户实际启用的 7 个 Anime4K shader、同一个片源，只换渲染 API）：

| 渲染路径 | 生成着色器里 `conv2d` 引用数 |
|---|---|
| OpenGL / ANGLE（`vo=gpu`） | **2016**（Anime4K 完整进管线） |
| `MPV_RENDER_API_TYPE_SW`（media_kit 软件回落） | **0**（user shader 完全不生效） |

判据说明：mpv **不会**把 `//!DESC` 写进生成的着色器或日志，所以「日志里 grep 不到 Anime4K」
不能作为未加载的证据（第一次排查就在这里误判过一次）。可靠标记是 `//!SAVE` 产生的中间纹理名
（这里是 `conv2d*`），它会真实出现在生成的 GLSL/HLSL 里。

### 根因 A：BUG-1644 引入的新 display 没有下游回退

BUG-1644 让 ANGLE 跑在我们自建的 D3D11 device 上（`eglCreateDeviceANGLE` +
`eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, …)`）。`EnsureSharedEGLDisplay()` 只在
**创建该 display 本身**失败时退回上游四级链；但 config / context / `eglCreatePbufferFromClientBuffer`
是在**之后**做的，任何一步失败都会让 `Create()` 直接抛异常 → 整个 `VideoOutput` 掉进软件渲染。
也就是说：一个只影响「零拷贝」的问题，被放大成了「丢掉整条 GPU 渲染管线（连带画质增强）」。
device-backed display 上的 pbuffer 路径此前只在 WARP 上验过，真 N 卡未验证（见 BUG-1644 未闭环项），
所以这个放大风险是真实存在的。

修法：失败时保留硬件渲染、只放弃零拷贝——回到上游 display 重建一次。仅对**首个**实例执行
（`instance_count_ == 0`），避免把别的 `VideoOutput` 正在用的共享 display 拆掉。

### 根因 B：软件回落没有任何可观测信号

回落只打 `Using S/W rendering.`，没说代价。现在补一行明确写出 `glsl-shaders & scale filters
are INERT`，下次同类报告可一眼定位。

### 本次报告的现场结论

用户设置侧完全正常：`video_mpv_config.highQuality = true`，`video_shaders_enabled` 7 个且文件
都在 `D:\APP\HIBIKI_date\documents\mpv_shaders\`；下发链路也正常（探针实测 7 条
`change-list glsl-shaders append` 全部返回 0，`glsl-shaders` 属性确实带上 7 个路径）。

但**本机当时处于「新进程建不出硬件 D3D11 设备」的状态**（三块 5090 适配器一律
`E_OUTOFMEMORY 0x8007000E`，D3D12 同样失败，只有 WARP / Basic Render Driver / D3D9Ex 可用；
详见 BUG-1644 未闭环项与 `reference_no_hw_d3d11_device_when_gpu_clients_saturated`）。在该状态下
`EnsureSharedD3D11Device()` 必然失败 → `Create()` 抛异常 → 软件渲染 → 超分整体失效。
**这一条与 BUG-1644 无关，改动前后都会发生**；根因 A 是在此之上新增的、独立的放大路径。

### 未闭环

「真 N 卡上 device-backed display 的 pbuffer 是否可用」仍未验证（GPU 不可用）。若它其实不可用，
本条的 retry 正好把后果从「丢 GPU 管线」降级为「只丢零拷贝」；若可用，则 retry 永不触发，零代价。
GPU 恢复后按 BUG-1644 的命令跑一次探针即可同时闭环两条。
