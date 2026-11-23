/// PV 拼贴的纹理与逐帧绘制（移植 folia `hanabi/collage/collagePainters.ts`、`collageViews.ts`、`unitCollage.ts`）。
///
/// 纹理：每种拼贴件先在离屏画布上画好（带白边、硬阴影、花纹），按 2 倍渲染倍率栅格成 [ui.Image]，按 key 缓存在
/// 一个场景单元里（[HanabiCollageCache]），单元销毁时一起释放。贴纸是「模切贴纸」：形状 + 一圈粗白边 + 偏移浅阴影；
/// 胶带半透明、两端锯齿；装饰带是可以平铺的一节（胶片 / 剪切线 / 蕾丝花边），沿带子方向重复。
///
/// 绘制：[paintCollageItems] 按 t 给一个镜头的拼贴件摆姿态（back = 装饰带、重复字、纸片、窗口、后层贴纸；
/// front = 贴纸、胶带、标签、图标贴纸、升空小图标、贴纸气球）。Pixi 容器的 alpha 是逐个子件相乘、不做离屏合成，
/// 这里同样把 alpha 乘到每一笔上。[HanabiUnitCollage] 是整个场景单元一份的网点底纹与左缘竖胶片。
///
/// 片尾卡等别处复用：[HanabiCollageCache.strip] 取一节装饰带纹理，[paintCollageStrip] 按 folia 的擦出 / 走片规则
/// 画一条带子（坐标为当前画布坐标）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage_plan.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

/// 装饰字用的圆体（folia `POP_FONT_FAMILIES`）：系统里有就用，没有回落到主题字体。
const List<String> kHanabiPopFontFamilies = <String>[
  'M PLUS Rounded 1c',
  'Zen Maru Gothic',
  'Kosugi Maru',
  'Hiragino Maru Gothic ProN',
  'Arial Rounded MT Bold',
  'Yu Gothic UI',
  'Meiryo UI',
  'Microsoft YaHei UI',
];

/// 贴纸纹理的基准边长（逻辑像素）。
const double kCollageStickerPx = 112;

/// 栅格倍率（folia 按渲染倍率钳在 1..2；这里取上限 2）。
const double _scale = 2;

Color _css(int color, [double alpha = 1]) => rgbColor(color, alpha);

/// 一张拼贴纹理：图像 + 逻辑尺寸。
class CollageTexture {
  CollageTexture(this.image, this.width, this.height);
  final ui.Image image;
  final double width;
  final double height;
}

// ─── 形状路径 ───────────────────────────────────────────────────────────

ui.Path _pathHeart(double c, double r) => ui.Path()
  ..moveTo(c, c + r * 0.85)
  ..cubicTo(
    c - r * 1.25,
    c + r * 0.05,
    c - r * 0.95,
    c - r * 0.95,
    c,
    c - r * 0.42,
  )
  ..cubicTo(
    c + r * 0.95,
    c - r * 0.95,
    c + r * 1.25,
    c + r * 0.05,
    c,
    c + r * 0.85,
  );

ui.Path _pathStar(double c, double r, int points, double inner) {
  final ui.Path p = ui.Path();
  const double rotation = -math.pi / 2;
  for (int i = 0; i < points * 2; i++) {
    final double radius = i.isEven ? r : r * inner;
    final double angle = rotation + i * math.pi / points;
    final double x = c + math.cos(angle) * radius;
    final double y = c + math.sin(angle) * radius;
    if (i == 0) {
      p.moveTo(x, y);
    } else {
      p.lineTo(x, y);
    }
  }
  return p..close();
}

ui.Path _pathSparkle(double c, double r) {
  final double pinch = r * 0.16;
  return ui.Path()
    ..moveTo(c, c - r)
    ..quadraticBezierTo(c + pinch, c - pinch, c + r, c)
    ..quadraticBezierTo(c + pinch, c + pinch, c, c + r)
    ..quadraticBezierTo(c - pinch, c + pinch, c - r, c)
    ..quadraticBezierTo(c - pinch, c - pinch, c, c - r)
    ..close();
}

ui.Path _pathFlower(double c, double r) {
  final ui.Path p = ui.Path();
  for (int i = 0; i < 5; i++) {
    final double angle = -math.pi / 2 + i * math.pi * 2 / 5;
    p.addOval(
      Rect.fromCircle(
        center: Offset(
          c + math.cos(angle) * r * 0.55,
          c + math.sin(angle) * r * 0.55,
        ),
        radius: r * 0.42,
      ),
    );
  }
  return p;
}

ui.Path _pathCloud(double c, double r) {
  const List<(double, double, double)> bumps = <(double, double, double)>[
    (-0.5, 0.15, 0.38),
    (-0.12, -0.18, 0.48),
    (0.38, -0.02, 0.42),
    (0.62, 0.25, 0.28),
    (0.05, 0.3, 0.4),
  ];
  final ui.Path p = ui.Path();
  for (final (double dx, double dy, double k) in bumps) {
    p.addOval(
      Rect.fromCircle(center: Offset(c + dx * r, c + dy * r), radius: k * r),
    );
  }
  return p;
}

ui.Path _pathRibbon(double c, double r) => ui.Path()
  ..moveTo(c, c)
  ..cubicTo(
    c - r * 0.5,
    c - r * 0.75,
    c - r * 1.05,
    c - r * 0.55,
    c - r * 0.95,
    c,
  )
  ..cubicTo(c - r * 1.05, c + r * 0.55, c - r * 0.5, c + r * 0.75, c, c)
  ..cubicTo(
    c + r * 0.5,
    c - r * 0.75,
    c + r * 1.05,
    c - r * 0.55,
    c + r * 0.95,
    c,
  )
  ..cubicTo(c + r * 1.05, c + r * 0.55, c + r * 0.5, c + r * 0.75, c, c)
  ..addOval(Rect.fromCircle(center: Offset(c, c), radius: r * 0.24));

ui.Path _pathCat(double c, double r) => ui.Path()
  ..addOval(Rect.fromCircle(center: Offset(c, c + r * 0.12), radius: r * 0.78))
  ..moveTo(c - r * 0.72, c - r * 0.2)
  ..lineTo(c - r * 0.62, c - r * 0.95)
  ..lineTo(c - r * 0.12, c - r * 0.6)
  ..close()
  ..moveTo(c + r * 0.72, c - r * 0.2)
  ..lineTo(c + r * 0.62, c - r * 0.95)
  ..lineTo(c + r * 0.12, c - r * 0.6)
  ..close();

