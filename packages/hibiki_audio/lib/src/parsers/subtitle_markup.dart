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

  /// `\fn` 字体名（ASS 行内字体覆盖，TODO-1105）；null=默认。
  final String? fontName;

  /// `\3c` 描边色，0xFFRRGGBB（TODO-1105）；null=默认。
  final int? outlineColorArgb;

  /// `\4c` 阴影色，0xFFRRGGBB（TODO-1105）；null=默认。
  final int? shadowColorArgb;

  /// `\bord` 描边宽（px，TODO-1105）；null=默认。
  final double? outlineWidthPx;

  /// `\shad` 阴影深度（px，TODO-1105）；null=默认。
  final double? shadowDepthPx;

  const SubtitleSpan({
    required this.startGrapheme,
    required this.endGrapheme,
    this.italic = false,
    this.bold = false,
    this.underline = false,
    this.strike = false,
    this.colorArgb,
    this.fontSizePx,
    this.fontName,
    this.outlineColorArgb,
    this.shadowColorArgb,
    this.outlineWidthPx,
    this.shadowDepthPx,
  });

  bool get hasStyle =>
      italic ||
      bold ||
      underline ||
      strike ||
      colorArgb != null ||
      fontSizePx != null ||
      fontName != null ||
      outlineColorArgb != null ||
      shadowColorArgb != null ||
      outlineWidthPx != null ||
      shadowDepthPx != null;
}

/// 单条 cue 的**默认样式**：来自 ASS `[V4+ Styles]` 段里该 Dialogue 引用的 Style 行
/// （字体名 / 主色 / 描边色 / 阴影色 / 描边宽 / 阴影深度 / 对齐 / 竖直边距，TODO-1105）。
///
/// 语义是「本条字幕在没有行内 `{...}` 覆盖时的基线样式」：渲染层先取本 cueStyle，再让
/// 行内 [SubtitleSpan] 覆盖之。所有字段可空——srt/vtt 无 `[V4+ Styles]`、或某列缺失时留 null，
/// 渲染层回退到用户统一样式（fail-safe，Never break userspace）。
class SubtitleCueStyle {
  /// `Fontname`；null=默认。
  final String? fontName;

  /// `PrimaryColour`（BGR→0xFFRRGGBB）主色；null=默认。
  final int? primaryColorArgb;

  /// `OutlineColour`（BGR→0xFFRRGGBB）描边色；null=默认。
  final int? outlineColorArgb;

  /// `BackColour`（BGR→0xFFRRGGBB）阴影/背景色；null=默认。
  final int? shadowColorArgb;

  /// `Fontsize`（px）；null=默认。
  final double? fontSizePx;

  /// `Outline` 描边宽（px）；null=默认。
  final double? outlineWidthPx;

  /// `Shadow` 阴影深度（px）；null=默认。
  final double? shadowDepthPx;

  /// `Bold`（-1/1=粗体）；null=默认。
  final bool? bold;

  /// `Italic`（-1/1=斜体）；null=默认。
  final bool? italic;

  /// `Underline`；null=默认。
  final bool? underline;

  /// `StrikeOut`；null=默认。
  final bool? strikeOut;

  /// `Alignment`（\an 小键盘布局 1..9，V4+ 与行内 \an 同码）解码出的锚点；null=默认。
  final SubtitleAnchor? anchor;

  /// `MarginV` 竖直边距（px，ASS 坐标系）；null=默认。渲染层可选消费。
  final double? marginV;

  const SubtitleCueStyle({
    this.fontName,
    this.primaryColorArgb,
    this.outlineColorArgb,
    this.shadowColorArgb,
    this.fontSizePx,
    this.outlineWidthPx,
    this.shadowDepthPx,
    this.bold,
    this.italic,
    this.underline,
    this.strikeOut,
    this.anchor,
    this.marginV,
  });
}

/// 单条字幕 cue 解析出的几何 + 行内样式。`plainText` 不含任何标签，供逐字查词/制卡。
class SubtitleMarkup {
  final String plainText;
  final List<SubtitleSpan> spans;
  final SubtitleAnchor? anchor;
  final SubtitlePos? posFraction;

  /// cue 级默认样式（来自 ASS `[V4+ Styles]`，TODO-1105）。null=无 Style 段/非 ASS。
  final SubtitleCueStyle? cueStyle;

