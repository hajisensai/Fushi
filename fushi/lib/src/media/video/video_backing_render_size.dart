import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart' show VideoController;

/// macOS Retina 下「按物理像素渲染视频」（IINA 同款做法）。
///
/// 症状（用户报告：mac 视频发虚）：media_kit 在 darwin 上把纹理**固定建成视频原生
/// 分辨率**（`VideoOutput.videoSize` 读 mpv 的 `dw/dh`），`Video` 再把这张图交给
/// Flutter 按 `FilterQuality.low`（双线性）缩放到控件框。Retina 屏上控件框的物理
/// 像素是逻辑尺寸的 2 倍：1080p 片源在 1440×810pt 的框里实际要铺 2880×1620 物理
/// 像素，于是每帧都是「1920 宽的图被双线性拉到 2880」——整片发虚，而且 mpv 的缩放
/// 器与用户着色器（`VideoShaderManager`）全都用不上，因为缩放根本不在 mpv 里发生。
///
/// IINA 的做法是让 mpv 直接渲染到 backing store 尺寸（`convertToBacking`），缩放由
/// mpv 完成。本组件是同一思路在 media_kit 上的落点：量出 `Video` 控件框的物理像素
/// 尺寸，按视频原生宽高比算出「画面真正要占的物理像素」，用
/// [VideoController.setSize] 把它交给 mpv。按视频宽高比下发（而不是直接把框的尺寸
/// 丢过去）是必须的：mpv 会在给定尺寸里保持比例、自己补黑边，比例一旦不等于片源，
/// 黑边会被烤进纹理，Flutter 侧的 `cover` / `fill` 就会连黑边一起裁 / 拉。
///
/// 为什么只在 macOS：Windows 走 ANGLE 共享纹理 + HDR 直通宿主窗（另一条链路，改渲染
/// 尺寸会牵动 `HdrHostRectReporter` 的矩形契约），移动端拿不到同等收益却要为软件渲染
/// 多付 CPU。本次用户要的就是 mac 端。
///
/// 尺寸变化必经防抖：拖窗口会连发几十帧不同尺寸，每帧重建纹理就是卡顿。
class VideoBackingRenderSize extends StatefulWidget {
  const VideoBackingRenderSize({
    required this.controller,
    required this.videoSize,
    required this.fit,
    required this.child,
    super.key,
  });

  /// 目标控制器：算出来的物理尺寸下发到它。
  final VideoController controller;

  /// 视频**原生**解码尺寸（`player.state.width/height`）。
  ///
  /// 必须是原生尺寸而不是 `controller.rect`：后者正是本组件写进去的值，拿它当输入
  /// 会自激（下发 → rect 变 → 重算 → 再下发）。
  final Size? videoSize;

  /// 画面在框内的贴合方式（用户偏好 `VideoFitMode` 换算而来）。
  final BoxFit fit;

  final Widget child;

  @override
  State<VideoBackingRenderSize> createState() => _VideoBackingRenderSizeState();
}

class _VideoBackingRenderSizeState extends State<VideoBackingRenderSize> {
  static const Duration _debounce = Duration(milliseconds: 180);

  Timer? _timer;
  Size? _applied;
  Size? _pending;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(Size? target) {
    if (target == _pending) return;
    _pending = target;
    _timer?.cancel();
    _timer = Timer(_debounce, _apply);
  }

  void _apply() {
    final Size? target = _pending;
    if (!mounted || target == _applied) return;
    _applied = target;
    // 失败静默：渲染尺寸是纯画质优化，平台通道不可用时保持 media_kit 默认（视频原生
    // 尺寸），绝不因此让播放链路抛错。
    unawaited(
      widget.controller
          .setSize(width: target?.width.round(), height: target?.height.round())
          .catchError((Object e) {
        debugPrint('[Fushi] video backing render size skipped: $e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return widget.child;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _schedule(
          resolveVideoBackingRenderSize(
            boxLogicalSize: constraints.biggest,
            devicePixelRatio: dpr,
            videoNativeSize: widget.videoSize,
            fit: widget.fit,
          ),
        );
        return widget.child;
      },
    );
  }
}

/// 把 mpv 报上来的原生宽高（`player.state.width/height`）收成 [Size]；任一维缺失或
/// 非正（首帧解出画之前就是这样）返回 null，调用方据此保持 media_kit 默认尺寸。
Size? videoNativeSizeOf(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return Size(width.toDouble(), height.toDouble());
}

/// 单帧最多渲染多少像素（4K）。darwin 走的是软件渲染路径（`TextureSW`），每帧成本
/// 与像素数线性相关，5K/6K 显示器全屏放大会把 CPU 吃满，所以设上限；超过就按上限
/// 等比收，画质仍好过「原生尺寸再被 Flutter 拉大」。
const double kVideoBackingRenderMaxPixels = 3840 * 2160;

/// 与视频原生尺寸差多少才值得改（±5%）。窗口拖一点点就重建纹理不划算。
const double kVideoBackingRenderMinDelta = 0.05;

/// 算出 mpv 应当渲染的物理像素尺寸；返回 null = 用 media_kit 默认（视频原生尺寸）。
///
/// 纯函数，行为单测直接钉它——真实渲染要 macOS + NSWindow + 平台通道，headless
/// `flutter test` 一样都没有。
Size? resolveVideoBackingRenderSize({
  required Size boxLogicalSize,
  required double devicePixelRatio,
  required Size? videoNativeSize,
  required BoxFit fit,
  double maxPixels = kVideoBackingRenderMaxPixels,
}) {
  final Size? video = videoNativeSize;
  if (video == null || video.width <= 0 || video.height <= 0) return null;
  if (devicePixelRatio <= 0) return null;
  if (!boxLogicalSize.width.isFinite || !boxLogicalSize.height.isFinite) {
    return null;
  }
  final double boxW = boxLogicalSize.width * devicePixelRatio;
  final double boxH = boxLogicalSize.height * devicePixelRatio;
  if (boxW <= 1 || boxH <= 1) return null;

  // 画面在框里的实际占用比例。contain 取 min（内接，两侧可能留黑边）；cover / fill
  // 取 max：cover 裁掉超出部分、fill 由 Flutter 拉伸，两者都需要「至少铺满框」那一档
  // 像素，取 min 会让被放大的那一维欠采样。
  final double scaleW = boxW / video.width;
  final double scaleH = boxH / video.height;
  final double scale = switch (fit) {
    BoxFit.contain ||
    BoxFit.scaleDown ||
    BoxFit.none =>
      math.min(scaleW, scaleH),
    _ => math.max(scaleW, scaleH),
  };
  if (scale <= 0) return null;
  // 与原生尺寸几乎一致就别改：保持 media_kit 默认路径（也避免换片瞬间来回抖）。
  if ((scale - 1).abs() < kVideoBackingRenderMinDelta) return null;

  double width = video.width * scale;
  double height = video.height * scale;
  final double pixels = width * height;
  if (pixels > maxPixels) {
    final double clamp = math.sqrt(maxPixels / pixels);
    width *= clamp;
    height *= clamp;
    // 收到上限后若又落回原生尺寸附近，就别下发了。
    if ((width / video.width - 1).abs() < kVideoBackingRenderMinDelta) {
      return null;
    }
  }
  // 取偶数：奇数宽高在 YUV 半采样色度平面上要多一次补齐拷贝。
  return Size(
    math.max(2, (width / 2).round() * 2).toDouble(),
    math.max(2, (height / 2).round() * 2).toDouble(),
  );
}