ui.Path _pathBubble(double c, double r) {
  final double w = r;
  final double h = r * 0.72;
  final double top = c - h * 0.95;
  final double radius = h * 0.55;
  return ui.Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(c - w, top, w * 2, h * 1.6),
        Radius.circular(radius),
      ),
    )
    ..moveTo(c - w * 0.35, top + h * 1.55)
    ..lineTo(c - w * 0.62, top + h * 2.15)
    ..lineTo(c - w * 0.02, top + h * 1.55)
    ..close();
}

/// 贴纸形状的路径（中心 (c, c)、半径 r）。
ui.Path collageShapePath(StickerShape shape, double c, double r) =>
    switch (shape) {
      StickerShape.heart => _pathHeart(c, r),
      StickerShape.star => _pathStar(c, r, 5, 0.48),
      StickerShape.sparkle => _pathSparkle(c, r),
      StickerShape.flower => _pathFlower(c, r),
      StickerShape.cloud => _pathCloud(c, r),
      StickerShape.ribbon => _pathRibbon(c, r),
      StickerShape.cat => _pathCat(c, r),
      StickerShape.bubble => _pathBubble(c, r),
    };

/// lucide `Flower`（24 单位、描线图标）：花心圆 + 四瓣弧线 + 八道短线。
ui.Path _lucideFlower() {
  const Radius r = Radius.circular(4.5);
  final ui.Path p = ui.Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 3))
    ..moveTo(12, 16.5)
    ..arcToPoint(const Offset(7.5, 12), radius: r, largeArc: true)
    ..arcToPoint(const Offset(12, 7.5), radius: r, largeArc: true)
    ..arcToPoint(const Offset(16.5, 12), radius: r, largeArc: true)
    ..arcToPoint(const Offset(12, 16.5), radius: r, largeArc: true);
  const List<(double, double, double, double)> ticks =
      <(double, double, double, double)>[
        (12, 7.5, 12, 9),
        (7.5, 12, 9, 12),
        (16.5, 12, 15, 12),
        (12, 16.5, 12, 15),
        (8, 8, 9.88, 9.88),
        (14.12, 9.88, 16, 8),
        (8, 16, 9.88, 14.12),
        (14.12, 14.12, 16, 16),
      ];
  for (final (double x0, double y0, double x1, double y1) in ticks) {
    p
      ..moveTo(x0, y0)
      ..lineTo(x1, y1);
  }
  return p;
}

// ─── 纹理缓存 ───────────────────────────────────────────────────────────

/// 一个场景单元的拼贴纹理缓存（folia `createCollageTextureCache`）。
class HanabiCollageCache {
  HanabiCollageCache({required String? fallbackFont})
    : _fallback = fallbackFont;

  final String? _fallback;
  final Map<String, CollageTexture> _cache = <String, CollageTexture>{};
  bool _disposed = false;

  int get length => _cache.length;

  TextStyle _popStyle(double px) => TextStyle(
    fontFamily: kHanabiPopFontFamilies.first,
    fontFamilyFallback: <String>[...kHanabiPopFontFamilies.skip(1), ?_fallback],
    fontSize: px,
    fontWeight: FontWeight.w800,
    height: 1,
  );

