/// 查词弹窗「最大宽 / 高」的实时预览（设置页与小说阅读器快捷设置共用）。
///
/// 滑杆写的是**上限**，真实尺寸还要经 [resolvePopupRect] 按当前屏幕、底部停靠、
/// 竖排避让夹一次——用户拖到 2000 但手机只有 400 宽时，只看滑杆读数会以为弹窗
/// 有 2000 宽。这里用与宿主同一个 [resolvePopupRect] 在缩小的「屏幕」里画出
/// 弹窗落点，并报出当前屏幕上的实际尺寸，几何真值只有一份。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show resolvePopupRect;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// 预览里「被查的词」放在哪：横排取屏幕左中偏上的一个词，竖排取右侧一列里的
/// 一个字。只是示意位置，但与真实阅读的典型落点同向，避让方向（上下 / 左右）
/// 与正文里一致。尺寸是逻辑像素（与 [screen] 同系）。
Rect lookupPopupPreviewSelection({
  required Size screen,
  required bool verticalWriting,
}) {
  if (verticalWriting) {
    return Rect.fromLTWH(screen.width * 0.62, screen.height * 0.24, 26, 52);
  }
  return Rect.fromLTWH(screen.width * 0.28, screen.height * 0.36, 52, 26);
}

/// 预览里弹窗的矩形：与 base_source_page `_calculatePopupPosition` 走同一个
/// [resolvePopupRect]，参数同义（[maxWidth] / [maxHeight] 已乘界面缩放）。
/// 纯函数，单元可测。
Rect lookupPopupPreviewRect({
  required Size screen,
  required double maxWidth,
  required double maxHeight,
  required bool bottomDocked,
  required bool verticalWriting,
  double topReserve = 0,
  double padding = 6,
}) {
  return resolvePopupRect(
    selectionRect: lookupPopupPreviewSelection(
      screen: screen,
      verticalWriting: verticalWriting,
    ),
    screen: screen,
    bottomDocked: bottomDocked,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    padding: padding,
    topReserve: topReserve,
    verticalWriting: verticalWriting,
  );
}

/// 缩小的屏幕 + 被查词 + 弹窗落点。随滑杆实时重建（schema 的 refresh 会重建
/// 本行），弹窗矩形用 [AnimatedPositioned] 过渡，时长走 [fushiMotionDuration]
/// （墨水屏 / 减弱动效归零）。两套设计系统只换颜色、不换结构。
class LookupPopupSizePreview extends StatelessWidget {
  const LookupPopupSizePreview({
    required this.maxWidth,
    required this.maxHeight,
    required this.bottomDocked,
    required this.verticalWriting,
    this.screenOverride,
    super.key,
  });

  /// 已乘界面缩放的最大宽 / 高（逻辑像素）。
  final double maxWidth;
  final double maxHeight;
  final bool bottomDocked;
  final bool verticalWriting;

  /// 测试注入；null = 当前窗口（MediaQuery）。
  final Size? screenOverride;

  static const double _maxPreviewWidth = 320;
  static const double _maxPreviewHeight = 200;

  @override
  Widget build(BuildContext context) {
    final Size screen = screenOverride ?? MediaQuery.sizeOf(context);
    final double topReserve = screenOverride == null
        ? MediaQuery.paddingOf(context).top
        : 0;
    final Rect selection = lookupPopupPreviewSelection(
      screen: screen,
      verticalWriting: verticalWriting,
    );
    final Rect popup = lookupPopupPreviewRect(
      screen: screen,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      bottomDocked: bottomDocked,
      verticalWriting: verticalWriting,
      topReserve: topReserve,
    );

    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final Color frameFill =
        apple?.secondaryGroupedBackground ?? scheme.surfaceContainerLow;
    final Color frameBorder = apple?.separator ?? scheme.outlineVariant;
    final Color textLine = apple?.tertiaryFill ?? scheme.outlineVariant;
    final Color accent = apple?.accent ?? scheme.primary;
    final Color popupFill = apple?.fill ?? scheme.primaryContainer;
    final TextStyle? caption = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: apple?.secondaryLabel ?? scheme.onSurfaceVariant,
    );
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);

    return Padding(
      key: const ValueKey<String>('lookup_popup_size_preview'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double safeW = math.max(1, screen.width);
          final double safeH = math.max(1, screen.height);
          final double available = constraints.maxWidth.isFinite
              ? math.min(constraints.maxWidth, _maxPreviewWidth)
              : _maxPreviewWidth;
          final double scale = math.min(
            available / safeW,
            _maxPreviewHeight / safeH,
          );
          final Size box = Size(safeW * scale, safeH * scale);
          Rect scaled(Rect r) => Rect.fromLTWH(
            r.left * scale,
            r.top * scale,
            r.width * scale,
            r.height * scale,
          );
          final Rect sel = scaled(selection);
          final Rect pop = scaled(popup);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Center(
                child: Container(
                  key: const ValueKey<String>(
                    'lookup_popup_size_preview_frame',
                  ),
                  width: box.width,
                  height: box.height,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: frameFill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: frameBorder),
                  ),
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _TextLinesPainter(
                            color: textLine,
                            vertical: verticalWriting,
                          ),
                        ),
                      ),
                      Positioned.fromRect(
                        rect: sel,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      AnimatedPositioned(
                        key: const ValueKey<String>(
                          'lookup_popup_size_preview_popup',
                        ),
                        duration: motion,
                        curve: FushiMotion.standard,
                        left: pop.left,
                        top: pop.top,
                        width: pop.width,
                        height: pop.height,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: popupFill,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: accent, width: 1.2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t.lookup_popup_size_preview_effective(
                  width: popup.width.round(),
                  height: popup.height.round(),
                ),
                key: const ValueKey<String>(
                  'lookup_popup_size_preview_caption',
                ),
                style: caption,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                t.lookup_popup_size_shared_hint,
                style: caption,
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 预览屏幕里的「正文」：横排画行、竖排画列，只是示意。
class _TextLinesPainter extends CustomPainter {
  const _TextLinesPainter({required this.color, required this.vertical});

  final Color color;
  final bool vertical;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    const double inset = 8;
    const double thickness = 3;
    const double gap = 7;
    if (vertical) {
      for (
        double x = size.width - inset - thickness;
        x > inset;
        x -= thickness + gap
      ) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, inset, thickness, size.height - inset * 2),
            const Radius.circular(1.5),
          ),
          paint,
        );
      }
      return;
    }
    for (double y = inset; y < size.height - inset; y += thickness + gap) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(inset, y, size.width - inset * 2, thickness),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TextLinesPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.vertical != vertical;
}
