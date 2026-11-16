import 'package:material_ui/material_ui.dart';

// =============================================================================
// 按标题生成的封面（设计稿 M2：无封面时不放空 ♪ / 图标方块）：取标题开头 1–2 个
// 字形当大字（拉丁字母取同一个词的前两个、其余取首个），底色是由标题哈希定的
// 色调渐变。同一标题恒同色同字（哈希不依赖 `String.hashCode`，跨运行稳定）。
//
// 大字是画出来的（[CustomPaint]），不进语义树、不参与 `find.text`：标题本身在
// 色块文字区另有一份。
// =============================================================================

/// 标题的稳定哈希（FNV-1a 32 位，按 UTF-16 码元）。
int fushiTitleHash(String title) {
  int hash = 0x811c9dc5;
  for (final int unit in title.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// 生成封面 / 无封面色块的色相（0–360），由 [fushiTitleHash] 定。
double fushiGeneratedCoverHue(String title) =>
    (fushiTitleHash(title.trim()) % 360).toDouble();

bool _isAsciiAlnum(String grapheme) {
  if (grapheme.length != 1) return false;
  final int c = grapheme.codeUnitAt(0);
  return (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a);
}

/// 括号、引号、标点、空白这类不适合当封面大字的开头字形。
bool _isSkippable(String grapheme) {
  if (grapheme.trim().isEmpty) return true;
  const String skip =
      '「」『』【】〔〕〈〉《》（）()[]{}<>"\'“”‘’`~!！?？.,，。、・·:：;；-—_=+*＊#＃@&/\\|♪☆★…';
  return grapheme.length == 1 && skip.contains(grapheme);
}

/// 封面大字：跳过开头的括号 / 标点后，首字形是拉丁字母或数字时取同一个词里的
/// 前两个（大写，「SAKURA」→「SA」），否则取首个字形（「超かぐや姫」→「超」）。
/// 标题里没有可用字形时为空串。
String fushiGeneratedCoverInitials(String title) {
  final List<String> graphemes = title.characters
      .skipWhile(_isSkippable)
      .toList(growable: false);
  if (graphemes.isEmpty) return '';
  final String first = graphemes.first;
  if (!_isAsciiAlnum(first)) return first;
  final StringBuffer out = StringBuffer(first.toUpperCase());
  if (graphemes.length > 1 && _isAsciiAlnum(graphemes[1])) {
    out.write(graphemes[1].toUpperCase());
  }
  return out.toString();
}

/// 生成封面的配色：渐变两端与大字色。深色主题压暗、浅色主题提亮，大字在两套
/// 主题下都与底色拉开明度。
@immutable
class FushiGeneratedCoverColors {
  const FushiGeneratedCoverColors({
    required this.start,
    required this.end,
    required this.glyph,
  });

  factory FushiGeneratedCoverColors.of(Brightness brightness, double hue) {
    Color hsl(double h, double s, double l) =>
        HSLColor.fromAHSL(1, h % 360, s, l).toColor();
    if (brightness == Brightness.dark) {
      return FushiGeneratedCoverColors(
        start: hsl(hue, 0.40, 0.36),
        end: hsl(hue + 28, 0.44, 0.22),
        glyph: hsl(hue, 0.60, 0.90),
      );
    }
    return FushiGeneratedCoverColors(
      start: hsl(hue, 0.52, 0.78),
      end: hsl(hue + 28, 0.46, 0.60),
      glyph: hsl(hue, 0.55, 0.20),
    );
  }

  final Color start;
  final Color end;
  final Color glyph;
}

/// 按 [title] 生成的封面，铺满父级。
class FushiGeneratedCover extends StatelessWidget {
  const FushiGeneratedCover({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final FushiGeneratedCoverColors colors = FushiGeneratedCoverColors.of(
      Theme.of(context).brightness,
      fushiGeneratedCoverHue(title),
    );
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[colors.start, colors.end],
          ),
        ),
        child: CustomPaint(
          size: Size.infinite,
          painter: _InitialsPainter(
            initials: fushiGeneratedCoverInitials(title),
            style: DefaultTextStyle.of(context).style.merge(
              TextStyle(
                fontWeight: FontWeight.w900,
                height: 1,
                color: colors.glyph,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 居中画封面大字：字号取短边的 0.5（一个字形）/ 0.38（两个），再按宽度收。
class _InitialsPainter extends CustomPainter {
  _InitialsPainter({required this.initials, required this.style});

  final String initials;
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (initials.isEmpty || size.isEmpty) return;
    final int count = initials.characters.length;
    final double side = size.shortestSide;
    double fontSize = side * (count > 1 ? 0.38 : 0.5);
    TextPainter layout(double s) => TextPainter(
      text: TextSpan(
        text: initials,
        style: style.copyWith(fontSize: s, letterSpacing: -0.02 * s),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    TextPainter painter = layout(fontSize);
    final double room = size.width * 0.84;
    if (painter.width > room && painter.width > 0) {
      fontSize *= room / painter.width;
      painter.dispose();
      painter = layout(fontSize);
    }
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _InitialsPainter old) =>
      old.initials != initials || old.style != style;

  @override
  SemanticsBuilderCallback? get semanticsBuilder => null;
}