  TextPainter _painter(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  double _measure(String text, double px) {
    final TextPainter p = _painter(text, _popStyle(px));
    final double w = p.width;
    p.dispose();
    return w;
  }

  /// 以 (x, y) 为中心画一行字（Canvas2D 的 textAlign center + textBaseline middle）。
  void _text(
    ui.Canvas canvas,
    String text,
    double px,
    double x,
    double y, {
    Color? fill,
    Paint? stroke,
  }) {
    final TextStyle base = _popStyle(px);
    final TextPainter p = _painter(
      text,
      stroke != null
          ? base.copyWith(foreground: stroke)
          : base.copyWith(color: fill),
    );
    p.paint(canvas, Offset(x - p.width / 2, y - p.height / 2));
    p.dispose();
  }

  CollageTexture _cached(
    String key,
    double width,
    double height,
    void Function(ui.Canvas canvas) paint,
  ) {
    final CollageTexture? hit = _cache[key];
    if (hit != null) return hit;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.scale(_scale);
    paint(canvas);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(
      math.max(1, (width * _scale).ceil()),
      math.max(1, (height * _scale).ceil()),
    );
    picture.dispose();
    final CollageTexture texture = CollageTexture(image, width, height);
    if (!_disposed) _cache[key] = texture;
    return texture;
  }

  /// 贴纸：形状 + 粗白边 + 偏移阴影 + 左上高光（猫脸加五官，对话框加字）。
  CollageTexture sticker(StickerShape shape, int color, String? label) =>
      _cached(
        'sticker:${shape.name}:$color:${label ?? ''}',
        kCollageStickerPx,
        kCollageStickerPx,
        (ui.Canvas canvas) {
          const double side = kCollageStickerPx;
          const double c = side / 2;
          const double r = side * 0.34;
          final ui.Path path = collageShapePath(shape, c, r);
          Paint stroke(Color color) => Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = side * 0.13
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round
            ..color = color;
          const Color shade = Color.fromRGBO(30, 16, 48, 0.28);
          canvas
            ..save()
            ..translate(side * 0.035, side * 0.05)
            ..drawPath(path, stroke(shade))
            ..drawPath(path, Paint()..color = shade)
            ..restore();
          canvas
            ..drawPath(path, stroke(const Color(0xFFFFFFFF)))
            ..drawPath(path, Paint()..color = const Color(0xFFFFFFFF))
            ..drawPath(path, Paint()..color = _css(color));
          canvas
            ..save()
            ..clipPath(path)
            ..translate(c - r * 0.35, c - r * 0.4)
            ..rotate(-0.6)
            ..drawOval(
              Rect.fromCenter(
                center: Offset.zero,
                width: r * 0.56,
                height: r * 0.32,
              ),
              Paint()..color = const Color.fromRGBO(255, 255, 255, 0.4),
            )
            ..restore();
          if (shape == StickerShape.cat) {
            final Paint ink = Paint()..color = _css(kCollageInk);
            canvas
              ..drawCircle(Offset(c - r * 0.3, c + r * 0.08), r * 0.08, ink)
              ..drawCircle(Offset(c + r * 0.3, c + r * 0.08), r * 0.08, ink);
            final ui.Path mouth = ui.Path()
              ..arcTo(
                Rect.fromCircle(
                  center: Offset(c - r * 0.09, c + r * 0.28),
                  radius: r * 0.09,
                ),
                0.1,
                math.pi - 0.2,
                true,
              )
              ..arcTo(
                Rect.fromCircle(
                  center: Offset(c + r * 0.09, c + r * 0.28),
                  radius: r * 0.09,
                ),
                0.1,
                math.pi - 0.2,
                false,
              );
            canvas.drawPath(
              mouth,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = r * 0.07
                ..strokeCap = StrokeCap.round
                ..strokeJoin = StrokeJoin.round
                ..color = _css(kCollageInk),
            );
            final Paint blush = Paint()
              ..color = const Color.fromRGBO(255, 120, 160, 0.55);
            canvas
              ..drawOval(
                Rect.fromCenter(
                  center: Offset(c - r * 0.5, c + r * 0.3),
                  width: r * 0.24,
                  height: r * 0.14,
                ),
                blush,
              )
              ..drawOval(
                Rect.fromCenter(
                  center: Offset(c + r * 0.5, c + r * 0.3),
                  width: r * 0.24,
                  height: r * 0.14,
                ),
                blush,
              );
          }
          if (label != null) {
            double px = r * 0.62;
            while (px > 8 && _measure(label, px) > r * 1.7) {
              px -= 1;
            }
            _text(canvas, label, px, c, c - r * 0.08, fill: _css(kCollageInk));
          }
        },
      );

  /// 胶带：两端锯齿、半透明，条纹 / 圆点 / 方格花纹。
  CollageTexture tape(int color, TapePattern pattern) =>
      _cached('tape:$color:${pattern.name}', 160, 48, (ui.Canvas canvas) {
        const double length = 160;
        const double width = 48;
        const double tooth = 6;
        final ui.Path shape = ui.Path()..moveTo(0, 0);
        for (double y = 0; y <= width; y += tooth) {
          shape.lineTo(y % (tooth * 2) == 0 ? 0 : tooth * 0.7, y);
        }
        shape.lineTo(length, width);
        for (double y = width; y >= 0; y -= tooth) {
          shape.lineTo(y % (tooth * 2) == 0 ? length : length - tooth * 0.7, y);
        }
        shape.close();
        canvas
          ..drawPath(shape, Paint()..color = _css(color, 0.78))
          ..save()
          ..clipPath(shape);
        switch (pattern) {
          case TapePattern.stripe:
            final Paint p = Paint()
              ..color = const Color.fromRGBO(255, 255, 255, 0.55)
              ..strokeWidth = 7
              ..style = PaintingStyle.stroke;
            for (double x = -width; x < length + width; x += 18) {
              canvas.drawLine(Offset(x, width), Offset(x + width, 0), p);
            }
          case TapePattern.dot:
            final Paint p = Paint()
              ..color = const Color.fromRGBO(255, 255, 255, 0.65);
            for (double y = 8; y < width; y += 16) {
              for (double x = (y / 16) % 2 == 0 ? 8 : 16; x < length; x += 16) {
                canvas.drawCircle(Offset(x, y), 3.2, p);
              }
            }
          case TapePattern.check:
            final Paint p = Paint()
              ..color = const Color.fromRGBO(255, 255, 255, 0.38);
            for (double y = 0; y < width; y += 12) {
              for (double x = (y / 12) % 2 == 0 ? 0 : 12; x < length; x += 24) {
                canvas.drawRect(Rect.fromLTWH(x, y, 12, 12), p);
              }
            }
        }
        canvas.restore();
      });

  /// 纸片 / 窗口的花纹小格（白色；平铺用）。
  CollageTexture pattern(PatchPattern kind) => _cached(
    'pattern:${kind.name}',
    24,
    24,
    (ui.Canvas canvas) {
      const double tile = 24;
      final Paint white = Paint()..color = const Color(0xFFFFFFFF);
      switch (kind) {
        case PatchPattern.grid:
          final Paint line = Paint()
            ..color = const Color(0xFFFFFFFF)
            ..strokeWidth = 1.2
            ..style = PaintingStyle.stroke;
          canvas
            ..drawLine(const Offset(0, 0.6), const Offset(tile, 0.6), line)
            ..drawLine(const Offset(0.6, 0), const Offset(0.6, tile), line);
        case PatchPattern.dots:
          canvas
            ..drawCircle(const Offset(tile / 4, tile / 4), 2.4, white)
            ..drawCircle(const Offset(tile * 3 / 4, tile * 3 / 4), 2.4, white);
        case PatchPattern.gingham:
          final Paint p = Paint()
            ..color = const Color.fromRGBO(255, 255, 255, 0.55);
          canvas
            ..drawRect(const Rect.fromLTWH(0, 0, tile / 2, tile), p)
            ..drawRect(const Rect.fromLTWH(0, 0, tile, tile / 2), p);
        case PatchPattern.plain:
          break;
      }
    },
  );

  /// 胶片：深色片基，上下两排齿孔挖空，中间三格画面（主色与两种糖果色轮着，各有一个白色小图案）。
  void _paintFilm(ui.Canvas canvas, int color, double height, double width) {
    final double frame = height * 1.18;
    canvas
      ..saveLayer(Rect.fromLTWH(0, 0, width, height), Paint())
      ..drawRect(
        Rect.fromLTWH(0, 0, width, height),
        Paint()..color = _css(kCollageInk, 0.92),
      );
    final double pitch = frame / 4;
    final double holeW = pitch * 0.48;
    final double holeH = height * 0.11;
    final Paint cut = Paint()..blendMode = BlendMode.dstOut;
    for (int k = 0; k < 12; k++) {
      final double x = k * pitch + (pitch - holeW) / 2;
      for (final double y in <double>[height * 0.07, height * 0.93 - holeH]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, holeW, holeH),
            Radius.circular(holeH * 0.3),
          ),
          cut,
        );
      }
    }
    canvas.restore();
    final int base = math.max(0, kCollageCandy.indexOf(color));
    final List<int> colors = <int>[
      color,
      kCollageCandy[(base + 2) % kCollageCandy.length],
      kCollageCandy[(base + 4) % kCollageCandy.length],
    ];
    const List<StickerShape> icons = <StickerShape>[
      StickerShape.heart,
      StickerShape.star,
      StickerShape.sparkle,
    ];
    for (int k = 0; k < 3; k++) {
      final double x = k * frame + frame * 0.07;
      final double y = height * 0.25;
      final double w = frame * 0.86;
      final double h = height * 0.5;
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, w, h),
            Radius.circular(h * 0.12),
          ),
          Paint()..color = _css(colors[k], 0.92),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.06, y + h * 0.1, w * 0.4, h * 0.16),
            Radius.circular(h * 0.08),
          ),
          Paint()..color = const Color.fromRGBO(255, 255, 255, 0.28),
        )
        ..save()
        ..translate(x + w / 2, y + h / 2)
        ..drawPath(
          collageShapePath(icons[k], 0, h * 0.24),
          Paint()..color = const Color.fromRGBO(255, 255, 255, 0.9),
        )
        ..restore();
    }
  }

  /// 剪切线：一段圆头虚线 + 底下一道浅阴影。
  void _paintCut(ui.Canvas canvas, int color, double height, double period) {
    final double line = math.max(2, height * 0.11);
    final double dash = period * 0.55;
    Paint pen(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = line
      ..color = c;
    canvas
      ..drawLine(
        Offset(line, height / 2 + line * 0.6),
        Offset(dash, height / 2 + line * 0.6),
        pen(const Color.fromRGBO(30, 16, 48, 0.35)),
      )
      ..drawLine(
        Offset(line, height / 2),
        Offset(dash, height / 2),
        pen(_css(color)),
      );
  }

  /// 蕾丝花边：白色带身、上下小波浪边（波浪里镂孔）、边上一排孔眼，中间穿一条糖果色缎带。
  void _paintLace(
    ui.Canvas canvas,
    int color,
    double height,
    double scallop,
    double width,
  ) {
    final double top = height * 0.25;
    final double bottom = height * 0.75;
    final List<double> centers = <double>[scallop, scallop * 3];
    ui.Path shape(double dy) {
      final ui.Path p = ui.Path()
        ..addRect(Rect.fromLTWH(0, top + dy, width, bottom - top));
      for (final double cx in centers) {
        p
          ..addArc(
            Rect.fromCircle(center: Offset(cx, top + dy), radius: scallop),
            0,
            -math.pi,
          )
          ..addArc(
            Rect.fromCircle(center: Offset(cx, bottom + dy), radius: scallop),
            math.pi,
            -math.pi,
          );
      }
      return p;
    }

    canvas
      ..saveLayer(Rect.fromLTWH(0, 0, width, height), Paint())
      ..drawPath(
        shape(height * 0.05),
        Paint()..color = const Color.fromRGBO(30, 16, 48, 0.22),
      )
      ..drawPath(
        shape(0),
        Paint()..color = const Color.fromRGBO(255, 255, 255, 0.96),
      );
    final Paint cut = Paint()..blendMode = BlendMode.dstOut;
    for (final double cx in centers) {
      for (final (double y, double radius) in <(double, double)>[
        (top - scallop * 0.45, scallop * 0.3),
        (bottom + scallop * 0.45, scallop * 0.3),
        (top + height * 0.075, height * 0.035),
        (bottom - height * 0.075, height * 0.035),
      ]) {
        canvas.drawCircle(Offset(cx, y), math.max(0.8, radius), cut);
      }
    }
    canvas.restore();
    final double ribbonTop = height * 0.4;
    final double ribbonHeight = height * 0.2;
    canvas
      ..drawRect(
        Rect.fromLTWH(0, ribbonTop, width, ribbonHeight),
        Paint()..color = _css(color),
      )
      ..drawRect(
        Rect.fromLTWH(
          0,
          ribbonTop + ribbonHeight * 0.18,
          width,
          math.max(1, ribbonHeight * 0.16),
        ),
        Paint()..color = const Color.fromRGBO(255, 255, 255, 0.45),
      )
      ..drawRect(
        Rect.fromLTWH(
          0,
          ribbonTop + ribbonHeight * 0.86,
          width,
          math.max(1, ribbonHeight * 0.14),
        ),
        Paint()..color = const Color.fromRGBO(43, 31, 61, 0.16),
      );
  }

  /// 装饰带沿长度方向平铺的一节（纹理高 = 带子粗细）。
  CollageTexture strip(StripStyle style, int color, double thickness) {
    final double height = math.max(10, thickness.roundToDouble());
    final double width = switch (style) {
      StripStyle.film => (height * 1.18 * 3).roundToDouble(),
      StripStyle.cut => math.max(10, height * 0.9),
      StripStyle.lace => math.max(3, height * 0.21) * 4,
    };
    return _cached(
      'strip:${style.name}:$color:$height',
      width,
      height,
      (ui.Canvas canvas) => switch (style) {
        StripStyle.film => _paintFilm(canvas, color, height, width),
        StripStyle.cut => _paintCut(canvas, color, height, width),
        StripStyle.lace => _paintLace(canvas, color, height, width / 4, width),
      },
    );
  }

  /// 剪刀：两个指环 + 两片交叉的刀刃，白身深色描边，尖朝 +x。
  CollageTexture scissors(double thickness) {
    final double side = math.max(20, (thickness * 2.3).roundToDouble());
    return _cached('scissors:$side', side, side, (ui.Canvas canvas) {
      final double c = side / 2;
      final double ring = side * 0.15;
      for (final int dir in <int>[-1, 1]) {
        final ui.Path blade = ui.Path()
          ..moveTo(c - side * 0.12, c + dir * side * 0.1)
          ..quadraticBezierTo(
            c + side * 0.15,
            c - dir * side * 0.02,
            c + side * 0.46,
            c - dir * side * 0.06,
          )
          ..quadraticBezierTo(
            c + side * 0.12,
            c + dir * side * 0.08,
            c - side * 0.12,
            c + dir * side * 0.16,
          )
          ..close();
        canvas
          ..drawPath(
            blade,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = side * 0.09
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round
              ..color = _css(kCollageInk),
          )
          ..drawPath(blade, Paint()..color = const Color(0xFFFFFFFF));
      }
      for (final int dir in <int>[-1, 1]) {
        final Offset center = Offset(c - side * 0.28, c + dir * side * 0.2);
        canvas
          ..drawCircle(
            center,
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = side * 0.1
              ..color = _css(kCollageInk),
          )
          ..drawCircle(
            center,
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = side * 0.06
              ..color = _css(kCollageCandy[0]),
          );
      }
      canvas.drawCircle(
        Offset(c - side * 0.06, c),
        side * 0.04,
        Paint()..color = _css(kCollageInk),
      );
    });
  }

  /// 重复字的一个单元：空心描边字 + 间隔。
  CollageTexture echo(String text, int color, double size, bool vertical) {
    final double px = math.max(10, size.roundToDouble());
    final double textWidth = _measure(text, px);
    final double gapX = vertical ? px * 0.2 : px * 0.6;
    final double width = (textWidth + gapX * 2).ceilToDouble();
    final double height = (px * (vertical ? 1.3 : 1.25)).ceilToDouble();
    return _cached(
      'echo:$text:$color:$px:$vertical',
      width,
      height,
      (ui.Canvas canvas) => _text(
        canvas,
        text,
        px,
        width / 2,
        height * 0.52,
        stroke: Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(1.5, px * 0.045)
          ..color = _css(color),
      ),
    );
  }

  /// 粗字贴纸（开场标题卡的曲名）：硬阴影 → 白边 → 彩色字 → 深色细描边。
  CollageTexture sound(String text, int color, double size) {
    final double px = math.max(12, size.roundToDouble());
    final double stroke = px * 0.2;
    final double shadow = px * 0.09;
    final double width = (_measure(text, px) + stroke * 2 + shadow + px * 0.2)
        .ceilToDouble();
    final double height = (px * 1.35 + stroke * 2 + shadow).ceilToDouble();
    return _cached('sound:$text:$color:$px', width, height, (ui.Canvas canvas) {
      final double x = width / 2 - shadow / 2;
      final double y = height / 2 - shadow / 2;
      Paint pen(Color c, double w) => Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = w
        ..color = c;
      _text(
        canvas,
        text,
        px,
        x + shadow,
        y + shadow,
        stroke: pen(const Color.fromRGBO(43, 31, 61, 0.9), stroke * 2),
      );
      _text(
        canvas,
        text,
        px,
        x,
        y,
        stroke: pen(const Color(0xFFFFFFFF), stroke * 2),
      );
      _text(canvas, text, px, x, y, fill: _css(color));
      _text(
        canvas,
        text,
        px,
        x,
        y,
        stroke: pen(
          const Color.fromRGBO(43, 31, 61, 0.85),
          math.max(1, px * 0.04),
        ),
      );
    });
  }

  /// 图标贴纸：图标描线 + 粗白边 + 浅阴影；边长 size。没有 lucide 图标库，一律画 lucide 的 Flower。
  CollageTexture icon(String name, int color, double size) {
    final double side = math.max(16, size.roundToDouble());
    return _cached('icon:-:$color:$side', side, side, (ui.Canvas canvas) {
      final double pad = side * 0.16;
      final double k = (side - pad * 2) / 24;
      canvas
        ..translate(pad, pad)
        ..scale(k);
      final ui.Path path = _lucideFlower();
      void draw(Color stroke, double width, [double dx = 0, double dy = 0]) {
        canvas
          ..save()
          ..translate(dx, dy)
          ..drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round
              ..strokeWidth = width
              ..color = stroke,
          )
          ..restore();
      }

      draw(const Color.fromRGBO(30, 16, 48, 0.3), 7.2, 0.7, 1);
      draw(const Color(0xFFFFFFFF), 7.2);
      draw(_css(color), 2.8);
    });
  }

  /// 标签：圆角胶囊里一行深色小字（深色硬影 + 白边 + 彩色底）。
  CollageTexture label(String text, int color, double size) {
    final double px = math.max(10, size.roundToDouble());
    final double padX = px * 0.7;
    final double height = (px * 1.7).ceilToDouble();
    final double width = (_measure(text, px) + padX * 2).ceilToDouble();
    return _cached('label:$text:$color:$px', width + 4, height + 4, (
      ui.Canvas canvas,
    ) {
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(3, 3, width, height),
            Radius.circular(height / 2),
          ),
          Paint()..color = const Color.fromRGBO(43, 31, 61, 0.85),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, width, height),
            Radius.circular(height / 2),
          ),
          Paint()..color = const Color(0xFFFFFFFF),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(2, 2, width - 4, height - 4),
            Radius.circular((height - 4) / 2),
          ),
          Paint()..color = _css(color),
        );
      _text(
        canvas,
        text,
        px,
        width / 2,
        height * 0.54,
        fill: _css(kCollageInk),
      );
    });
  }

  void dispose() {
    _disposed = true;
    for (final CollageTexture t in _cache.values) {
      t.image.dispose();
    }
    _cache.clear();
  }
}

