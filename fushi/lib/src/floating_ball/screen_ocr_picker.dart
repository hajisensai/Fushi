/// 应用内识字选取页：截屏识字（iOS 截自己的窗口）与拍照查词（Android / iOS 相机）
/// 的识别结果都在这里点字查词。
///
/// Android 截屏识字不走这里：它用 MediaProjection 截整屏，识别与选取层都在原生侧
/// （同一条流程服务应用内与应用外）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiFloatingPill, fushiFloatingToolbarPalette;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 一次点选的结果：哪一行、行内第几个 UTF-16 码元、被点字符的框（逻辑像素）。
class ScreenOcrHit {
  const ScreenOcrHit({
    required this.line,
    required this.charIndex,
    required this.charRect,
    required this.lineRect,
  });

  final SystemOcrTextLine line;
  final int charIndex;
  final Rect charRect;
  final Rect lineRect;
}

/// 把点在屏幕上的 [point]（逻辑像素）映射到识别结果里的某一行某个字。
///
/// [scale] = 逻辑像素 / 送检图像素（截图是物理像素，等于 1 / devicePixelRatio）。
/// 系统 OCR 只给行框，字的位置按行内等分估计：竖排沿高度、横排沿宽度——日文
/// 等宽字形下误差在一个字以内，查词本身还会从这个字往后扫。点在行框外（含
/// [slop] 容差）返回 null。多行重叠时取面积最小的那一行（嵌套时更具体）。
ScreenOcrHit? screenOcrHitTest({
  required List<SystemOcrTextLine> lines,
  required Offset point,
  required double scale,
  double slop = 4,
}) {
  SystemOcrTextLine? best;
  Rect? bestRect;
  for (final SystemOcrTextLine line in lines) {
    final Rect rect = _scaleRect(line.rect, scale);
    if (!rect.inflate(slop).contains(point)) continue;
    if (bestRect == null ||
        rect.width * rect.height < bestRect.width * bestRect.height) {
      best = line;
      bestRect = rect;
    }
  }
  if (best == null || bestRect == null) return null;
  final List<String> glyphs = best.text.characters.toList();
  if (glyphs.isEmpty) return null;
  final int count = glyphs.length;
  final double fraction = best.isVertical
      ? (point.dy - bestRect.top) / bestRect.height
      : (point.dx - bestRect.left) / bestRect.width;
  final int glyph = (fraction.clamp(0.0, 1.0) * count).floor().clamp(
    0,
    count - 1,
  );
  int charIndex = 0;
  for (int i = 0; i < glyph; i++) {
    charIndex += glyphs[i].length;
  }
  final Rect charRect = best.isVertical
      ? Rect.fromLTWH(
          bestRect.left,
          bestRect.top + bestRect.height * glyph / count,
          bestRect.width,
          bestRect.height / count,
        )
      : Rect.fromLTWH(
          bestRect.left + bestRect.width * glyph / count,
          bestRect.top,
          bestRect.width / count,
          bestRect.height,
        );
  return ScreenOcrHit(
    line: best,
    charIndex: charIndex,
    charRect: charRect,
    lineRect: bestRect,
  );
}

Rect _scaleRect(Rect rect, double scale) => Rect.fromLTRB(
  rect.left * scale,
  rect.top * scale,
  rect.right * scale,
  rect.bottom * scale,
);

/// 送检图在选取页上怎么摆。
enum ScreenOcrImageFit {
  /// 截屏：截的就是当前窗口，与页面同形——贴宽、顶对齐，和截屏前的画面重合。
  window,

  /// 照片：形状任意，等比缩放后整张放进页面并居中（上下或左右留黑边）。
  contain,
}

/// 送检图在选取页上的位置：[origin] 是图左上角（逻辑像素），[scale] = 逻辑像素 /
/// 送检图像素。行框、点击坐标都经它换算。
class ScreenOcrImageLayout {
  const ScreenOcrImageLayout({required this.origin, required this.scale});

  factory ScreenOcrImageLayout.of({
    required Size box,
    required int imageWidth,
    required int imageHeight,
    required ScreenOcrImageFit fit,
  }) {
    if (imageWidth <= 0 || imageHeight <= 0) {
      return const ScreenOcrImageLayout(origin: Offset.zero, scale: 1);
    }
    switch (fit) {
      case ScreenOcrImageFit.window:
        // 截图宽 = 窗口宽 × dpr；按宽换算，高度方向同一比例（截图与窗口同形）。
        return ScreenOcrImageLayout(
          origin: Offset.zero,
          scale: box.width / imageWidth,
        );
      case ScreenOcrImageFit.contain:
        final double scale = math.min(
          box.width / imageWidth,
          box.height / imageHeight,
        );
        return ScreenOcrImageLayout(
          origin: Offset(
            (box.width - imageWidth * scale) / 2,
            (box.height - imageHeight * scale) / 2,
          ),
          scale: scale,
        );
    }
  }

