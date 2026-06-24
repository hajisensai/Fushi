import 'package:characters/characters.dart';

/// ASS `\an1-9` 解码出的垂直/水平锚点。
enum SubtitleVAlign { top, middle, bottom }

enum SubtitleHAlign { left, center, right }

class SubtitleAnchor {
  final SubtitleVAlign vertical;
  final SubtitleHAlign horizontal;
  const SubtitleAnchor(this.vertical, this.horizontal);

  /// `\an` 小键盘布局：1=bottom-left .. 9=top-right。越界返回 null。
  static SubtitleAnchor? fromAnCode(int an) {
    if (an < 1 || an > 9) return null;
    final SubtitleVAlign v = an <= 3
        ? SubtitleVAlign.bottom
        : (an <= 6 ? SubtitleVAlign.middle : SubtitleVAlign.top);
    final SubtitleHAlign h = <SubtitleHAlign>[
      SubtitleHAlign.left,
      SubtitleHAlign.center,
      SubtitleHAlign.right,
    ][(an - 1) % 3];
    return SubtitleAnchor(v, h);
  }
}

/// `\pos` 归一化坐标（0..1），纯 Dart（不引 dart:ui）。
class SubtitlePos {
  final double xFraction;
  final double yFraction;
  const SubtitlePos(this.xFraction, this.yFraction);
}

/// plainText 上 [startGrapheme, endGrapheme) 半开区间的行内样式。
class SubtitleSpan {
  final int startGrapheme;
  final int endGrapheme;
  final bool italic;
  final bool bold;
  final bool underline;
  final bool strike;

  /// `\c`/`\1c` 主色，0xFFRRGGBB；null=默认。
  final int? colorArgb;

  /// `\fs` 字号（px）；null=默认。
  final double? fontSizePx;

  const SubtitleSpan({
    required this.startGrapheme,
    required this.endGrapheme,
    this.italic = false,
    this.bold = false,
    this.underline = false,
    this.strike = false,
    this.colorArgb,
    this.fontSizePx,
  });

  bool get hasStyle =>
      italic ||
      bold ||
      underline ||
      strike ||
      colorArgb != null ||
      fontSizePx != null;
}

/// 单条字幕 cue 解析出的几何 + 行内样式。`plainText` 不含任何标签，供逐字查词/制卡。
class SubtitleMarkup {
  final String plainText;
  final List<SubtitleSpan> spans;
  final SubtitleAnchor? anchor;
  final SubtitlePos? posFraction;
  const SubtitleMarkup({
    required this.plainText,
    required this.spans,
    this.anchor,
    this.posFraction,
  });
}

/// 扫描过程内部可变样式状态。
class _Style {
  bool italic = false;
  bool bold = false;
  bool underline = false;
  bool strike = false;
  int? colorArgb;
  double? fontSizePx;

  _Style clone() => _Style()
    ..italic = italic
    ..bold = bold
    ..underline = underline
    ..strike = strike
    ..colorArgb = colorArgb
    ..fontSizePx = fontSizePx;

  bool get hasStyle =>
      italic ||
      bold ||
      underline ||
      strike ||
      colorArgb != null ||
      fontSizePx != null;
}

/// 单条 cue 原文 → 结构化 markup。一趟扫描同时构建 plainText 与 span 边界。
///
/// [playResX]/[playResY] 仅用于把 `\pos` 归一化；srt/vtt 无 `\pos`，传 null 即可。
/// 不支持的标签（卡拉OK `\k`、动画 `\t/\move/\fad`、绘图 `\p`、旋转缩放等）静默删除，
/// 既不显示控制码也不产出样式。
SubtitleMarkup parseSubtitleMarkup(String raw,
    {double? playResX, double? playResY}) {
  final List<({String text, _Style style})> segments =
      <({String text, _Style style})>[];
  final StringBuffer cur = StringBuffer();
  final _Style style = _Style();
  SubtitleAnchor? anchor;
  SubtitlePos? pos;
  // ASS 绘图模式：\pN(N>0) 开启、\p0 关闭，作用域持续到本条 cue 结束。开启
  // 期间标签块之外的正文是矢量绘图命令（m/l/b 坐标），是图形不是文字，必须
  // 丢弃而非当 plainText 渲染（TODO-799 OP 卡拉OK 满屏坐标乱码）。
  final _DrawingState drawing = _DrawingState();

  void flush() {
    if (cur.isEmpty) return;
    segments.add((text: cur.toString(), style: style.clone()));
    cur.clear();
  }

  final int n = raw.length;
  int i = 0;
  while (i < n) {
    final String c = raw[i];
    if (c == '{') {
      final int close = raw.indexOf('}', i + 1);
      if (close < 0) {
        // 无闭合括号：剩余当普通文本。
        cur.write(raw.substring(i));
        break;
      }
      flush();
      _applyOverrideBlock(
        raw.substring(i + 1, close),
        style,
        (SubtitleAnchor a) => anchor = a,
        (SubtitlePos p) => pos = p,
        (bool on) => drawing.active = on,
        playResX,
        playResY,
      );
      i = close + 1;
      continue;
    }
    if (drawing.active) {
      // 绘图模式下标签块之外的正文是矢量命令，整体丢弃。
      i++;
      continue;
    }
    if (c == r'\' && i + 1 < n) {
      final String next = raw[i + 1];
      if (next == 'N' || next == 'n' || next == 'h') {
        cur.write(' ');
        i += 2;
        continue;
      }
    }
    cur.write(c);
    i++;
  }
  flush();

  // 修剪首尾空白（在计算 grapheme 偏移前裁段，保证偏移与 span 对齐）。
  if (segments.isNotEmpty) {
    final ({String text, _Style style}) first = segments.first;
    segments[0] = (text: first.text.trimLeft(), style: first.style);
    final ({String text, _Style style}) last = segments.last;
    segments[segments.length - 1] =
        (text: last.text.trimRight(), style: last.style);
    segments.removeWhere((({String text, _Style style}) s) => s.text.isEmpty);
  }

  final StringBuffer plain = StringBuffer();
  final List<SubtitleSpan> spans = <SubtitleSpan>[];
  int g = 0;
  for (final ({String text, _Style style}) seg in segments) {
    final int len = seg.text.characters.length;
    if (seg.style.hasStyle && len > 0) {
      spans.add(SubtitleSpan(
        startGrapheme: g,
        endGrapheme: g + len,
        italic: seg.style.italic,
        bold: seg.style.bold,
        underline: seg.style.underline,
        strike: seg.style.strike,
        colorArgb: seg.style.colorArgb,
        fontSizePx: seg.style.fontSizePx,
      ));
    }
    plain.write(seg.text);
    g += len;
  }

  return SubtitleMarkup(
    plainText: plain.toString(),
    spans: spans,
    anchor: anchor,
    posFraction: pos,
  );
}

