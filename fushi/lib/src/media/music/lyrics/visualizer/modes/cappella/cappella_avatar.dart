/// 群唱的头像与表情贴纸。folia 随包带了一套头像 / 表情 PNG，Fushi 不搬图片（许可与体积）：
/// 内置头像改为按调色板生成的人像剪影 / 首字母，另有封面 3×3 切格、纯色块与用户自己的头像包；
/// 内置表情改为几种画出来的表情脸贴纸（用户表情包见 `cappella_assets.dart`）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_messages.dart';

/// 头像来源（落库值冻结，与 folia 一致；`builtin` 在 Fushi 是程序生成的头像，`custom` 是用户
/// 自己的头像包）。
enum CappellaAvatarSource {
  cover('cover'),
  generated('builtin'),
  color('color'),
  custom('custom');

  const CappellaAvatarSource(this.value);

  final String value;

  static CappellaAvatarSource fromValue(String value) {
    for (final CappellaAvatarSource s in values) {
      if (s.value == value) return s;
    }
    return cover;
  }
}

/// 生成头像的款式数（对应 folia 内置头像池）。
const int kCappellaGeneratedAvatarCount = 9;

/// 表情贴纸款式数。
const int kCappellaStickerCount = 8;

/// 封面切格：右侧固定右下格，左侧按 [kCappellaLeftAvatarIndices] 轮流（folia
/// `CappellaAvatar` 的 grid crop）。返回 0–8。
int cappellaCoverCell(CappellaSender sender) => sender.right
    ? kCappellaRightAvatarIndex
    : kCappellaLeftAvatarIndices[sender.avatarIndex %
          kCappellaLeftAvatarIndices.length];

/// 头像池（[n] 张）里取哪一张（folia `pickStableBuiltinAvatarImage`：右侧按种子固定一张，
/// 左侧在其余张里按头像下标 + 种子偏移轮流；只有一张时都用它）。
int cappellaStablePoolIndex(int n, CappellaSender sender, int seed) {
  if (n <= 1) return 0;
  final int rightIndex = lyricVisualizerSeedOf('$seed|right|$n') % n;
  if (sender.right) return rightIndex;
  final int leftOffset = lyricVisualizerSeedOf('$seed|left|${n - 1}') % (n - 1);
  final int k = (sender.avatarIndex + leftOffset).abs() % (n - 1);
  return k >= rightIndex ? k + 1 : k;
}

/// 生成头像池里取哪一款。
int cappellaGeneratedAvatarIndex(CappellaSender sender, int seed) =>
    cappellaStablePoolIndex(kCappellaGeneratedAvatarCount, sender, seed);

Color _hueShift(Color base, double degrees, double s, double l) {
  final HSLColor h = HSLColor.fromColor(base);
  return HSLColor.fromAHSL(
    1,
    (h.hue + degrees) % 360,
    s.clamp(0.0, 1.0),
    l.clamp(0.0, 1.0),
  ).toColor();
}

/// 头像首字母：有演唱者名字时取第一个字形（大写），否则 null。
String? cappellaAvatarInitial(String? name) {
  final String n = (name ?? '').trim();
  if (n.isEmpty) return null;
  return n.characters.first.toUpperCase();
}

/// 画一个圆形头像到 [rect]。[cover] 为解码好的封面（没有 / 未加载完时 cover 来源回落生成头像）。
void paintCappellaAvatar(
  Canvas canvas,
  Rect rect, {
  required CappellaAvatarSource source,
  required CappellaSender sender,
  required int seed,
  required LyricVisualizerPalette palette,
  required double opacity,
  ui.Image? cover,
  String? initial,
  CappellaImagePool? customPool,
}) {
  if (opacity <= 0) return;
  final double r = rect.width / 2;
  final Offset c = rect.center;
  // shadow-lg
  canvas.drawCircle(
    c.translate(0, 4),
    r,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.18 * opacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
  );
  canvas.save();
  canvas.clipPath(Path()..addOval(rect));
  canvas.drawRect(
    rect,
    Paint()..color = palette.secondary.withValues(alpha: opacity),
  );
  final ui.Image? custom =
      source == CappellaAvatarSource.custom &&
          customPool != null &&
          customPool.length > 0
      ? customPool.imageAt(
          cappellaStablePoolIndex(customPool.length, sender, seed),
        )
      : null;
  if (custom != null) {
    // 自定义头像：整张图 cover 进圆里。
    paintCappellaPoolImage(canvas, rect, custom, opacity, cover: true);
  } else if (source == CappellaAvatarSource.cover && cover != null) {
    final int cell = cappellaCoverCell(sender);
    final double cw = cover.width / kCappellaAvatarGridSize;
    final double ch = cover.height / kCappellaAvatarGridSize;
    final Rect src = Rect.fromLTWH(
      (cell % kCappellaAvatarGridSize) * cw,
      (cell ~/ kCappellaAvatarGridSize) * ch,
      cw,
      ch,
    );
    canvas.drawImageRect(
      cover,
      src,
      rect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(alpha: opacity),
    );
  } else if (source == CappellaAvatarSource.color) {
    // folia 色块：135° 前景色 → 强调色渐变。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, <Color>[
          palette.text.withValues(alpha: opacity),
          palette.primary.withValues(alpha: opacity),
        ]),
    );
  } else {
    _paintGenerated(
      canvas,
      rect,
      cappellaGeneratedAvatarIndex(sender, seed),
      palette,
      opacity,
      initial,
    );
  }
  canvas.restore();
  canvas.drawCircle(
    c,
    r - 0.5,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.24 * opacity),
  );
}

