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

/// 行级淡入淡出（ASS `\fad` / `\fade`，TODO-1373）。以「不透明度包络」建模：三段平台
/// 不透明度 (op1,op2,op3) + 四个时间边界 (t1<=t2<=t3<=t4)：
/// - t<=t1 → op1；t1<t<t2 → op1..op2 线性；t2<=t<=t3 → op2；
///   t3<t<t4 → op2..op3 线性；t>=t4 → op3。
///
/// `\fad(a,b)` 简式=淡入 a ms、淡出 b ms（op 0→1→0），收尾两点 t3=dur-b、t4=dur
/// 依赖 cue 时长，故只存 (fadeInMs,fadeOutMs)，在 [opacityAt] 里用真实时长解析。
/// `\fade(a1,a2,a3,t1,t2,t3,t4)` 全式：alpha 0..255（0=不透明）已换算成 op=1-alpha/255，
/// 时间为绝对毫秒。两式最终归一到同一条 [_evaluate]，消除按标签分渲染的特例。纯 Dart。
class SubtitleFade {
  /// `\fad(fadeInMs, fadeOutMs)` 简式。
  const SubtitleFade.simple(this.fadeInMs, this.fadeOutMs)
      : _op1 = 0.0,
        _op2 = 1.0,
        _op3 = 0.0,
        _t1 = null,
        _t2 = null,
        _t3 = null,
        _t4 = null;

  /// `\fade(...)` 全式（alpha 已换算成 op 0..1，时间为绝对毫秒）。
  const SubtitleFade.full({
    required double op1,
    required double op2,
    required double op3,
    required int t1,
    required int t2,
    required int t3,
    required int t4,
  })  : fadeInMs = 0,
        fadeOutMs = 0,
        _op1 = op1,
        _op2 = op2,
        _op3 = op3,
        _t1 = t1,
        _t2 = t2,
        _t3 = t3,
        _t4 = t4;

  /// 简式淡入 / 淡出毫秒（全式恒 0，收尾时间走 [_t3]/[_t4]）。
  final int fadeInMs;
  final int fadeOutMs;

  final double _op1;
  final double _op2;
  final double _op3;
  final int? _t1;
  final int? _t2;
  final int? _t3;
  final int? _t4;

  /// cue 内已播放 [elapsedMs]、cue 总时长 [durationMs] → 不透明度 0..1。简式收尾两点
  /// 用 [durationMs] 解析；四个时间边界先夹成单调非减（短 cue 下 dur-fadeOut 可能 <
  /// fadeIn，淡入淡出重叠），防反序求值。
  double opacityAt(int elapsedMs, int durationMs) {
    final int t1 = _t1 ?? 0;
    int t2 = _t2 ?? fadeInMs;
    int t3 = _t3 ?? (durationMs - fadeOutMs);
    int t4 = _t4 ?? durationMs;
    if (t2 < t1) t2 = t1;
    if (t4 < t2) t4 = t2;
    if (t3 < t2) t3 = t2;
    if (t3 > t4) t3 = t4;
    return _evaluate(elapsedMs, t1, t2, t3, t4, _op1, _op2, _op3);
  }

  static double _evaluate(int t, int t1, int t2, int t3, int t4, double op1,
      double op2, double op3) {
    // 淡入段（含之前）：仅当 t<t2 才可能是 op1 / 入坡。零宽入坡（t1==t2，如 \fad(0,..)）时
    // t==t1 直接落到平台 op2（瞬时不透明），不会误显 op1（透明），也避免除零。
    if (t < t2) {
      if (t <= t1) return op1;
      return _lerp(op1, op2, (t - t1) / (t2 - t1));
    }
    if (t <= t3) return op2;
    if (t < t4) return _lerp(op2, op3, (t - t3) / (t4 - t3));
    return op3;
  }

  static double _lerp(double a, double b, double f) {
    final double c = f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
    return a + (b - a) * c;
  }
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

  /// `\blur`/`\be` 辉光模糊强度（ASS 目标分辨率像素下的高斯 sigma，TODO-1373）；null/0=无。
  /// 本类只存 ASS 原值（不引 Flutter），换算成多少逻辑像素由 video 层按字号定。
  final double? blur;

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
    this.blur,
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
      shadowDepthPx != null ||
      (blur != null && blur! > 0);
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

  /// ASS `[Script Info]` 的 `PlayResY`（脚本坐标系高度，TODO-1246）。ASS 的字号
  /// （`Fontsize` / `\fs`）与阴影深度（`Shadow` / `\shad`）是**相对本高度的绝对像素**：
  /// 渲染层据 `字幕显示区高度 / playResY` 把绝对值缩放到实际播放尺寸，否则大制作字幕
  /// （PlayResY=1080、Fontsize=60）会以裸 60 逻辑像素在小屏撑爆、在大屏偏小。ass_parser
  /// 缺省时按 ASS 规范回退 288（与 `\pos` 归一化同源）；srt/vtt 无 PlayRes 传 null →
  /// 渲染层退回不缩放（历史行为）。
  final double? playResY;

  /// `\fad`/`\fade` 行级淡入淡出（TODO-1373）；null=无。渲染时按 cue 内已播放时长求不透明度。
  final SubtitleFade? fade;