// ─── 画纹理 ─────────────────────────────────────────────────────────────

final Paint _imagePaint = Paint()..filterQuality = FilterQuality.medium;

/// 像 Pixi 精灵那样画一张纹理：锚点 (ax, ay)、平移、旋转、缩放、透明度。
void drawCollageSprite(
  ui.Canvas canvas,
  CollageTexture texture, {
  required double x,
  required double y,
  double rotation = 0,
  double scaleX = 1,
  double scaleY = 1,
  double alpha = 1,
  double anchorX = 0.5,
  double anchorY = 0.5,
}) {
  if (alpha <= 0.002 || scaleX == 0 || scaleY == 0) return;
  canvas
    ..save()
    ..translate(x, y);
  if (rotation != 0) canvas.rotate(rotation);
  canvas.scale(scaleX, scaleY);
  _imagePaint.color = Color.fromRGBO(255, 255, 255, clamp01(alpha));
  canvas.drawImageRect(
    texture.image,
    Rect.fromLTWH(
      0,
      0,
      texture.image.width.toDouble(),
      texture.image.height.toDouble(),
    ),
    Rect.fromLTWH(
      -texture.width * anchorX,
      -texture.height * anchorY,
      texture.width,
      texture.height,
    ),
    _imagePaint,
  );
  canvas.restore();
}