void _paintGenerated(
  Canvas canvas,
  Rect rect,
  int style,
  LyricVisualizerPalette palette,
  double opacity,
  String? initial,
) {
  final double hue = style * 40.0;
  final Color a = _hueShift(palette.primary, hue, 0.55, 0.62);
  final Color b = _hueShift(palette.primary, hue + 28, 0.6, 0.36);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, <Color>[
        a.withValues(alpha: opacity),
        b.withValues(alpha: opacity),
      ]),
  );
  final Color ink = Colors.white.withValues(alpha: 0.9 * opacity);
  final double w = rect.width;
  if (initial != null) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: initial,
        style: TextStyle(
          fontSize: w * 0.46,
          fontWeight: FontWeight.w700,
          color: ink,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
    return;
  }
  // 人像剪影：头 + 肩。
  final Paint p = Paint()..color = ink;
  canvas.drawCircle(
    Offset(rect.left + w * 0.5, rect.top + w * 0.4),
    w * 0.18,
    p,
  );
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(rect.left + w * 0.5, rect.top + w * 0.98),
      width: w * 0.68,
      height: w * 0.56,
    ),
    p,
  );
  // 款式点缀：不同款式在头顶加发髻 / 侧边加星点，左侧多人时一眼能分开。
  switch (style % 3) {
    case 1:
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(rect.left + w * 0.5, rect.top + w * 0.4),
          radius: w * 0.22,
        ),
        math.pi * 1.1,
        math.pi * 0.8,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.06
          ..strokeCap = StrokeCap.round
          ..color = b.withValues(alpha: 0.9 * opacity),
      );
    case 2:
      canvas.drawCircle(
        Offset(rect.left + w * 0.78, rect.top + w * 0.24),
        w * 0.07,
        Paint()..color = a.withValues(alpha: opacity),
      );
  }
}

Path _heart(Offset c, double s) {
  return Path()
    ..moveTo(c.dx, c.dy + s * 0.35)
    ..cubicTo(
      c.dx - s * 0.9,
      c.dy - s * 0.25,
      c.dx - s * 0.35,
      c.dy - s * 0.85,
      c.dx,
      c.dy - s * 0.3,
    )
    ..cubicTo(
      c.dx + s * 0.35,
      c.dy - s * 0.85,
      c.dx + s * 0.9,
      c.dy - s * 0.25,
      c.dx,
      c.dy + s * 0.35,
    )
    ..close();
}

