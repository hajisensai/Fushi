import 'package:fushi_compute/fushi_compute.dart';

import 'subtitle_native_decode.dart';

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
  }) : fadeInMs = 0,
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

  static double _evaluate(
    int t,
    int t1,
    int t2,
    int t3,
    int t4,
    double op1,
    double op2,
    double op3,
  ) {
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

/// ASS `\move(x1,y1,x2,y2[,t1,t2])` 行级运动（TODO-1374）。坐标已归一化到 0..1（同
/// [SubtitlePos]，用 PlayResX/Y 归一），渲染层按 letterbox 映射到显示坐标。t1/t2 为绝对
/// 毫秒；缺省（`\move(x1,y1,x2,y2)` 四参式）表示整条 cue 时长内匀速。渲染层按 cue 内已播放
/// 时长在 (x1,y1)→(x2,y2) 线性插值定位（同 libass「移动」语义）。纯 Dart。
class SubtitleMove {
  final double x1Fraction;
  final double y1Fraction;
  final double x2Fraction;
  final double y2Fraction;

  /// 运动起止毫秒（相对 cue 起点）；null=整条 cue 时长。
  final int? t1Ms;
  final int? t2Ms;

  const SubtitleMove(
    this.x1Fraction,
    this.y1Fraction,
    this.x2Fraction,
    this.y2Fraction, {
    this.t1Ms,
    this.t2Ms,
  });

  /// cue 内已播放 [elapsedMs]、cue 总时长 [durationMs] → 当前归一化位置。
  SubtitlePos posAt(int elapsedMs, int durationMs) {
    final int t1 = t1Ms ?? 0;
    final int t2 = t2Ms ?? durationMs;
    final double f = t2 <= t1
        ? 1.0
        : ((elapsedMs - t1) / (t2 - t1)).clamp(0.0, 1.0).toDouble();
    return SubtitlePos(
      x1Fraction + (x2Fraction - x1Fraction) * f,
      y1Fraction + (y2Fraction - y1Fraction) * f,
    );
  }
}

/// ASS `\fscx`/`\fscy` 缩放（+ 可选 `\t` 动画，TODO-1374）。[fromX]/[fromY]/[toX]/[toY]
/// 为倍数（1.0=100%）。无 `\t` 动画时 from==to（静态缩放）。[t1Ms]/[t2Ms] 为相对 cue 起点
/// 的毫秒；缺省整条 cue 时长。渲染层按 cue 内时间在 from→to 线性插值。纯 Dart。
class SubtitleScale {
  final double fromX;
  final double fromY;
  final double toX;
  final double toY;
  final int? t1Ms;
  final int? t2Ms;

  const SubtitleScale({
    required this.fromX,
    required this.fromY,
    required this.toX,
    required this.toY,
    this.t1Ms,
    this.t2Ms,
  });

  bool get isAnimated => fromX != toX || fromY != toY;

  /// cue 内已播放 [elapsedMs]、cue 总时长 [durationMs] → 当前 (scaleX, scaleY)。
  (double, double) scaleAt(int elapsedMs, int durationMs) {
    if (!isAnimated) return (fromX, fromY);
    final int t1 = t1Ms ?? 0;
    final int t2 = t2Ms ?? durationMs;
    final double f = t2 <= t1
        ? 1.0
        : ((elapsedMs - t1) / (t2 - t1)).clamp(0.0, 1.0).toDouble();
    return (fromX + (toX - fromX) * f, fromY + (toY - fromY) * f);
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

  /// `\1a`/`\alpha` 主填充不透明度 0..1（ASS alpha 00=不透明 FF=全透明，已换算成
  /// op=1-a/255）；null=默认不透明。多层卡拉 OK 的光晕层用 `\1a&HFF&` 把填充抹透明、
  /// 只留模糊描边成辉光。`\alpha` 按主填充近似（描边/阴影 alpha 不单独建模）。
  final double? fillOpacity;

  /// `\fsp` 字间距（px，PlayRes 空间）；null=默认（回退样式表 Spacing）。
  final double? letterSpacingPx;

  /// 静态 `\fscx`/`\fscy` 横/纵缩放倍数（1.0=不缩放）；null=默认。**span 级语义**
  /// （ASS：标签处生效直到下一次覆盖）——说话人前缀 `{\fscx50}（名前）{\fscx100}本文`
  /// 与句尾 `…{\fscx50}。` 只缩放所在段，不是整行。
  final double? scaleX;
  final double? scaleY;

  /// 卡拉 OK 音节（`\k`/`\kf`/`\K`/`\ko`）：本段从 cue 起点第 [kStartCs] 厘秒起、
  /// 历时 [kDurCs] 厘秒点亮。null=非卡拉 OK 段。[kMode]：'k'=瞬时切主色、
  /// 'kf'=渐变过渡（扫填近似）、'ko'=点亮前无描边。
  final String? kMode;
  final int? kStartCs;
  final int? kDurCs;

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
    this.fillOpacity,
    this.letterSpacingPx,
    this.scaleX,
    this.scaleY,
    this.kMode,
    this.kStartCs,
    this.kDurCs,
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
      fillOpacity != null ||
      letterSpacingPx != null ||
      scaleX != null ||
      scaleY != null ||
      kMode != null ||
      (blur != null && blur! > 0);
}

/// `\t(...)` 通用动画（一段）：在 cue 内 [t1Ms,t2Ms]（相对 cue 起点毫秒；null=整条
/// cue 时长）按 `p = ((t-t1)/(t2-t1))^accel` 插值到目标值。只建模本项目支持的维度；
/// 缩放动画沿用既有 [SubtitleScale] 通道（历史兼容），不入本类。
class SubtitleTransition {
  final int? t1Ms;
  final int? t2Ms;
  final double accel;

  /// `\1a`/`\alpha` 目标不透明度 0..1；null=本段不动 alpha。
  final double? alphaTo;

  /// `\c`/`\1c` 目标主色（0xFFRRGGBB）；null=不动。
  final int? colorToArgb;

  /// `\blur`/`\be` 目标模糊；null=不动。
  final double? blurTo;

  /// `\bord` 目标描边宽（px）；null=不动。
  final double? bordTo;

  /// `\frz` 目标旋转角（度）；null=不动。
  final double? frzToDeg;

  const SubtitleTransition({
    this.t1Ms,
    this.t2Ms,
    this.accel = 1.0,
    this.alphaTo,
    this.colorToArgb,
    this.blurTo,
    this.bordTo,
    this.frzToDeg,
  });

  bool get hasTarget =>
      alphaTo != null ||
      colorToArgb != null ||
      blurTo != null ||
      bordTo != null ||
      frzToDeg != null;

  /// 本段在 [elapsedMs]（cue 内已播放毫秒）的进度 0..1（accel 已施加）。
  double progressAt(int elapsedMs, int cueDurationMs) {
    final int t1 = t1Ms ?? 0;
    final int t2 = t2Ms ?? cueDurationMs;
    if (t2 <= t1) return elapsedMs >= t2 ? 1.0 : 0.0;
    final double raw = ((elapsedMs - t1) / (t2 - t1)).clamp(0.0, 1.0);
    if (accel == 1.0 || raw <= 0 || raw >= 1) return raw;
    return _pow(raw, accel);
  }

  static double _pow(double base, double exp) {
    // 纯 Dart pow（不引 dart:math 泛型歧义）：accel 常见 0.5~3，精度足够。
    if (exp == 2.0) return base * base;
    if (exp == 0.5) {
      // 牛顿法开方两轮足够视觉精度。
      double x = base;
      x = (x + base / x) / 2;
      x = (x + base / x) / 2;
      return x;
    }
    // 通用：exp 的整数部分连乘 + 小数部分线性近似（视觉动画容差内）。
    final int ip = exp.floor();
    double r = 1.0;
    for (int i = 0; i < ip; i++) {
      r *= base;
    }
    final double frac = exp - ip;
    if (frac > 0) r *= 1.0 + (base - 1.0) * frac;
    return r.clamp(0.0, 1.0);
  }
}

/// `\clip`/`\iclip` 静态裁剪路径的一段命令（归一化分数坐标，与 [SubtitlePos] 同构）。
/// [op] 为 move/line 时只用 (x1,y1)；cubic 用三控制点 (x1,y1)..(x3,y3)。
class SubtitleClipSegment {
  final SubtitleClipOp op;
  final double x1, y1;
  final double x2, y2;
  final double x3, y3;
  const SubtitleClipSegment.move(this.x1, this.y1)
    : op = SubtitleClipOp.move,
      x2 = 0,
      y2 = 0,
      x3 = 0,
      y3 = 0;
  const SubtitleClipSegment.line(this.x1, this.y1)
    : op = SubtitleClipOp.line,
      x2 = 0,
      y2 = 0,
      x3 = 0,
      y3 = 0;
  const SubtitleClipSegment.cubic(
    this.x1,
    this.y1,
    this.x2,
    this.y2,
    this.x3,
    this.y3,
  ) : op = SubtitleClipOp.cubic;
}

enum SubtitleClipOp { move, line, cubic }

/// ASS `\clip(...)`/`\iclip(...)` 静态裁剪（矩形四参形式已归一成折线段）。
/// [inverse]=true 为 `\iclip`（挖掉路径区域，其余照画）。本类只存归一化分数
/// （不引 Flutter）；渲染层按视频内容矩形映射后构建 `Path` 裁剪。
class SubtitleClip {
  final bool inverse;
  final List<SubtitleClipSegment> segments;
  const SubtitleClip({required this.inverse, required this.segments});
}

/// ASS `\p<n>` 矢量绘图（招牌白底遮罩 / 形状特效）。坐标已按 `2^(n-1)` 缩回脚本像素
/// 再除以 PlayRes 归一化成分数（与 [SubtitleClip] / [SubtitlePos] 同构，纯 Dart）。
///
/// libass/VSFilter 语义：绘图是一个「字形」，按其**包围盒**参与 `\an` 对齐 / `\pos`
/// 定位——`{\an7\pos(x,y)\p1}m 100 100 l 200 200` 的包围盒左上角落在 (x,y)，而不是
/// 绘图坐标原点。故本类同时给出包围盒 [minX]..[maxY]，渲染层据此把路径平移到盒内。
/// 每个 `m` 起一个子路径，子路径隐式闭合（ASS 绘图恒为填充形状）。
class SubtitleDrawing {
  final List<SubtitleClipSegment> segments;
  final double minX, minY, maxX, maxY;

  /// `\pbo<y>` 基线偏移（脚本像素 / PlayResY 归一化，正值向下）；无则 0。
  final double baselineOffsetFraction;

  const SubtitleDrawing({
    required this.segments,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    this.baselineOffsetFraction = 0,
  });

  double get widthFraction => maxX - minX;
  double get heightFraction => maxY - minY;
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

  /// `MarginL` 左边距（px，PlayResX 坐标系）；null=默认。与 [marginR] 一起定义水平
  /// 排版盒 `[MarginL, PlayResX - MarginR]`：居中对齐在盒内居中（不对称边距 → 整体
  /// 横移，字幕组用它把对白挪到说话人一侧）、左/右对齐分别贴盒左/右缘。
  final double? marginL;

  /// `MarginR` 右边距（px，PlayResX 坐标系）；null=默认。见 [marginL]。
  final double? marginR;

  /// `SecondaryColour`（BGR→0xFFRRGGBB）副色——卡拉 OK 音节点亮前的文字色；null=默认。
  final int? secondaryColorArgb;

  /// `Spacing` 字间距（px）；null=默认。
  final double? spacingPx;

  /// `Angle` 样式级 Z 轴旋转（度，ASS 逆时针为正）；null/0=不旋转。
  final double? angleDeg;

  /// `ScaleX`/`ScaleY` 样式级缩放（百分比，100=不缩放）；null=默认。
  final double? scaleXPct;
  final double? scaleYPct;

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
    this.marginL,
    this.marginR,
    this.secondaryColorArgb,
    this.spacingPx,
    this.angleDeg,
    this.scaleXPct,
    this.scaleYPct,
  });

  /// Dialogue 行级 Margin 列（MarginL/MarginR/MarginV，>0 才覆盖，0=沿用样式默认，ASS
  /// 规范）覆盖后的新实例。样式表实例被同名多条 Dialogue 共享，覆盖必须 clone 不得原地改。
  SubtitleCueStyle withEventMargins({
    double? marginL,
    double? marginR,
    double? marginV,
  }) {
    return SubtitleCueStyle(
      fontName: fontName,
      primaryColorArgb: primaryColorArgb,
      outlineColorArgb: outlineColorArgb,
      shadowColorArgb: shadowColorArgb,
      fontSizePx: fontSizePx,
      outlineWidthPx: outlineWidthPx,
      shadowDepthPx: shadowDepthPx,
      bold: bold,
      italic: italic,
      underline: underline,
      strikeOut: strikeOut,
      anchor: anchor,
      marginV: marginV ?? this.marginV,
      marginL: marginL ?? this.marginL,
      marginR: marginR ?? this.marginR,
      secondaryColorArgb: secondaryColorArgb,
      spacingPx: spacingPx,
      angleDeg: angleDeg,
      scaleXPct: scaleXPct,
      scaleYPct: scaleYPct,
    );
  }
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

  /// ASS `[Script Info]` 的 `PlayResX`（脚本坐标系宽度）。`MarginL`/`MarginR` 是相对本
  /// 宽度的绝对像素：渲染层据 `显示区宽 / playResX` 缩放成水平边距（与 [playResY] 之于
  /// MarginV 同构）。缺省回退 384（ASS 规范）；srt/vtt 传 null。
  final double? playResX;

  /// `\N` 硬换行的 grapheme 下标（升序）。[plainText] 里这些下标处是**空格**（与历史
  /// 行为一致——查词 / 制卡 / DB 文本零变化），渲染层据此把字幕盒切成多行，复现作者
  /// 排好的换行（libass 语义）。空列表 = 无硬换行。
  final List<int> lineBreakGraphemes;

  /// `\fad`/`\fade` 行级淡入淡出（TODO-1373）；null=无。渲染时按 cue 内已播放时长求不透明度。
  final SubtitleFade? fade;

  /// `\frz`（含旧式 `\fr`）行级 Z 轴旋转角（度，ASS 逆时针为正，TODO-1374）；null=无旋转。
  /// 渲染层绕锚点旋转字幕盒。`\frx`/`\fry`（3D 旋转）不支持。
  final double? rotationDeg;

  /// `\fscx`/`\fscy`（+ `\t` 动画）行级缩放（TODO-1374）；null=无缩放（100%）。
  final SubtitleScale? scale;

  /// `\move(...)` 行级运动（TODO-1374）；null=无运动。有 [move] 时覆盖 [posFraction]，
  /// 渲染层按 cue 内时间插值定位。
  final SubtitleMove? move;

  /// ASS Dialogue 的 `Layer` 列；srt/vtt 恒 0。libass 语义：**碰撞（竖排避让）只发生在
  /// 同层事件之间**，不同层各按自带位置叠画（多层卡拉 OK：光晕层+主文字层+点缀层同位
  /// 叠出一行特效）。渲染层据此分组。
  final int layer;

  /// `\t(...)` 通用动画段列表（按出现顺序；同维后段覆盖前段的目标）。空=无动画。
  final List<SubtitleTransition> transitions;

  /// `\frx`/`\fry` 3D 旋转（度，ASS 语义）；null=无。渲染层用带透视的 Matrix4。
  final double? rotationXDeg;
  final double? rotationYDeg;

  /// `\fax`/`\fay` 切变因子；null=无。
  final double? shearX;
  final double? shearY;

  /// 本 cue 的 `\clip(...)`/`\iclip(...)` 静态裁剪；null=无。坐标已按 PlayRes 归一化
  /// 成分数（与 [posFraction] 同构），渲染层映射到视频内容矩形后构建裁剪路径。
  /// `\t(\clip)` 动画裁剪不支持（取扫描到的最后一个静态值）。
  final SubtitleClip? clip;

  /// `\p<n>` 正文矢量绘图（招牌白底遮罩等）；null=本 cue 无绘图。绘图事件通常没有
  /// 可读正文（[plainText] 为空），是否作为 cue 产出由解析器调用方决定
  /// （`AssParser.parseString(includeDrawings:)`）——播放渲染要它，字幕列表 / 制卡 /
  /// 导入持久化不要。
  final SubtitleDrawing? drawing;

  /// 绘图生效时刻的行内样式快照（`\1c` 填充色 / `\1a` / `\3c` `\bord` 描边 / `\shad`
  /// / `\blur`），grapheme 区间恒为空 `[0,0)`；null=绘图前无任何行内覆盖（回退
  /// [cueStyle]）。渲染层用它给路径取填充 / 描边画笔，与文字字形同一套解析。
  final SubtitleSpan? drawingStyle;

  const SubtitleMarkup({
    required this.plainText,
    required this.spans,
    this.anchor,
    this.posFraction,
    this.cueStyle,
    this.playResY,
    this.playResX,
    this.lineBreakGraphemes = const <int>[],
    this.fade,
    this.rotationDeg,
    this.scale,
    this.move,
    this.layer = 0,
    this.clip,
    this.transitions = const <SubtitleTransition>[],
    this.rotationXDeg,
    this.rotationYDeg,
    this.shearX,
    this.shearY,
    this.drawing,
    this.drawingStyle,
  });
}

