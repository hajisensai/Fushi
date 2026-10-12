## BUG-3296 · Windows 关闭画质增强后画面纵向被压扁约 0.74%
- **报告**：2026-10-12（应用内反馈 #nHz3k6xegQ，Windows 11 IoT LTSC 24H2，窗口 1707x912@1.5：「视频关闭画质增强画面会稍微压扁」，附「关 / 开」两张同一帧截图）
- **真实性**：✅ 现象为真，**根因未定位，未修复**。
  - 截图量化（两张 1600x900，逐像素拟合 `off(y) = on(sy·y + d)`）：横向缩放恰为 1.000，纵向 `sy = 1.0075`、上沿对齐——即「关」那张在同样高度里多塞了约 0.74% 的竖向内容，比例恰等于 1088/1080。
  - 「关」那张最底下 3~4 行像素逐行几乎相同（行间差 ≈0.01，「开」那张同位置 ≈1.3），是 H.264/HEVC 1080p 编码高度对齐到 1088 时编码器复制底边得到的**填充行**。结论：关掉画质增强时渲染采样了未裁剪的 1920x1088 解码面，把 8 行填充一并压进 16:9 画面；开着时（着色器 / 高质量缩放链）走的路径正确裁到 1080。
  - Fushi 侧：「画质增强」档「无」= `highQuality=false`（`video_mpv_config.dart` `resolveScaleProperties` 下发 `scale/cscale/dscale=bilinear`）+ 清空 `glsl-shaders`；Flutter 纹理尺寸取 `video-out-params` 的 `dw/dh`（`third_party/media_kit_video/windows/video_output.cc` `GetVideoWidth/Height`），两者都不改裁剪。
  - 本机用独立 mpv（v0.41.0-259，`--vo=gpu`；opengl + d3d11va-copy 下 bilinear 与 ewa_lanczossharp 各一次，另 bilinear 下 d3d11+d3d11va、d3d11+d3d11va-copy、opengl+d3d11va、opengl+软解四组，共 6 组）渲染 1920x1080 x264 测试片（底边 8 行红条）到 2400x1350：全部正确裁剪、无压扁，**未复现**。差异点在 app 自带的 libmpv（`mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav1`）+ render API + ANGLE 共享纹理这条链，独立 mpv 覆盖不到。
- **[ ] ① 未修复** — 需要在 app 真实链路（Windows 发布构建 + 本仓 libmpv + ANGLE）上用 1080p（编码高 1088）片源对比「无」档与「低」档（`highQuality=true`、无着色器），先分清是「bilinear 缩放」还是「无 glsl hook」触发，再看 libmpv 的裁剪是否在该路径丢失（可开诊断日志看 `video-out-params` / `video-params` 的 w/h 与 crop）。
- **[ ] ② 未加自动化测试** — 根因落在 libmpv 渲染链，定位前没有可落地的测试层。
- **备注**：未复现前不加任何「强制开高质量缩放」之类的绕过。