/// 解析单个 `{...}` 块内的 `\tag` 序列，更新样式/锚点/位置。未知标签忽略。
void _applyOverrideBlock(
  String block,
  _Style style,
  void Function(SubtitleAnchor) setAnchor,
  void Function(SubtitlePos) setPos,
  void Function(bool) setDrawing,
  double? playResX,
  double? playResY,
) {
  // 按 '\' 切分各 tag；首段（第一个 '\' 前，通常空或注释）忽略。
  final List<String> tags = block.split(r'\');
  for (int t = 1; t < tags.length; t++) {
    final String tag = tags[t].trim();
    if (tag.isEmpty) continue;

    // \an<d> / \a<d>（旧式）
    final RegExpMatch? an = RegExp(r'^an?([1-9])$').firstMatch(tag);
    if (an != null) {
      final SubtitleAnchor? a =
          SubtitleAnchor.fromAnCode(int.parse(an.group(1)!));
      if (a != null) setAnchor(a);
      continue;
    }

    // \pos(x,y)
    final RegExpMatch? p =
        RegExp(r'^pos\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)$')
            .firstMatch(tag);
    if (p != null &&
        playResX != null &&
        playResY != null &&
        playResX > 0 &&
        playResY > 0) {
      final double x = double.parse(p.group(1)!);
      final double y = double.parse(p.group(2)!);
      setPos(SubtitlePos(x / playResX, y / playResY));
      continue;
    }

    // \i1 \i0 \b1 \b0 \u1 \u0 \s1 \s0（\b 接粗细数值时 >0 视为粗体）
    final RegExpMatch? toggle = RegExp(r'^([ibus])(\d+)$').firstMatch(tag);
    if (toggle != null) {
      final bool on = int.parse(toggle.group(2)!) > 0;
      switch (toggle.group(1)!) {
        case 'i':
          style.italic = on;
        case 'b':
          style.bold = on;
        case 'u':
          style.underline = on;
        case 's':
          style.strike = on;
      }
      continue;
    }

    // \fs<n>
    final RegExpMatch? fs = RegExp(r'^fs(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fs != null) {
      style.fontSizePx = double.parse(fs.group(1)!);
      continue;
    }

    // \c&H..& / \1c&H..&（主色，BGR）
    final RegExpMatch? col =
        RegExp(r'^1?c&H([0-9a-fA-F]{1,8})&?$').firstMatch(tag);
    if (col != null) {
      style.colorArgb = _assColorToArgb(col.group(1)!);
      continue;
    }

    // \p<n>：绘图模式开关。n>0 进入，n=0 退出；作用域持续到本条 cue 结束。
    final RegExpMatch? p1 = RegExp(r'^p(\d+)$').firstMatch(tag);
    if (p1 != null) {
      setDrawing(int.parse(p1.group(1)!) > 0);
      continue;
    }

    // 其余（\k \t \move \fad \frx \fscx \clip \bord \shad ...）忽略。
  }
}

/// ASS 颜色十六进制（BGR，可省前导零）→ 0xFFRRGGBB。
int _assColorToArgb(String hex) {
  final int v = int.parse(hex, radix: 16);
  final int b = (v >> 16) & 0xFF;
  final int g = (v >> 8) & 0xFF;
  final int r = v & 0xFF;
  return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// 扫描过程内部可变绘图模式状态（\pN 开 / \p0 关）。
class _DrawingState {
  bool active = false;
}