/// 画一张表情贴纸填满 [box]（贴纸风：白描边圆脸 + 五官，款式由 [index] 定）。
void paintCappellaSticker(
  Canvas canvas,
  Rect box,
  int index,
  LyricVisualizerPalette palette,
  double opacity,
) {
  if (opacity <= 0) return;
  final int k = index % kCappellaStickerCount;
  final double s = box.shortestSide;
  final Offset c = box.center;
  final double r = s * 0.4;
  final Color face = _hueShift(palette.primary, 30 + k * 23.0, 0.75, 0.68);
  const Color ink = Color(0xFF2A2230);
  Paint fill(Color color) =>
      Paint()..color = color.withValues(alpha: color.a * opacity);
  Paint stroke(Color color, double w) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..color = color.withValues(alpha: color.a * opacity);

  canvas.drawCircle(
    c.translate(0, s * 0.03),
    r + s * 0.04,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.22 * opacity)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
  );
  canvas.drawCircle(c, r + s * 0.035, fill(Colors.white));
  canvas.drawCircle(c, r, fill(face));

  final double eyeY = c.dy - r * 0.18;
  final Offset le = Offset(c.dx - r * 0.36, eyeY);
  final Offset re = Offset(c.dx + r * 0.36, eyeY);
  final double eyeR = r * 0.1;
  final double lw = r * 0.09;
  final Rect mouthBox = Rect.fromCenter(
    center: Offset(c.dx, c.dy + r * 0.28),
    width: r * 0.8,
    height: r * 0.5,
  );
  void blush() {
    final Paint p = fill(const Color(0x66FF6F91));
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.dx - r * 0.58, c.dy + r * 0.12),
        width: r * 0.3,
        height: r * 0.16,
      ),
      p,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.dx + r * 0.58, c.dy + r * 0.12),
        width: r * 0.3,
        height: r * 0.16,
      ),
      p,
    );
  }

  void smile() =>
      canvas.drawArc(mouthBox, 0.15, math.pi - 0.3, false, stroke(ink, lw));
  void happyEyes() {
    for (final Offset e in <Offset>[le, re]) {
      canvas.drawArc(
        Rect.fromCircle(center: e.translate(0, eyeR), radius: eyeR * 1.6),
        math.pi * 1.15,
        math.pi * 0.7,
        false,
        stroke(ink, lw),
      );
    }
  }

  switch (k) {
    case 0: // 微笑
      canvas.drawCircle(le, eyeR, fill(ink));
      canvas.drawCircle(re, eyeR, fill(ink));
      smile();
      blush();
    case 1: // 大笑
      happyEyes();
      canvas.drawArc(mouthBox, 0, math.pi, true, fill(ink));
      blush();
    case 2: // 眨眼
      canvas.drawCircle(le, eyeR, fill(ink));
      canvas.drawLine(
        re.translate(-eyeR * 1.4, 0),
        re.translate(eyeR * 1.4, 0),
        stroke(ink, lw),
      );
      smile();
    case 3: // 惊讶
      canvas.drawCircle(le, eyeR * 1.3, fill(ink));
      canvas.drawCircle(re, eyeR * 1.3, fill(ink));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(c.dx, c.dy + r * 0.36),
          width: r * 0.3,
          height: r * 0.38,
        ),
        fill(ink),
      );
    case 4: // 心心眼
      canvas.drawPath(_heart(le, r * 0.34), fill(const Color(0xFFFF4D6D)));
      canvas.drawPath(_heart(re, r * 0.34), fill(const Color(0xFFFF4D6D)));
      smile();
    case 5: // 感动落泪
      canvas.drawCircle(le, eyeR, fill(ink));
      canvas.drawCircle(re, eyeR, fill(ink));
      canvas.drawArc(
        mouthBox.translate(0, r * 0.25),
        math.pi + 0.35,
        math.pi - 0.7,
        false,
        stroke(ink, lw),
      );
      final Offset tear = re.translate(r * 0.05, r * 0.32);
      canvas.drawPath(
        Path()
          ..moveTo(tear.dx, tear.dy - r * 0.16)
          ..quadraticBezierTo(
            tear.dx + r * 0.12,
            tear.dy + r * 0.04,
            tear.dx,
            tear.dy + r * 0.1,
          )
          ..quadraticBezierTo(
            tear.dx - r * 0.12,
            tear.dy + r * 0.04,
            tear.dx,
            tear.dy - r * 0.16,
          ),
        fill(const Color(0xFF5AB8FF)),
      );
    case 6: // 墨镜
      final Paint glass = fill(ink);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: le, width: r * 0.52, height: r * 0.32),
          Radius.circular(r * 0.1),
        ),
        glass,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: re, width: r * 0.52, height: r * 0.32),
          Radius.circular(r * 0.1),
        ),
        glass,
      );
      canvas.drawLine(le, re, stroke(ink, lw * 0.8));
      canvas.drawArc(
        mouthBox.translate(r * 0.12, 0),
        0.3,
        math.pi * 0.55,
        false,
        stroke(ink, lw),
      );
    default: // 唱歌 + 音符
      happyEyes();
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(c.dx, c.dy + r * 0.38),
          width: r * 0.36,
          height: r * 0.3,
        ),
        fill(ink),
      );
      blush();
      final Offset n = Offset(c.dx + r * 0.95, c.dy - r * 0.7);
      final Paint note = fill(palette.text);
      canvas.drawOval(
        Rect.fromCenter(center: n, width: r * 0.28, height: r * 0.2),
        note,
      );
      canvas.drawLine(
        n.translate(r * 0.13, 0),
        n.translate(r * 0.13, -r * 0.5),
        stroke(palette.text, r * 0.06),
      );
      canvas.drawLine(
        n.translate(r * 0.13, -r * 0.5),
        n.translate(r * 0.32, -r * 0.36),
        stroke(palette.text, r * 0.06),
      );
  }
}
