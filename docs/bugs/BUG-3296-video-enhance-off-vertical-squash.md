## BUG-3296 · Windows 关闭画质增强后画面纵向被压扁约 0.74%
- **报告**：2026-10-12（应用内反馈 #nHz3k6xegQ，Windows 11 IoT LTSC 24H2，窗口 1707x912@1.5：「视频关闭画质增强画面会稍微压扁」，附「关 / 开」两张同一帧截图）
- **真实性**：✅ 真 bug，第三轮已在本机真 app 复现、定位到上游 mpv 并根因修复（见文末）。
  - 截图量化（两张 1600x900，逐像素拟合 `off(y) = on(sy·y + d)`）：横向缩放恰为 1.000，纵向 `sy = 1.0075`、上沿对齐——即「关」那张在同样高度里多塞了约 0.74% 的竖向内容，比例恰等于 1088/1080。
  - 「关」那张最底下 3~4 行像素逐行几乎相同（行间差 ≈0.01，「开」那张同位置 ≈1.3），是 H.264/HEVC 1080p 编码高度对齐到 1088 时编码器复制底边得到的**填充行**。结论：关掉画质增强时渲染采样了未裁剪的 1920x1088 解码面，把 8 行填充一并压进 16:9 画面；开着时（着色器 / 高质量缩放链）走的路径正确裁到 1080。
  - Fushi 侧：「画质增强」档「无」= `highQuality=false`（`video_mpv_config.dart` `resolveScaleProperties` 下发 `scale/cscale/dscale=bilinear`）+ 清空 `glsl-shaders`；Flutter 纹理尺寸取 `video-out-params` 的 `dw/dh`（`third_party/media_kit_video/windows/video_output.cc` `GetVideoWidth/Height`），两者都不改裁剪。
  - 本机用独立 mpv（v0.41.0-259，`--vo=gpu`；opengl + d3d11va-copy 下 bilinear 与 ewa_lanczossharp 各一次，另 bilinear 下 d3d11+d3d11va、d3d11+d3d11va-copy、opengl+d3d11va、opengl+软解四组，共 6 组）渲染 1920x1080 x264 测试片（底边 8 行红条）到 2400x1350：全部正确裁剪、无压扁，**未复现**。差异点在 app 自带的 libmpv（`mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav1`）+ render API + ANGLE 共享纹理这条链，独立 mpv 覆盖不到。
- **第二轮：app 侧「开 / 关」实际下发差异逐项对比**（2026-10-13）
  - 开关入口：播放页「画质增强」选档 → `video_fushi_page.dart` `_applyShaderTier(highQuality, enabledNames)` → `VideoPlayerController.applyMpvConfig`（`applyMpvConfigToPlayer` 逐条 `setProperty`，`video_mpv_config.dart:729`）+ `applyShaders`（`change-list glsl-shaders clr` 再逐条 `append`，`video_shader_manager.dart:278`）。全局设置的 `video.quality.enhancement` 开关只走前一半。
  - `buildMpvProperties`（`video_mpv_config.dart:651`）里随 `highQuality` 变化的**只有** `scale / cscale / dscale / scale-antiring / cscale-antiring`（开：`ewa_lanczossharp`/`mitchell`/0.7；关：全 `bilinear`/0）；另加着色器列表清空。**不变**的：`hwdec`（两态都是 `resolvePlatformHwdec('auto-safe')` = `d3d11va,d3d11va-copy`，零拷贝优先）、`vo`/渲染 API（media_kit 固定 libmpv render API + `MPV_RENDER_API_TYPE_OPENGL` on ANGLE，`third_party/media_kit_video/windows/video_output.cc:56`）、`video-aspect-override` / `video-zoom` / `panscan` / `video-rotate`、`video-crop`（app 从不下发）。已加守卫 `fushi/test/media/video/video_enhancement_toggle_property_diff_test.dart` 钉死这一点。
  - 纹理尺寸：Flutter 纹理 = ANGLE 共享面，尺寸取 `video-out-params` 的 `dw/dh`（`video_output.cc` `GetVideoWidth/Height`，即裁剪后的显示尺寸 1920x1080，与开关无关）；mpv 每帧 `mpv_render_context_render` 画进这个 FBO（`video_output.cc:189-213`）。即 **app 侧两态用的是同一个显示尺寸与同一个 FBO**，没有「关闭时换了尺寸来源」的分叉——在 app 代码里找不到可改的根因。
  - 推断：本 app 在 Windows 上走 BUG-1644 打通的 `d3d11va` **零拷贝** `d3d11-egl` interop（`video_output.cc:77-84` 会打印 `libmpv d3d11-egl zero-copy interop: available`），解码面是编码尺寸 1920x1088。独立 mpv 的测试走的是 WGL / d3d11 自己的 interop，没有经过 ANGLE 的 `d3d11-egl`，所以复现不了。最可能的是 libmpv 在「零拷贝 d3d11-egl 纹理 + 无 hook + bilinear 直接采样」这条最短路径上，按整张 1088 面做归一化采样、丢了裁剪；开了着色器或 EWA 缩放时 mpv 先把平面拷进自己的中间 FBO（已按显示尺寸裁剪），所以正常。这只是推断，还要真机确认。
