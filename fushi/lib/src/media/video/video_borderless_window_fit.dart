import 'dart:ui' show Rect;

/// 无边框自适应播放时，窗口贴合视频宽高比所用的最小尺寸下限。
///
/// 与 app 启动 `setMinimumSize` 的 360×480 对齐；这里独立写死是为了让本文件保持
/// 纯 Dart 无平台依赖（不读 window_manager、不与启动顺序耦合），便于单测。
const double kVideoBorderlessMinWindowWidth = 360;
const double kVideoBorderlessMinWindowHeight = 480;

/// 计算贴合 [aspectRatio] 后的窗口 bounds：保持 [current] 左上角不动，按目标比例
/// 重算宽高，使视频在 contain 下铺满窗口、不留黑边。
///
/// 为什么需要这一步：只调 `windowManager.setAspectRatio` 不够 —— 其 Windows 实现
/// 只在 WM_SIZING 拖动阶段约束比例、**不矫正当前窗口尺寸**（平台限制），
/// `layout.part.dart` 的比例锁注释里记着「contain 仍留黑边」。
///
/// 算法：以当前宽为基准推高；推出来的高若低于 [minHeight]，改为以 [minHeight] 为
/// 基准反推宽；反推的宽若仍低于 [minWidth]，再以 [minWidth] 为基准推高。这样在
/// 极端比例（超宽/超窄视频）下也不会把窗口缩到比最小尺寸还小。
///
/// 纯函数，无平台依赖，由 `test/settings/video_borderless_window_fit_test.dart` 覆盖。
Rect fitWindowBoundsToAspect(
  Rect current,
  double aspectRatio, {
  double minWidth = kVideoBorderlessMinWindowWidth,
  double minHeight = kVideoBorderlessMinWindowHeight,
}) {
  // 比例非法时原样返回：调用方已过滤 width/height <= 0，这里只兜住传入的脏值，
  // 不让 NaN/Infinity 传播成 setBounds 的平台异常。
  if (aspectRatio <= 0 || !aspectRatio.isFinite) return current;
  double nextWidth = current.width;
  double nextHeight = nextWidth / aspectRatio;
  if (nextHeight < minHeight) {
    nextHeight = minHeight;
    nextWidth = nextHeight * aspectRatio;
  }
  if (nextWidth < minWidth) {
    nextWidth = minWidth;
    nextHeight = nextWidth / aspectRatio;
  }
  return Rect.fromLTWH(current.left, current.top, nextWidth, nextHeight);
}
