/// 横屏矮窗口（横屏手机 / 小窗横放）下浮层的尺寸策略——对话框、浮动弹层、
/// 设置弹窗外框共用这一份，不在各调用点各写一套。
///
/// 背景（拍板台 MANKlxTTpV，维护者 2026-11-16）：「很多方框都有这种问题，横屏以后
/// 很多空地方，但是就是不用，而且中间基本上没功能或者功能区很小。」根因是所有浮层
/// 外框的尺寸规则都是按竖屏 / 桌面定的：宽度上限 420–640（为桌面宽窗口防止拉成
/// 长条），竖向再留 24+24 外边距、外加 0.82–0.86 的屏高比例封顶。横屏手机逻辑高度
/// 只有 ~400dp、宽 ~900dp：竖向被两道限制叠着吃掉 ~25%，横向却有一半以上空着。
///
/// 策略：判定为横屏矮窗口时
/// - 竖向外边距收到 [kFushiCompactLandscapeVerticalInset]，屏高比例封顶取消（只剩
///   外边距），把高度还给内容；
/// - 横向外边距不超过 [kFushiCompactLandscapeHorizontalInset]，宽度上限至少放宽到
///   [kFushiCompactLandscapeMaxWidth]（只放宽、不收窄；按内容取宽的对话框照旧按
///   内容取宽，正文长的才会变宽、少折行、少滚动）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/app_ui_scale.dart';

/// 窗口高度低于此（逻辑像素）且宽高比不小于 [kFushiCompactLandscapeMinAspect] 时
/// 视为横屏矮窗口。与浮动弹层的 `kFushiSheetShortWindowHeight` 同值（那边引用这里）。
const double kFushiCompactLandscapeMaxHeight = 500;

/// 横屏矮窗口的最小宽高比（4:3）。近方形的小窗（如桌面最小窗口 360×320）两侧并没有
/// 空出来的地方，不算；横屏手机（~2.2）、横放小平板（~1.6）都在其上。
const double kFushiCompactLandscapeMinAspect = 4 / 3;

/// 横屏矮窗口下浮层与屏幕上下边缘的留白上限。
const double kFushiCompactLandscapeVerticalInset = 8;

/// 横屏矮窗口下浮层与屏幕左右边缘的留白上限。
const double kFushiCompactLandscapeHorizontalInset = 24;

/// 横屏矮窗口下浮层的宽度上限下限：原上限比它窄的放宽到它（再受可用宽度约束）。
const double kFushiCompactLandscapeMaxWidth = 720;

/// [size] 是否是横屏矮窗口。
bool isFushiCompactLandscape(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.height > 0 &&
    size.width >= size.height * kFushiCompactLandscapeMinAspect &&
    size.height < kFushiCompactLandscapeMaxHeight;

/// 当前窗口（按**真实**视口尺寸，即逻辑尺寸 × [FushiAppUiScale]）是否是横屏矮
/// 窗口。外壳级的版面判据（页头大字档位、侧栏默认收展）用它：界面缩放只改逻辑
/// 画布，不改手机横过来只有 ~400dp 高这件事（同 `windowSizeClassReal` 的理由）。
bool isFushiCompactLandscapeWindow(BuildContext context) {
  final double scale = FushiAppUiScale.of(context);
  final Size logical = MediaQuery.sizeOf(context);
  final bool usable = scale.isFinite && scale > 0;
  return isFushiCompactLandscape(usable ? logical * scale : logical);
}

/// 浮层外边距：横屏矮窗口下把 [base] 的上下收到
/// [kFushiCompactLandscapeVerticalInset]、左右收到
/// [kFushiCompactLandscapeHorizontalInset]（只收不放），其余窗口原样返回。
EdgeInsets fushiCompactLandscapeInset(Size size, EdgeInsets base) {
  if (!isFushiCompactLandscape(size)) return base;
  return EdgeInsets.fromLTRB(
    math.min(base.left, kFushiCompactLandscapeHorizontalInset),
    math.min(base.top, kFushiCompactLandscapeVerticalInset),
    math.min(base.right, kFushiCompactLandscapeHorizontalInset),
    math.min(base.bottom, kFushiCompactLandscapeVerticalInset),
  );
}

/// 浮层宽度上限：横屏矮窗口下至少 [kFushiCompactLandscapeMaxWidth]（[maxWidth]
/// 本就更宽的保持不变），其余窗口原样返回。
double fushiCompactLandscapeMaxWidth(Size size, double maxWidth) {
  if (!isFushiCompactLandscape(size)) return maxWidth;
  return math.max(maxWidth, kFushiCompactLandscapeMaxWidth);
}

/// 浮层高度占屏高比例的封顶：横屏矮窗口下取消（1.0，只剩外边距限制），其余窗口
/// 原样返回 [fraction]。
double fushiCompactLandscapeHeightFraction(Size size, double fraction) {
  if (!isFushiCompactLandscape(size)) return fraction;
  return 1.0;
}

/// 浮层盒约束：横屏矮窗口下按 [fushiCompactLandscapeMaxWidth] 放宽 maxWidth
/// （有界的 maxHeight 原样保留），其余窗口原样返回。
BoxConstraints fushiCompactLandscapeConstraints(
  Size size,
  BoxConstraints base,
) {
  if (!isFushiCompactLandscape(size) || !base.maxWidth.isFinite) return base;
  return base.copyWith(
    maxWidth: fushiCompactLandscapeMaxWidth(size, base.maxWidth),
  );
}