  final Offset origin;
  final double scale;

  /// 送检图像素坐标的框 → 页面坐标。
  Rect toPage(Rect imageRect) => _scaleRect(imageRect, scale).shift(origin);

  /// 整张图在页面上占的框。
  Rect imageRect(int imageWidth, int imageHeight) =>
      origin & Size(imageWidth * scale, imageHeight * scale);
}

/// 截图 / 照片 + 识别结果的全屏选取页。图按 [fit] 摆放（截屏与窗口重合，照片
/// 等比居中），行框描边；点字把整行交给应用内查词弹窗（弹窗宿主挂在导航之上，
/// 盖在本页上面）。点空白或关闭钮退出。
class ScreenOcrPickerPage extends StatelessWidget {
  const ScreenOcrPickerPage({
    required this.imageBytes,
    required this.result,
    this.fit = ScreenOcrImageFit.window,
    super.key,
  });

  final Uint8List imageBytes;
  final SystemOcrPageResult result;
  final ScreenOcrImageFit fit;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    // 行框：MD3 主题色描边 + 浅主题色底。Apple 单色强调色（浅色黑 / 深色白）压在
    // 任意截图上不保证看得见，行框改成「实况文本」那样的白色半透明底 + 白描边——
    // 截图已压暗 18%，白框在亮暗两种画面上都分得出来。
    final Color lineFill = glass
        ? Colors.white.withValues(alpha: 0.16)
        : colors.primary.withValues(alpha: 0.12);
    final Color lineStroke = glass
        ? Colors.white.withValues(alpha: 0.9)
        : colors.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final ScreenOcrImageLayout layout = ScreenOcrImageLayout.of(
            box: constraints.biggest,
            imageWidth: result.imageWidth,
            imageHeight: result.imageHeight,
            fit: fit,
          );
          return GestureDetector(
            key: const ValueKey<String>('screen_ocr_picker_surface'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) {
              final ScreenOcrHit? hit = screenOcrHitTest(
                lines: result.lines,
                point: details.localPosition - layout.origin,
                scale: layout.scale,
              );
              if (hit == null) {
                Navigator.of(context).maybePop();
                return;
              }
              FloatingLyricLookupNotifier.instance.requestLookup(
                hit.line.text,
                hit.charIndex,
                selectionRect: hit.charRect.shift(layout.origin),
              );
            },
            child: Stack(
              children: <Widget>[
                Positioned.fromRect(
                  rect: layout.imageRect(result.imageWidth, result.imageHeight),
                  child: Image.memory(
                    imageBytes,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.18),
                  ),
                ),
                for (final SystemOcrTextLine line in result.lines)
                  Positioned.fromRect(
                    rect: layout.toPage(line.rect).inflate(2),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: lineFill,
                          border: Border.all(color: lineStroke, width: 1.5),
                          // 两套设计系统都给行框 4 圆角（M3E 不再是直角框）。
                          borderRadius: const BorderRadius.all(
                            Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      // 浮动胶囊弹簧上浮淡入（减弱动态效果 / 墨水屏下静止）。
                      child: FushiStaggeredEntrance(
                        index: 0,
                        child: _hintPill(
                          context,
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              FushiIconButtonControl(
                                key: const ValueKey<String>(
                                  'screen_ocr_picker_close',
                                ),
                                tooltip: MaterialLocalizations.of(
                                  context,
                                ).closeButtonTooltip,
                                icon: const FushiIcon(FushiIcons.close),
                                onPressed: () =>
                                    Navigator.of(context).maybePop(),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 16),
                                child: Text(
                                  t.floating_ball_ocr_pick_hint,
                                  style: context.fushiType.labelLarge.copyWith(
                                    color: glass
                                        ? appleColorsOf(context).label
                                        : fushiFloatingToolbarPalette(
                                            context,
                                          ).foreground,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 左上角「关闭 + 提示」胶囊：浮在截图上的控件层。MD3 是 M3E 悬浮胶囊；Apple 是液态玻璃胶囊（截图本身是 Flutter 图像，玻璃能折射到它），
  /// 降低透明度时由 [fushiGlassSettings] 回落实色。
  Widget _hintPill(BuildContext context, Widget child) {
    if (isGlassDesign(context)) {
      return GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiGlassSettings(context),
        shape: const LiquidRoundedSuperellipse(borderRadius: 22),
        child: child,
      );
    }
    // M3E 悬浮工具栏同一套胶囊（surfaceContainer + Elevation 3 投影，墨水屏
    // 改描边），与阅读器 / 首页的浮动工具栏一致。
    return FushiFloatingPill(
      color: fushiFloatingToolbarPalette(context).container,
      padding: EdgeInsets.zero,
      child: child,
    );
  }
}
