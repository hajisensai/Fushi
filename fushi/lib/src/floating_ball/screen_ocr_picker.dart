/// 应用内截屏识字（iOS）：截自己的窗口 → 系统 OCR（Vision）→ 选取页上点字查词。
///
/// Android 不走这里：它用 MediaProjection 截整屏，识别与选取层都在原生侧
/// （同一条流程服务应用内与应用外）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/utils.dart';

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

/// 截图 + 识别结果的全屏选取页。截图铺满（截的就是当前窗口，尺寸一致），
/// 行框描边；点字把整行交给应用内查词弹窗（弹窗宿主挂在导航之上，盖在本页上
/// 面）。点空白或关闭钮退出。
class ScreenOcrPickerPage extends StatelessWidget {
  const ScreenOcrPickerPage({
    required this.imageBytes,
    required this.result,
    super.key,
  });

  final Uint8List imageBytes;
  final SystemOcrPageResult result;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          // 截图宽 = 窗口宽 × dpr；按宽换算，高度方向同一比例（截图与窗口同形）。
          final double scale = result.imageWidth <= 0
              ? 1
              : size.width / result.imageWidth;
          return GestureDetector(
            key: const ValueKey<String>('screen_ocr_picker_surface'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) {
              final ScreenOcrHit? hit = screenOcrHitTest(
                lines: result.lines,
                point: details.localPosition,
                scale: scale,
              );
              if (hit == null) {
                Navigator.of(context).maybePop();
                return;
              }
              FloatingLyricLookupNotifier.instance.requestLookup(
                hit.line.text,
                hit.charIndex,
                selectionRect: hit.charRect,
              );
            },
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Image.memory(
                    imageBytes,
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.topCenter,
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
                    rect: _scaleRect(line.rect, scale).inflate(2),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.12),
                          border: Border.all(color: colors.primary, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Material(
                        color: colors.surface.withValues(alpha: 0.9),
                        shape: const StadiumBorder(),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              key: const ValueKey<String>(
                                'screen_ocr_picker_close',
                              ),
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).closeButtonTooltip,
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: Text(
                                t.floating_ball_ocr_pick_hint,
                                style: TextStyle(color: colors.onSurface),
                              ),
                            ),
                          ],
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
}