  const SubtitleMarkup({
    required this.plainText,
    required this.spans,
    this.anchor,
    this.posFraction,
    this.cueStyle,
    this.playResY,
    this.fade,
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
  double? blur;

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
    ..shadowDepthPx = shadowDepthPx
    ..blur = blur;

  /// Clears every accumulated inline override, returning to the "no override"
  /// state (ASS `\r` reset-tag semantics, TODO-1246). A segment reset this way
  /// reports [hasStyle] == false, so the renderer falls back to this cue's
  /// [V4+ Styles] baseline ([SubtitleCueStyle]) instead of inheriting the
  /// previous span's inline primary colour / outline / font.
  void reset() {
    italic = false;
    bold = false;
    underline = false;
    strike = false;
    colorArgb = null;
    fontSizePx = null;
    fontName = null;
    outlineColorArgb = null;
    shadowColorArgb = null;
    outlineWidthPx = null;
    shadowDepthPx = null;
    blur = null;
  }

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
      shadowDepthPx != null ||
      (blur != null && blur! > 0);
}

/// 单条 cue 原文 → 结构化 markup。一趟扫描同时构建 plainText 与 span 边界。
///
/// [playResX]/[playResY] 仅用于把 `\pos` 归一化；srt/vtt 无 `\pos`，传 null 即可。
/// [cueStyle] 是本条 cue 引用的 ASS `[V4+ Styles]` 默认样式（TODO-1105）：原样透传到
/// 返回的 [SubtitleMarkup.cueStyle]，供渲染层作行内 span 之下的基线；行内 `{...}` 覆盖
/// 它。srt/vtt 无 Style 段传 null。
/// 支持行内 `\blur`/`\be`（辉光）与行级 `\fad`/`\fade`（淡入淡出，TODO-1373）。其余不支持
/// 的标签（卡拉OK `\k`、动画 `\t/\move`、绘图 `\p`、旋转缩放等）静默删除，既不显示控制码
/// 也不产出样式。
SubtitleMarkup parseSubtitleMarkup(String raw,
    {double? playResX, double? playResY, SubtitleCueStyle? cueStyle}) {
  final List<({String text, _Style style})> segments =
      <({String text, _Style style})>[];
  final StringBuffer cur = StringBuffer();
  final _Style style = _Style();
  SubtitleAnchor? anchor;
  SubtitlePos? pos;
  SubtitleFade? fade;
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
        (SubtitleFade f) => fade = f,
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
        blur: seg.style.blur,
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
    // PlayResY 原样透传，供渲染层把 ASS 绝对字号 / 阴影深度缩放到播放尺寸（TODO-1246）。
    playResY: playResY,
    fade: fade,
  );
}

/// 解析单个 `{...}` 块内的 `\tag` 序列，更新样式/锚点/位置/淡变。未知标签忽略。
void _applyOverrideBlock(
  String block,
  _Style style,
  void Function(SubtitleAnchor) setAnchor,
  void Function(SubtitlePos) setPos,
  void Function(bool) setDrawing,
  void Function(SubtitleFade) setFade,
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

    // \blur<n> / \be<n>：辉光边缘模糊（TODO-1373）。两者都软化字形边缘成辉光，归一到
    // 同一 `blur` 强度字段（span 级，随文本作用域），消除按标签特判。value<=0 视为无。
    final RegExpMatch? blur =
        RegExp(r'^(?:blur|be)(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (blur != null) {
      final double v = double.parse(blur.group(1)!);
      style.blur = v > 0 ? v : null;
      continue;
    }

    // \fad(t1,t2)：行级淡入 t1ms / 淡出 t2ms（收尾依赖 cue 时长，渲染时解析，TODO-1373）。
    final RegExpMatch? fad =
        RegExp(r'^fad\(\s*(\d+)\s*,\s*(\d+)\s*\)$').firstMatch(tag);
    if (fad != null) {
      setFade(SubtitleFade.simple(
        int.parse(fad.group(1)!),
        int.parse(fad.group(2)!),
      ));
      continue;
    }

    // \fade(a1,a2,a3,t1,t2,t3,t4)：行级七参淡变。alpha 0..255（0=不透明）→
    // 不透明度 op=1-alpha/255；时间为绝对毫秒（TODO-1373）。
    final RegExpMatch? fade = RegExp(
            r'^fade\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$')
        .firstMatch(tag);
    if (fade != null) {
      double toOp(String a) => 1.0 - (int.parse(a).clamp(0, 255) / 255.0);
      setFade(SubtitleFade.full(
        op1: toOp(fade.group(1)!),
        op2: toOp(fade.group(2)!),
        op3: toOp(fade.group(3)!),
        t1: int.parse(fade.group(4)!),
        t2: int.parse(fade.group(5)!),
        t3: int.parse(fade.group(6)!),
        t4: int.parse(fade.group(7)!),
      ));
      continue;
    }

    // \r / \r<StyleName>: ASS reset tag. Clears every accumulated inline
    // override so the reset region falls back to this cue's [V4+ Styles]
    // baseline instead of inheriting the previous span's primary colour /
    // outline / font (TODO-1246). Without it, `{\c&Hxxxxxx&}...{\r}...` bleeds
    // the earlier colour past the reset and paints the wrong colour / stroke
    // rather than honouring the subtitle's own style. The only ASS tag starting
    // with a bare `r` is `\r` (`\frx` / `\fscx` start with `f`), so a prefix
    // test is safe. Named-style `\r<StyleName>` switching needs the
    // [V4+ Styles] map (not held here); a baseline reset is a safe approximation
    // that at least stops stale overrides from leaking.
    if (tag == 'r' || RegExp(r'^r[A-Za-z0-9_ \-]+$').hasMatch(tag)) {
      style.reset();
      continue;
    }

    // 其余（\k \t \move \frx \fscx \clip \xbord \ybord ...）忽略。
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