/// 像 Pixi 平铺精灵那样把纹理平铺进 [rect]（当前画布坐标），tile 原点在 rect 左上 + (tileX, tileY)。
void drawCollageTiling(
  ui.Canvas canvas,
  CollageTexture texture,
  Rect rect, {
  double tileX = 0,
  double tileY = 0,
  double alpha = 1,
  int? tint,
}) {
  if (alpha <= 0.002 || rect.width <= 0 || rect.height <= 0) return;
  final double sx = texture.width / texture.image.width;
  final double sy = texture.height / texture.image.height;
  final Float64List matrix = Float64List(16)
    ..[0] = sx
    ..[5] = sy
    ..[10] = 1
    ..[12] = rect.left + tileX
    ..[13] = rect.top + tileY
    ..[15] = 1;
  final Paint paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..shader = ui.ImageShader(
      texture.image,
      TileMode.repeated,
      TileMode.repeated,
      matrix,
    )
    ..color = Color.fromRGBO(255, 255, 255, clamp01(alpha));
  if (tint != null) {
    paint.colorFilter = ColorFilter.mode(rgbColor(tint), BlendMode.modulate);
  }
  canvas.drawRect(rect, paint);
}

void _rect(ui.Canvas canvas, Rect rect, int color, double alpha) {
  if (alpha <= 0.002 || rect.width <= 0 || rect.height <= 0) return;
  canvas.drawRect(rect, Paint()..color = rgbColor(color, clamp01(alpha)));
}