- **第三轮：本机真 app 复现 + 根因**（2026-10-13，RTX 5090，ANGLE 绑定 app 自建 D3D11 设备，d3d11-egl 零拷贝）
  - 片源：ffmpeg 生成 1920x1080 x264（coded 1920x1088），顶 8 行绿、底 8 行红、每 120 行一条 2 行白线。正确时顶绿 = 底红 = 8，白线中心 120.5 / 240.5 / … / 960.5。
  - 真 app 四组（`fushi/integration_test/video_hwdec_crop_probe_itest.dart`：生产同款 `resolvePlatformHwdec` + `applyMpvConfigToPlayer` + `applyShadersToPlayer`，Flutter 合成后的真实像素；回读确认 scale / cscale / 三项 scaling 开关已生效）：

    | 画质增强 × 硬解 | 修复前（libmpv discnav1） | 修复后（discnav1-hwcrop1） |
    |---|---|---|
    | 无 × 默认（d3d11va 零拷贝） | **底红 16 行，白线 119.5 / … / 953.5（×1080/1088）** | 底红 8，白线 120.5 / … / 960.5 |
    | 无 × 复制（d3d11va-copy） | 正确 | 正确 |
    | 低 × 默认（d3d11va） | 正确 | 正确 |
    | 低 × 复制 | 正确 | 正确 |

    与用户报告一致：只有「关增强 + 零拷贝」压扁。证据在 `fushi/.codex-test/windows-itest/{before2,after1}/`（不入库）。
  - 前两轮独立 mpv 复现不出来的原因：mpv 默认开着 `correct-downscaling / linear-downscaling / sigmoid-upscaling`。Fushi 的 `VideoMpvConfig` 默认与 media_kit 的初始化属性把这三项都关掉，再加上全 bilinear、不开 deband、不加着色器，正好满足 mpv `check_dumb_mode()`（`video/out/gpu/video.c:3972`）的全部条件，vo=gpu 自动进入 **dumb mode**。离屏 harness 逐项最小化后，触发条件就是这三项 + bilinear + 零拷贝硬解。打开任一项、换 ewa（画质增强开）、改成复制或软解，都不压扁。
  - 根因在上游 mpv 36abaa32（master 截至 2026-10-13 仍未修）：`pass_render_frame_dumb()`（`video.c:3164`）调 `compute_src_transform()` 时，`p->texture_w/h` 还是 `pass_render_frame` 开头赋的图像尺寸 1920x1080（`video.c:3206`）。平面纹理却是硬解映射面的真实尺寸 1920x1088（`pass_upload_image` 取 `tex->params.w/h`；`opengl/hwdec_d3d11egl.c:321` 用的是 `texdesc.Height`）。结果源变换的纵向比例按 1080/1080 而不是 1080/1088 算，含填充行的整张解码面被铺满输出。非 dumb 路径的 `pass_read_video()` 会在 `video.c:2408` 把 `texture_w/h` 改成参考平面尺寸，所以开增强时正常。HEVC 硬解面按 1152 行对齐，压扁更厉害（离屏实测白线落在 113 / … / 900.5）。
- **[x] ① 根因修复** — 补丁 `third_party/media_kit_libs_windows_video/patches/gpu-dumb-mode-hwdec-crop.patch`：dumb 路径在计算源变换前同样改用参考平面（luma / RGB / XYZ）的尺寸。软件帧和复制帧的平面尺寸本来就等于图像尺寸，行为不变。用 `tool/bluray/build_libmpv.ps1` 打补丁重编，vendored 归档换成 `fushi-discnav1-hwcrop1`：只有 `libmpv-2.dll` 变了，121 个依赖 DLL 逐字节相同，`probe_libmpv.py` 通过。没有加「强制复制解码 / 强制高质量缩放」这类绕过，dumb mode 的低开销保留。提交 5e5a76be29。
- **[x] ② 自动化测试** — 源码守卫 `fushi/test/build/libmpv_dumb_mode_hwdec_crop_guard_test.dart`：钉住补丁位置、构建脚本的应用顺序，以及 provenance 里记录的补丁 sha256 与仓内补丁一致。离屏真渲染脚本 `tool/bluray/verify_hwdec_crop.py`：真 ANGLE + 真 libmpv，跑 {无, 低} × {零拷贝, 复制, 软解} 六组；变异对照下旧库只有「无 × 零拷贝」失败，新库全部通过。真 app 探针 `fushi/integration_test/video_hwdec_crop_probe_itest.dart`：四组 4/4 通过。
- **备注**：没有在用户本机验证（GPU 未知）。修复点是与 GPU 无关的 mpv 渲染逻辑；离屏另外验证了 1280x720 / 2560x1440 输出尺寸也正确。可以考虑回报上游 mpv。
