## BUG-3296 · Windows 关闭画质增强后画面纵向被压扁约 0.74%
- **报告**：2026-10-12（应用内反馈 #nHz3k6xegQ，Windows 11 IoT LTSC 24H2，窗口 1707x912@1.5：「视频关闭画质增强画面会稍微压扁」，附「关 / 开」两张同一帧截图）
- **真实性**：✅ 现象为真，**根因未定位，未修复**。
  - 截图量化（两张 1600x900，逐像素拟合 `off(y) = on(sy·y + d)`）：横向缩放恰为 1.000，纵向 `sy = 1.0075`、上沿对齐——即「关」那张在同样高度里多塞了约 0.74% 的竖向内容，比例恰等于 1088/1080。
  - 「关」那张最底下 3~4 行像素逐行几乎相同（行间差 ≈0.01，「开」那张同位置 ≈1.3），是 H.264/HEVC 1080p 编码高度对齐到 1088 时编码器复制底边得到的**填充行**。结论：关掉画质增强时渲染采样了未裁剪的 1920x1088 解码面，把 8 行填充一并压进 16:9 画面；开着时（着色器 / 高质量缩放链）走的路径正确裁到 1080。
  - Fushi 侧：「画质增强」档「无」= `highQuality=false`（`video_mpv_config.dart` `resolveScaleProperties` 下发 `scale/cscale/dscale=bilinear`）+ 清空 `glsl-shaders`；Flutter 纹理尺寸取 `video-out-params` 的 `dw/dh`（`third_party/media_kit_video/windows/video_output.cc` `GetVideoWidth/Height`），两者都不改裁剪。
  - 本机用独立 mpv（v0.41.0-259，`--vo=gpu`；opengl + d3d11va-copy 下 bilinear 与 ewa_lanczossharp 各一次，另 bilinear 下 d3d11+d3d11va、d3d11+d3d11va-copy、opengl+d3d11va、opengl+软解四组，共 6 组）渲染 1920x1080 x264 测试片（底边 8 行红条）到 2400x1350：全部正确裁剪、无压扁，**未复现**。差异点在 app 自带的 libmpv（`mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav1`）+ render API + ANGLE 共享纹理这条链，独立 mpv 覆盖不到。
- **第二轮：app 侧「开 / 关」实际下发差异逐项对比**（2026-10-13）
  - 开关入口：播放页「画质增强」选档 → `video_fushi_page.dart` `_applyShaderTier(highQuality, enabledNames)` → `VideoPlayerController.applyMpvConfig`（`applyMpvConfigToPlayer` 逐条 `setProperty`，`video_mpv_config.dart:729`）+ `applyShaders`（`change-list glsl-shaders clr` 再逐条 `append`，`video_shader_manager.dart:278`）。全局设置的 `video.quality.enhancement` 开关只走前一半。
  - `buildMpvProperties`（`video_mpv_config.dart:651`）里随 `highQuality` 变化的**只有** `scale / cscale / dscale / scale-antiring / cscale-antiring`（开：`ewa_lanczossharp`/`mitchell`/0.7；关：全 `bilinear`/0）；另加着色器列表清空。**不变**的：`hwdec`（两态都是 `resolvePlatformHwdec('auto-safe')` = `d3d11va,d3d11va-copy`，零拷贝优先）、`vo`/渲染 API（media_kit 固定 libmpv render API + `MPV_RENDER_API_TYPE_OPENGL` on ANGLE，`third_party/media_kit_video/windows/video_output.cc:56`）、`video-aspect-override` / `video-zoom` / `panscan` / `video-rotate`、`video-crop`（app 从不下发）。已加守卫 `fushi/test/media/video/video_enhancement_toggle_property_diff_test.dart` 钉死这一点。
  - 纹理尺寸：Flutter 纹理 = ANGLE 共享面，尺寸取 `video-out-params` 的 `dw/dh`（`video_output.cc` `GetVideoWidth/Height`，即裁剪后的显示尺寸 1920x1080，与开关无关）；mpv 每帧 `mpv_render_context_render` 画进这个 FBO（`video_output.cc:189-213`）。即 **app 侧两态用的是同一个显示尺寸与同一个 FBO**，没有「关闭时换了尺寸来源」的分叉——在 app 代码里找不到可改的根因。
  - 推断：本 app 在 Windows 上走 BUG-1644 打通的 `d3d11va` **零拷贝** `d3d11-egl` interop（`video_output.cc:77-84` 会打印 `libmpv d3d11-egl zero-copy interop: available`），解码面是编码尺寸 1920x1088。独立 mpv 的测试走的是 WGL / d3d11 自己的 interop，没有经过 ANGLE 的 `d3d11-egl`，所以复现不了。最可能的是 libmpv 在「零拷贝 d3d11-egl 纹理 + 无 hook + bilinear 直接采样」这条最短路径上，按整张 1088 面做归一化采样、丢了裁剪；开了着色器或 EWA 缩放时 mpv 先把平面拷进自己的中间 FBO（已按显示尺寸裁剪），所以正常。这只是推断，还要真机确认。
- **[ ] ① 未修复** — 真机验证步骤（Windows 发布构建，1080p H.264 片源，编码高 1088）：
  1. 设置 › 诊断 打开视频诊断日志（会给 libmpv 下发 `log-file` + `msg-level=all=v`），播放并在「画质增强」选「无」，导出日志，确认 `Using hardware decoding (d3d11va)`（零拷贝）与 `d3d11-egl zero-copy interop: available`。
  2. A/B 一：硬件解码改「复制」（`auto-copy` → `d3d11va-copy`），画质增强仍「无」。不压扁 → 锁定零拷贝 interop 路径。
  3. A/B 二：硬件解码保持默认，画质增强选「低」（`highQuality=true`、无着色器）。不压扁 → 触发条件是 bilinear 直接采样；仍压扁 → 是「无 glsl hook」触发。
  4. 定位后在本仓自编的 libmpv（`third_party/media_kit_libs_windows_video` 钉的 `fushi-discnav1` 构建）里修 d3d11-egl 映射的纹理尺寸 / 裁剪，或回报上游 mpv；在那之前**不**用「强制复制解码 / 强制高质量缩放」绕过（会让所有 Windows 用户多付一次 GPU→CPU 拷贝或缩放开销）。
- **[ ] ② 未加自动化测试** — 根因在 libmpv 渲染链，定位前无法写行为测试；app 侧「开 / 关只改缩放链」已由上面的守卫钉住。
- **备注**：未复现前不加任何绕过。