/// 弹出：0.32 秒 easeOutBack(2.4) 到 1。
double _popIn(double time, double at, [double duration = 0.32]) =>
    easeOutBack((time - at) / duration, 2.4);

/// 退场进度 0..1。
double _leave(double time, double exitAt, double exitDuration) =>
    clamp01((time - exitAt) / math.max(exitDuration, 0.05));

/// 贴纸精灵的缩放：形状半径约是纹理边长的 0.34，加白边约 0.4。
double _stickerScale(double size) => size / (kCollageStickerPx * 0.8);

/// 一条装饰带（folia collageViews 的 strip 件）：从 [StripItem.from] 那一端擦出，退场朝另一端收走；
/// 图案钉在整条带上并按 speed 走片；剪切线另有一把一开一合的剪刀。坐标为当前画布坐标。
void paintCollageStrip(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  StripItem item,
  double time, {
  double alpha = 1,
}) {
  final double raw = clamp01(
    (time - item.at) /
        switch (item.style) {
          StripStyle.cut => 1.25,
          StripStyle.lace => 0.55,
          StripStyle.film => 0.42,
        },
  );
  final double enter = item.style == StripStyle.cut
      ? raw * raw * (3 - 2 * raw)
      : easeOutCubic(raw);
  final double exit = easeInCubic(_leave(time, item.exitAt, item.exitDuration));
  if (!(time > item.at && exit < 1)) return;
  final double half = item.length / 2;
  final double startAt = item.from < 0 ? exit : 1 - enter;
  final double endAt = item.from < 0 ? enter : 1 - exit;
  final double x0 = -half + item.length * math.min(startAt, endAt);
  final double width = item.length * math.max(0, (endAt - startAt).abs());
  final CollageTexture band = cache.strip(
    item.style,
    item.color,
    item.thickness,
  );
  final double tile = band.width <= 0 ? 1 : band.width;
  final double lift = item.thickness * 0.14;
  canvas
    ..save()
    ..translate(item.x, item.y)
    ..rotate(item.rotation);
  if (item.style == StripStyle.film) {
    _rect(
      canvas,
      Rect.fromLTWH(
        x0 + lift,
        -item.thickness / 2 + lift * 1.3,
        width,
        item.thickness,
      ),
      kCollageInk,
      0.3 * alpha,
    );
  }
  drawCollageTiling(
    canvas,
    band,
    Rect.fromLTWH(x0, -item.thickness / 2, width, item.thickness),
    tileX: wrapD(item.speed * time - (x0 + half), tile),
    alpha: alpha,
  );
  if (item.style == StripStyle.cut && raw < 1 && exit <= 0) {
    final double age = time - item.at;
    drawCollageSprite(
      canvas,
      cache.scissors(item.thickness),
      x: item.from < 0 ? x0 + width : x0,
      y: 0,
      scaleX: item.from < 0 ? 1 : -1,
      scaleY: 1 - 0.3 * math.sin(age * 16).abs(),
      alpha: clamp01(age / 0.12) * alpha,
    );
  }
  canvas.restore();
}

/// 按 t 画一个镜头的拼贴件里属于 [layer] 的那些（坐标为镜头容器坐标）。
void paintCollageItems(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  CollagePlan plan,
  CollageLayer layer,
  double time,
) {
  final bool back = layer == CollageLayer.back;
  for (final CollageItem item in plan.items) {
    switch (item) {
      case StripItem():
        if (back) paintCollageStrip(canvas, cache, item, time);
      case EchoItem():
        if (back) _paintEcho(canvas, cache, item, time);
      case PatchItem():
        if (back) _paintPatch(canvas, cache, item, time);
      case WindowItem():
        if (back) _paintWindow(canvas, cache, item, time);
      case HeadlineItem():
        if (back) _paintHeadline(canvas, cache, item, time);
      case StickerItem():
        if ((item.layer == CollageLayer.back) == back) {
          _paintSticker(canvas, cache, item, time);
        }
      case TapeItem():
        if (!back) _paintTape(canvas, cache, item, time);
      case LabelItem():
        if (!back) _paintLabel(canvas, cache, item, time);
      case PopItem():
        if (!back) _paintPop(canvas, cache, item, time);
      case WhooshItem():
        if (!back) _paintWhoosh(canvas, cache, item, time);
      case FloaterItem():
        if (!back) _paintFloater(canvas, cache, item, time);
    }
  }
}

void _paintEcho(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  EchoItem item,
  double time,
) {
  final double enter = easeOutCubic((time - item.at) / 0.6);
  final double exit = _leave(time, item.exitAt, item.exitDuration);
  final double alpha = item.alpha * enter * (1 - exit);
  if (alpha <= 0.002) return;
  final CollageTexture texture = cache.echo(
    item.text,
    item.color,
    item.size,
    item.vertical,
  );
  final double w = item.vertical ? texture.width : item.width;
  final double h = item.vertical ? item.height : texture.height;
  final double scale = 1 + 0.06 * (1 - enter);
  canvas
    ..save()
    ..translate(item.x, item.y)
    ..rotate(item.rotation)
    ..scale(scale);
  drawCollageTiling(
    canvas,
    texture,
    Rect.fromLTWH(-w / 2, -h / 2, w, h),
    tileX: item.vertical ? 0 : wrapD(item.speed * time, texture.width),
    tileY: item.vertical ? wrapD(item.speed * time, texture.height) : 0,
    alpha: alpha,
  );
  canvas.restore();
}