/// 单条 cue 原文 → 结构化 markup。实现在 Rust（`ffc_parse_subtitle_markup`，
/// native/fushi_compute/src/parse/subtitle/markup.rs），这里只做 FFI 往返与解码。
///
/// [playResX]/[playResY] 仅用于把 `\pos` / `\move` / `\clip` / `\p` 绘图归一化；srt/vtt 无
/// PlayRes，传 null。[cueStyle] 是本条 cue 引用的 ASS `[V4+ Styles]` 默认样式（TODO-1105）：
/// 原样透传到返回的 [SubtitleMarkup.cueStyle]，行内无 `\an` 时回退它的 anchor。
/// 支持的标签见 markup.rs；不支持的标签静默删除，既不显示控制码也不产出样式。
///
/// 旧 Dart 实现会在这里抛出的异常（标签里的整数越界 → `FormatException`、卡拉 OK 时长
/// 溢出成 Infinity → `UnsupportedError`）照原类型抛出。
SubtitleMarkup parseSubtitleMarkup(
  String raw, {
  double? playResX,
  double? playResY,
  SubtitleCueStyle? cueStyle,
  int layer = 0,
}) {
  final SubtitleNativeResult result = SubtitleParseNative.instance.parseMarkup(
    raw,
    playResX: playResX,
    playResY: playResY,
    layer: layer,
  );
  result.throwIfError();
  try {
    return readSubtitleMarkup(
      result.reader(),
      playResX: playResX,
      playResY: playResY,
      cueStyle: cueStyle,
    );
  } finally {
    result.free();
  }
}