  const SubtitleMarkup({
    required this.plainText,
    required this.spans,
    this.anchor,
    this.posFraction,
    this.cueStyle,
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
  String? fontName;
  int? outlineColorArgb;
  int? shadowColorArgb;
  double? outlineWidthPx;
  double? shadowDepthPx;

  _Style clone() => _Style()
    ..italic = italic
    ..bold = bold
    ..underline = underline
    ..strike = strike
    ..colorArgb = colorArgb
    ..fontSizePx = fontSizePx
    ..fontName = fontName
    ..outlineColorArgb = outlineColorArgb
    ..shadowColorArgb = shadowColorArgb
    ..outlineWidthPx = outlineWidthPx
    ..shadowDepthPx = shadowDepthPx;

  bool get hasStyle =>
      italic ||
      bold ||
      underline ||
      strike ||
      colorArgb != null ||
      fontSizePx != null ||
      fontName != null ||
      outlineColorArgb != null ||
      shadowColorArgb != null ||
      outlineWidthPx != null ||
      shadowDepthPx != null;
}

/// 单条 cue 原文 → 结构化 markup。一趟扫描同时构建 plainText 与 span 边界。
///
/// [playResX]/[playResY] 仅用于把 `\pos` 归一化；srt/vtt 无 `\pos`，传 null 即可。
/// [cueStyle] 是本条 cue 引用的 ASS `[V4+ Styles]` 默认样式（TODO-1105）：原样透传到
/// 返回的 [SubtitleMarkup.cueStyle]，供渲染层作行内 span 之下的基线；行内 `{...}` 覆盖
/// 它。srt/vtt 无 Style 段传 null。
/// 不支持的标签（卡拉OK `\k`、动画 `\t/\move/\fad`、绘图 `\p`、旋转缩放等）静默删除，
/// 既不显示控制码也不产出样式。
SubtitleMarkup parseSubtitleMarkup(String raw,
    {double? playResX, double? playResY, SubtitleCueStyle? cueStyle}) {
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
        fontName: seg.style.fontName,
        outlineColorArgb: seg.style.outlineColorArgb,
        shadowColorArgb: seg.style.shadowColorArgb,
        outlineWidthPx: seg.style.outlineWidthPx,
        shadowDepthPx: seg.style.shadowDepthPx,
      ));
    }
    plain.write(seg.text);
    g += len;
  }

  return SubtitleMarkup(
    plainText: plain.toString(),
    spans: spans,
    // 行内 \an 优先；无行内 \an 时回退 cueStyle（V4+ Styles）的 Alignment（TODO-1105）。
    anchor: anchor ?? cueStyle?.anchor,
    posFraction: pos,
    cueStyle: cueStyle,
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
      style.colorArgb = assColorToArgb(col.group(1)!);
      continue;
    }

    // \3c&H..&（描边色，BGR，TODO-1105）
    final RegExpMatch? col3 =
        RegExp(r'^3c&H([0-9a-fA-F]{1,8})&?$').firstMatch(tag);
    if (col3 != null) {
      style.outlineColorArgb = assColorToArgb(col3.group(1)!);
      continue;
    }

    // \4c&H..&（阴影色，BGR，TODO-1105）
    final RegExpMatch? col4 =
        RegExp(r'^4c&H([0-9a-fA-F]{1,8})&?$').firstMatch(tag);
    if (col4 != null) {
      style.shadowColorArgb = assColorToArgb(col4.group(1)!);
      continue;
    }

    // \fn<字体名>（TODO-1105）。字体名可含空格；截到本 tag 末尾（\ 切分已隔开各 tag）。
    if (tag.startsWith('fn') && tag.length > 2) {
      final String name = tag.substring(2).trim();
      if (name.isNotEmpty) style.fontName = name;
      continue;
    }

    // \bord<n> 描边宽（px，TODO-1105）
    final RegExpMatch? bord = RegExp(r'^bord(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (bord != null) {
      style.outlineWidthPx = double.parse(bord.group(1)!);
      continue;
    }

    // \shad<n> 阴影深度（px，TODO-1105）
    final RegExpMatch? shad = RegExp(r'^shad(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (shad != null) {
      style.shadowDepthPx = double.parse(shad.group(1)!);
      continue;
    }

    // \p<n>：绘图模式开关。n>0 进入，n=0 退出；作用域持续到本条 cue 结束。
    final RegExpMatch? p1 = RegExp(r'^p(\d+)$').firstMatch(tag);
    if (p1 != null) {
      setDrawing(int.parse(p1.group(1)!) > 0);
      continue;
    }

    // 其余（\k \t \move \fad \frx \fscx \clip \xbord \ybord ...）忽略。
  }
}

/// ASS 颜色十六进制（BGR，可省前导零）→ 0xFFRRGGBB。
///
/// 公开供 [SubtitleMarkup] 与 ass_parser 的 `[V4+ Styles]` 颜色列（PrimaryColour /
/// OutlineColour / BackColour）共用同一份 BGR→ARGB 解码（TODO-1105），消除重复实现。
/// 高字节（AA）在 ASS 里是「透明度」（0=不透明，255=全透明）——本函数忽略之，一律返回
/// 不透明 0xFF；字幕渲染层不消费 ASS alpha（与行内 \c 路径一致）。
int assColorToArgb(String hex) {
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