void _paintPatch(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  PatchItem item,
  double time,
) {
  final double enter = _popIn(time, item.at, 0.36);
  final double exit = _leave(time, item.exitAt, item.exitDuration);
  if (!(time >= item.at && exit < 1)) return;
  final double alpha = clamp01((time - item.at) / 0.12) * (1 - exit);
  final double hw = item.width / 2;
  final double hh = item.height / 2;
  final double border = math.max(3, math.min(item.width, item.height) * 0.025);
  canvas
    ..save()
    ..translate(item.x, item.y + exit * item.height * 0.15)
    ..rotate(item.rotation + 0.12 * (1 - math.min(1, enter)))
    ..scale(1.14 - 0.14 * enter);
  _rect(
    canvas,
    Rect.fromLTWH(
      -hw - border + border * 2.2,
      -hh - border + border * 2.6,
      item.width + border * 2,
      item.height + border * 2,
    ),
    kCollageInk,
    (item.dark ? 0.35 : 0.3) * alpha,
  );
  _rect(
    canvas,
    Rect.fromLTWH(
      -hw - border,
      -hh - border,
      item.width + border * 2,
      item.height + border * 2,
    ),
    0xffffff,
    (item.dark ? 0.9 : 1) * alpha,
  );
  _rect(
    canvas,
    Rect.fromLTWH(-hw, -hh, item.width, item.height),
    item.color,
    (item.dark ? 0.86 : 1) * alpha,
  );
  if (item.pattern != PatchPattern.plain) {
    drawCollageTiling(
      canvas,
      cache.pattern(item.pattern),
      Rect.fromLTWH(-hw, -hh, item.width, item.height),
      alpha: (item.dark ? 0.16 : 0.45) * alpha,
    );
  }
  canvas.restore();
}

void _paintWindow(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  WindowItem item,
  double time,
) {
  final double enter = _popIn(time, item.at, 0.34);
  final double exit = _leave(time, item.exitAt, item.exitDuration);
  if (!(time >= item.at && exit < 1)) return;
  final double alpha =
      clamp01((time - item.at) / 0.1) * (1 - easeInCubic(exit));
  final double hw = item.width / 2;
  final double hh = item.height / 2;
  final double border = math.max(2.5, item.bar * 0.12);
  final double offset = item.bar * 0.32;
  final int titleColor =
      kCollageCandy[(item.x + item.y).round().abs() % kCollageCandy.length];
  canvas
    ..save()
    ..translate(item.x, item.y)
    ..rotate(item.rotation)
    ..scale((0.86 + 0.14 * enter) * (1 - 0.12 * exit));
  // 糖果粉的硬阴影：日系 PV 的界面窗口不用灰影。
  _rect(
    canvas,
    Rect.fromLTWH(-hw + offset, -hh + offset, item.width, item.height),
    kCollageCandy[0],
    0.85 * alpha,
  );
  _rect(
    canvas,
    Rect.fromLTWH(
      -hw - border,
      -hh - border,
      item.width + border * 2,
      item.height + border * 2,
    ),
    0xffffff,
    alpha,
  );
  _rect(
    canvas,
    Rect.fromLTWH(-hw, -hh + item.bar, item.width, item.height - item.bar),
    kCollageDeepCard,
    0.62 * alpha,
  );
  _rect(
    canvas,
    Rect.fromLTWH(-hw, -hh, item.width, item.bar),
    titleColor,
    alpha,
  );
  const List<int> buttons = <int>[0xff8fb5, 0xffe27a, 0x8ff0c8];
  for (int k = 0; k < buttons.length; k++) {
    canvas.drawCircle(
      Offset(hw - item.bar * (0.55 + k * 0.6), -hh + item.bar / 2),
      item.bar * 0.21,
      Paint()..color = rgbColor(buttons[k], alpha),
    );
  }
  drawCollageSprite(
    canvas,
    cache.label(item.title, titleColor, item.bar * 0.48),
    x: -hw + item.bar * 0.25,
    y: -hh + item.bar / 2,
    scaleX: 0.92,
    scaleY: 0.92,
    anchorX: 0,
    alpha: alpha,
  );
  canvas.restore();
}

void _paintHeadline(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  HeadlineItem item,
  double time,
) {
  final double exit = _leave(time, item.exitAt, item.exitDuration);
  if (!(time >= item.at && exit < 1)) return;
  final double age = time - item.at;
  final double scale = _popIn(time, item.at, 0.4) * (1 - easeInCubic(exit));
  drawCollageSprite(
    canvas,
    cache.sound(item.text, item.color, item.size),
    x: item.x,
    y: item.y + math.sin(age * 2.1) * item.size * 0.04,
    rotation: item.rotation + math.sin(age * 1.6) * 0.015,
    scaleX: scale,
    scaleY: scale,
  );
}

void _paintSticker(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  StickerItem item,
  double time,
) {
  final double exit = _leave(
    time,
    item.exitAt,
    math.min(0.3, item.exitDuration),
  );
  if (!(time >= item.at && exit < 1)) return;
  final double enter = _popIn(time, item.at);
  final double age = time - item.at;
  final double phase = wrapD(item.x * 0.013 + item.y * 0.007, kTau);
  final double scale =
      _stickerScale(item.size) * enter * (1 - easeInCubic(exit));
  drawCollageSprite(
    canvas,
    cache.sticker(item.shape, item.color, item.label),
    x: item.x,
    y: item.y + math.sin(age * 1.9 + phase) * item.size * 0.05,
    rotation:
        item.rotation +
        (1 - math.min(1, enter)) * 0.8 +
        math.sin(age * 2.6 + phase) * 0.07 +
        exit * 0.9,
    scaleX: scale,
    scaleY: scale,
  );
}

