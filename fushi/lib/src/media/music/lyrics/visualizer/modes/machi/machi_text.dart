/// 町景招牌的字：按（字、字号、颜色、粗细）缓存 [TextPainter]，每帧只画不排；最近最少使用
/// 淘汰，淘汰与卸载时释放。另给几种常用的画法：缩到框里、竖排。
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class MachiTextCache {
  MachiTextCache({this.limit = 360});

  final int limit;
  TextStyle base = const TextStyle();
  final LinkedHashMap<String, TextPainter> _painters =
      LinkedHashMap<String, TextPainter>();
  final Map<String, double> _widths = <String, double>{};

  TextPainter painter(
    String text,
    double fontSize,
    Color color, {
    FontWeight weight = FontWeight.w700,
    double letterSpacing = 0,
    List<Shadow>? shadows,
  }) {
    final String key =
        '$text\u0000${fontSize.toStringAsFixed(1)}\u0000${color.toARGB32()}\u0000${weight.value}\u0000$letterSpacing\u0000${shadows?.length ?? 0}${shadows?.isNotEmpty ?? false ? shadows!.first.color.toARGB32() : 0}';
    final TextPainter? hit = _painters.remove(key);
    if (hit != null) {
      _painters[key] = hit;
      return hit;
    }
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: base.copyWith(
          fontSize: fontSize,
          color: color,
          fontWeight: weight,
          letterSpacing: letterSpacing,
          height: 1.15,
          shadows: shadows,
          decoration: TextDecoration.none,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _painters[key] = tp;
    while (_painters.length > limit) {
      final String first = _painters.keys.first;
      _painters.remove(first)?.dispose();
    }
    return tp;
  }

  /// 按 100px 参考字号量宽度（歌词屏排版用）。
  double measure(String text) {
    final double? hit = _widths[text];
    if (hit != null) return hit;
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: base.copyWith(
          fontSize: 100,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final double w = tp.width;
    tp.dispose();
    if (_widths.length > 4000) _widths.clear();
    _widths[text] = w;
    return w;
  }

  /// 字体变了（换语言 / 换主题）：全部重排。
  void reset(TextStyle style) {
    if (style == base) return;
    base = style;
    clear();
  }

  void clear() {
    for (final TextPainter tp in _painters.values) {
      tp.dispose();
    }
    _painters.clear();
    _widths.clear();
  }

  void dispose() => clear();

  /// 把一行字缩进 [box]（字高约框高的 [fill]），按 [align] 摆。
  void drawFitted(
    Canvas canvas,
    String text,
    Rect box,
    Color color, {
    double fill = 0.78,
    FontWeight weight = FontWeight.w800,
    Alignment align = Alignment.center,
    List<Shadow>? shadows,
    double letterSpacing = 0,
  }) {
    if (text.isEmpty || box.width <= 0 || box.height <= 0) return;
    final double size = (box.height * fill).clamp(4, 400).toDouble();
    final TextPainter tp = painter(
      text,
      size,
      color,
      weight: weight,
      shadows: shadows,
      letterSpacing: letterSpacing,
    );
    final double k = math.min(1, box.width / math.max(1, tp.width));
    final double w = tp.width * k;
    final double h = tp.height * k;
    final double x = box.left + (box.width - w) * (align.x + 1) / 2;
    final double y = box.top + (box.height - h) * (align.y + 1) / 2;
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(k);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  /// 竖排：一字一格从上往下（竖招牌、のぼり旗）。
  void drawVertical(
    Canvas canvas,
    String text,
    Rect box,
    Color color, {
    FontWeight weight = FontWeight.w800,
    List<Shadow>? shadows,
  }) {
    final List<String> chars = text.characters
        .where((String c) => c.trim().isNotEmpty)
        .toList();
    if (chars.isEmpty) return;
    final double cell = math.min(box.width * 0.86, box.height / chars.length);
    final double top = box.top + (box.height - cell * chars.length) / 2;
    for (int i = 0; i < chars.length; i++) {
      drawFitted(
        canvas,
        chars[i],
        Rect.fromLTWH(box.left, top + i * cell, box.width, cell),
        color,
        fill: 0.86,
        weight: weight,
        shadows: shadows,
      );
    }
  }
}
