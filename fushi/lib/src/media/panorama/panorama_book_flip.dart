/// 全景收尾：飞到眼前的封面绕书脊 3D 翻开，露出当前进度的竖排正文，然后进阅读器。
///
/// 无缝交接：第 0 帧画的是舞台锁定阶段**同一张**高清带框封面、同一个矩形（[coverRect] 来自
/// Rust 那一帧的 `TARGET_RECT`），亮度 / 边框 / 尺寸逐像素一致；舞台同时停画目标。
/// 日文竖排书的书脊在右侧，封面绕右边缘翻开；翻开过程中整本书左移半个书宽，打开后的
/// 跨页居中。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/panorama/panorama_atlas.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

class PanoramaBookFlip extends StatefulWidget {
  const PanoramaBookFlip({
    super.key,
    required this.coverRect,
    required this.framedCover,
    required this.fallbackTitle,
    required this.accent,
    this.font,
    required this.excerpt,
    required this.duration,
    required this.onOpened,
  });

  /// 封面本体在舞台里的矩形（不含辉光留边）。
  final Rect coverRect;

  /// 带框高清封面（含辉光留边，比例见 [kPanoramaFramePadRatio]）；还没渲染好时为 null。
  final ui.Image? framedCover;
  final String fallbackTitle;
  final Color accent;

  /// 正文字体（小说正文字体那一套；null = 系统默认）。
  final PanoramaFontSet? font;

  /// 当前进度正文（null = 取不到，显示书名）。
  final Future<String?>? excerpt;
  final Duration duration;
  final VoidCallback onOpened;

  @override
  State<PanoramaBookFlip> createState() => _PanoramaBookFlipState();
}

class _PanoramaBookFlipState extends State<PanoramaBookFlip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  String? _text;

  @override
  void initState() {
    super.initState();
    widget.excerpt?.then((String? v) {
      if (mounted) setState(() => _text = v);
    });
    _c
      ..addStatusListener((AnimationStatus s) {
        if (s == AnimationStatus.completed) widget.onOpened();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        // 0–8% 停一拍；8–72% 翻开；之后停留读一眼。
        final double open = FushiMotion.standard.transform(
          ((_c.value - 0.08) / 0.64).clamp(0.0, 1.0),
        );
        final Rect body = widget.coverRect;
        final double shift = -body.width / 2 * open;
        final Rect page = body.shift(Offset(shift, 0));
        final double angle = math.pi * open;
        final double hingeX = page.right;
        final double cy = page.center.dy;
        final Matrix4 m = Matrix4.identity()
          ..translateByDouble(hingeX, cy, 0, 1)
          ..multiply(Matrix4.identity()..setEntry(3, 2, 0.0011))
          ..rotateY(-angle)
          ..translateByDouble(-hingeX, -cy, 0, 1);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              painter: _PagePainter(
                rect: page,
                text: _text ?? widget.fallbackTitle,
                accent: widget.accent,
                font: widget.font,
              ),
            ),
            Transform(
              transform: m,
              child: CustomPaint(
                painter: _CoverPainter(
                  rect: page,
                  image: widget.framedCover,
                  accent: widget.accent,
                  title: widget.fallbackTitle,
                  backSide: angle > math.pi / 2,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CoverPainter extends CustomPainter {
  _CoverPainter({
    required this.rect,
    required this.image,
    required this.accent,
    required this.title,
    required this.backSide,
  });

  final Rect rect;
  final ui.Image? image;
  final Color accent;
  final String title;
  final bool backSide;

  @override
  void paint(Canvas canvas, Size size) {
    if (backSide) {
      // 封面内侧（衬页）。
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect,
          Radius.circular(math.min(rect.width, rect.height) * 0.035),
        ),
        Paint()..color = const Color(0xFFE9E1D2),
      );
      return;
    }
    final ui.Image? img = image;
    if (img == null) {
      paintPanoramaFramedCover(canvas, rect, null, accent, title: title);
      return;
    }
    final Size framed = panoramaFramedSize(rect.size);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromCenter(
        center: rect.center,
        width: framed.width,
        height: framed.height,
      ),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_CoverPainter old) =>
      old.rect != rect || old.image != image || old.backSide != backSide;
}

/// 竖排时要换成竖排字形的标点。
const Map<String, String> _verticalForms = <String, String>{
  '「': '﹁',
  '」': '﹂',
  '『': '﹃',
  '』': '﹄',
  '（': '︵',
  '）': '︶',
  '、': '︑',
  '。': '︒',
  '…': '︙',
  '：': '︰',
};

/// 竖排时转 90° 画的字（长音 / 破折号 / 波浪线）。
const Set<String> _rotated = <String>{'ー', '―', '—', '〜', '～', '-'};

class _PagePainter extends CustomPainter {
  _PagePainter({
    required this.rect,
    required this.text,
    required this.accent,
    this.font,
  });

  final Rect rect;
  final String text;
  final Color accent;
  final PanoramaFontSet? font;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect r = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.min(rect.width, rect.height) * 0.02),
    );
    canvas.drawRRect(r, Paint()..color = const Color(0xFFF7F1E3));
    final double fs = rect.height / 24;
    final double colW = fs * 1.55;
    final double top = rect.top + rect.height * 0.07;
    final double bottom = rect.bottom - rect.height * 0.07;
    final int perCol = math.max(1, ((bottom - top) / (fs * 1.04)).floor());
    double x = rect.right - rect.width * 0.09 - colW / 2;
    final double minX = rect.left + rect.width * 0.08;
    final List<String> chars = text.characters.toList();
    final TextStyle style = TextStyle(
      fontSize: fs,
      fontFamily: font?.family,
      fontFamilyFallback: font == null || font!.fallback.isEmpty
          ? null
          : font!.fallback,
      color: const Color(0xFF2A2420),
      height: 1,
    );
    canvas.save();
    canvas.clipRRect(r);
    int i = 0;
    while (i < chars.length && x - colW / 2 >= minX) {
      for (int row = 0; row < perCol && i < chars.length; row++, i++) {
        final String raw = chars[i];
        final String ch = _verticalForms[raw] ?? raw;
        final TextPainter tp = TextPainter(
          text: TextSpan(text: ch, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final Offset center = Offset(x, top + fs * 1.04 * (row + 0.5));
        if (_rotated.contains(raw)) {
          canvas.save();
          canvas.translate(center.dx, center.dy);
          canvas.rotate(math.pi / 2);
          tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
          canvas.restore();
        } else {
          tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
        }
        tp.dispose();
      }
      x -= colW;
    }
    canvas.restore();
    // 书口一侧的细阴影，让纸面有厚度。
    canvas.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(_PagePainter old) => old.rect != rect || old.text != text;
}