void _paintTape(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  TapeItem item,
  double time,
) {
  final double exit = _leave(time, item.exitAt, item.exitDuration);
  if (!(time >= item.at && exit < 1)) return;
  final CollageTexture texture = cache.tape(item.color, item.pattern);
  final double sx = item.length / texture.width;
  final double sy = item.width / texture.height;
  // 「啪」地贴上：从稍大处压下来。
  final double stick = easeOutCubic((time - item.at) / 0.16);
  drawCollageSprite(
    canvas,
    texture,
    x: item.x,
    y: item.y,
    rotation: item.rotation,
    scaleX: sx * (1.25 - 0.25 * stick),
    scaleY: sy * (1.25 - 0.25 * stick),
    alpha: stick * (1 - exit),
  );
}

void _paintLabel(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  LabelItem item,
  double time,
) {
  final double exit = _leave(time, item.exitAt, item.exitDuration);
  if (!(time >= item.at && exit < 1)) return;
  final double scale = _popIn(time, item.at, 0.28) * (1 - easeInCubic(exit));
  drawCollageSprite(
    canvas,
    cache.label(item.text, item.color, item.size),
    x: item.x,
    y: item.y,
    rotation: item.rotation,
    scaleX: scale,
    scaleY: scale,
  );
}

void _paintPop(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  PopItem item,
  double time,
) {
  final double age = time - item.at;
  if (age < 0 || age > item.duration) return;
  final double fade = clamp01((age - (item.duration - 0.35)) / 0.35);
  // 跟着开花蹦出来：从小弹过 1 再落定、转着摆两下；最后往上飘着淡出。
  final double pop = easeOutBack(age / 0.24, 3);
  final double swing = math.exp(-age / 0.18) * math.sin(age * 38) * 0.22;
  final double scale = math.max(0, pop) * (1 + 0.06 * fade);
  drawCollageSprite(
    canvas,
    cache.icon(item.icon, item.color, item.size),
    x: item.x,
    y: item.y - fade * item.size * 0.6,
    rotation: item.rotation + swing,
    scaleX: scale,
    scaleY: scale,
    alpha: 1 - easeInCubic(fade),
  );
}

void _paintWhoosh(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  WhooshItem item,
  double time,
) {
  final double age = time - item.at;
  if (age < 0 || age > item.duration + 0.55) return;
  final double p = easeOutCubic(age / item.duration);
  final double scale = 0.7 + 0.3 * clamp01(age / item.duration);
  drawCollageSprite(
    canvas,
    cache.icon(item.icon, item.color, item.size),
    x: item.fromX + (item.toX - item.fromX) * p + item.size * 0.8,
    y: item.fromY + (item.toY - item.fromY) * p + item.size * 0.3,
    rotation: p * math.pi * 1.5,
    scaleX: scale,
    scaleY: scale,
    alpha:
        clamp01(age / 0.08) * (1 - clamp01((age - item.duration - 0.2) / 0.35)),
  );
}

void _paintFloater(
  ui.Canvas canvas,
  HanabiCollageCache cache,
  FloaterItem item,
  double time,
) {
  final double age = time - item.at;
  if (age < 0 || age > item.duration) return;
  final double p = age / item.duration;
  final double phase = wrapD(item.x * 0.017, kTau);
  final double scale =
      _stickerScale(item.size) * math.min(1, _popIn(time, item.at, 0.3));
  drawCollageSprite(
    canvas,
    cache.sticker(item.shape, item.color, null),
    x: item.x + math.sin(age * 2.2 + phase) * item.sway,
    y: item.y - item.rise * p,
    rotation: math.sin(age * 1.7 + phase) * 0.25,
    scaleX: scale,
    scaleY: scale,
    alpha: 1 - clamp01((p - 0.82) / 0.18),
  );
}

// ─── 整单元的拼贴层（unitCollage.ts）──────────────────────────────────────

/// 整个场景单元一份（屏幕坐标，不放进上升的世界里）：
/// back = 满屏网点底纹，按上升量 0.35 倍视差往下流；front = 画面左缘一条竖着的电影胶片，跟着世界上升往下走。
class HanabiUnitCollage {
  HanabiUnitCollage({
    required this.size,
    required String seed,
    required HanabiCollageCache cache,
    required this.paper,
    required this.amount,
    required this.startTime,
  }) : _cache = cache {
    final double unit = math.min(size.width, size.height);
    final HanabiRng random = hanabiRng('$seed:unit-collage');
    _thickness = math.max(20, unit * 0.055);
    _railColor =
        kCollageCandy[(random() * kCollageCandy.length).floor() %
            kCollageCandy.length];
    _drift = unit * 0.03;
  }

  final Size size;
  final HanabiCollageCache _cache;
  final int paper;

  /// tuning.collage（0..2）。
  final double amount;
  final double startTime;
  late final double _thickness;
  late final int _railColor;
  late final double _drift;

  CollageTexture _dotTile() =>
      _cache._cached('unit-dots', 26, 26, (ui.Canvas canvas) {
        const double tile = 26;
        final Paint white = Paint()..color = const Color(0xFFFFFFFF);
        canvas
          ..drawCircle(const Offset(tile / 4, tile / 4), 1.6, white)
          ..drawCircle(const Offset(tile * 3 / 4, tile * 3 / 4), 1.6, white);
      });

  void paintBack(ui.Canvas canvas, double time, double rise) {
    final double w = size.width;
    final double h = size.height;
    final CollageTexture dots = _dotTile();
    drawCollageTiling(
      canvas,
      dots,
      Rect.fromLTWH(-w * 0.1, -h * 0.1, w * 1.2, h * 1.2),
      tileY: wrapD(rise * 0.35, dots.height),
      alpha: 0.05 + 0.03 * math.min(1, amount),
      tint: paper,
    );
  }

  void paintFront(ui.Canvas canvas, double time, double rise) {
    final double w = size.width;
    final double h = size.height;
    final CollageTexture film = _cache.strip(
      StripStyle.film,
      _railColor,
      _thickness,
    );
    final double tile = film.width <= 0 ? 1 : film.width;
    final double length = h * 1.3;
    canvas
      ..save()
      ..translate(math.max(_thickness * 0.9, w * 0.022), h / 2)
      ..rotate(-math.pi / 2);
    // 胶片跟着世界往下走（本地 −x 是画面下方），外加一点自己的慢速走片。
    drawCollageTiling(
      canvas,
      film,
      Rect.fromLTWH(-length / 2, -_thickness / 2, length, _thickness),
      tileX: wrapD(-(rise + _drift * (time - startTime)), tile),
      alpha: 0.92,
    );
    canvas.restore();
  }
}
