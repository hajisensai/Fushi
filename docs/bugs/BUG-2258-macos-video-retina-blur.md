## BUG-2258 · mac 视频在 Retina 上发虚：media_kit 按视频原生分辨率建纹理，放大交给 Flutter 双线性
- **报告**：2026-09-08（用户：「mac视频的retina也要适配」→ 追问后确认症状是**发虚**，并指定「参考 iina 的处理方式」）
- **真实性**：✅ 真 bug（结构性，非偶发）。根因链：
  - `third_party/media_kit_video/common/darwin/Classes/plugin/VideoOutput.swift:180-196`
    （`videoSize`）——未显式 `setSize` 时纹理尺寸恒等于 mpv 报的 `dw/dh`，即**视频原生
    分辨率**，与显示器 backing scale 无关。
  - `third_party/media_kit_video/lib/src/video/video_texture.dart:410-436`——`Texture` 被放进
    `SizedBox(rect.width, rect.height)`（逻辑像素）再由 `FittedBox` 缩放，缩放器是
    `filterQuality`，默认 `FilterQuality.low`（双线性）。
  - 于是 Retina（DPR 2）下 1080p 片源在 1440×810pt 的框里，实际要铺 2880×1620 **物理**像素，
    每帧都是「1920 宽的图被双线性拉到 2880」→ 整片发虚；mpv 自己的缩放器与用户着色器
    （`fushi/lib/src/media/video/video_shader_manager.dart`）完全用不上，因为缩放根本不在
    mpv 里发生。
  - IINA 的做法是让 mpv 直接渲染到 backing store 尺寸（`convertToBacking`），缩放全部在 mpv
    内完成——这正是「参考 iina」要对齐的点。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/video_backing_render_size.dart`：量出 `Video`
  控件框的物理像素尺寸，按**片源宽高比**算出画面真正要占的物理像素，经
  `VideoController.setSize` 交给 mpv（防抖 180ms、±5% 内不动、4K 像素上限、仅 macOS）。
  窗口侧与全屏路由两条 `Video` 都接
  （`fushi/lib/src/pages/implementations/video_fushi/layout.part.dart`、`.../fullscreen.part.dart`）。
  按片源比例而不是框的比例下发是必须的：mpv 会在给定尺寸内保持比例并自行补黑边，比例不等
  时黑边会被烤进纹理，Flutter 侧的 `cover` / `fill` 会连黑边一起裁 / 拉。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_backing_render_size_test.dart`：
  数值契约钉在纯函数 `resolveVideoBackingRenderSize` 上（Retina contain / cover / fill 取边、
  比例守恒、缩小也下发、像素上限、退化输入不下发），接线钉源码（两条 Video 都接、输入取原生
  解码尺寸而非 `controller.rect`、macOS 门控 + 防抖）。真实渲染要 macOS + NSWindow + 平台通道，
  headless `flutter test` 一样都没有，故最强可落地层就是这两组。
- **备注**：真机复测未做（本机是 Windows，无 Mac）——按仓库口径这条属
  `implemented_unverified`，Retina 观感改善需在 Mac 上回原始路径确认。同批改动还包含
  「macOS 改用与 Windows 同款自绘 MD3 顶栏、隐藏交通灯」，二者共处一条分支但互相独立。
