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
      this.x1, this.y1, this.x2, this.y2, this.x3, this.y3)
      : op = SubtitleClipOp.cubic;
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

/// 解析 `\clip`/`\iclip` 括号内参数 [inner] → [SubtitleClip]（坐标除以 PlayRes 归一化）。
///
/// 两种形式（ASS 规范）：
/// - 矩形 `x1,y1,x2,y2` → 四段折线；
/// - 绘图 `[scale,] m/l/b/s/n 命令串`：`m x y` 移动、`l x y ...` 连续直线、
///   `b x1 y1 x2 y2 x3 y3 ...` 连续三次贝塞尔、`s ...` B 样条按折线近似、`n` 按移动
///   处理、`c`/`p` 忽略。scale 变体坐标除以 `2^(scale-1)`。
/// 解析失败 / 空路径 / PlayRes 缺失返回 null（调用方按无裁剪）。
SubtitleClip? parseAssClip({
  required bool inverse,
  required String inner,
  required double? playResX,
  required double? playResY,
}) {
  if (playResX == null || playResY == null || playResX <= 0 || playResY <= 0) {
    return null;
  }
  final List<SubtitleClipSegment> segments = <SubtitleClipSegment>[];

  // 矩形形式：恰好 4 个纯数字参数。
  final List<String> csv =
      inner.split(',').map((String p) => p.trim()).toList();
  if (csv.length == 4 && csv.every((String p) => double.tryParse(p) != null)) {
    final double x1 = double.parse(csv[0]) / playResX;
    final double y1 = double.parse(csv[1]) / playResY;
    final double x2 = double.parse(csv[2]) / playResX;
    final double y2 = double.parse(csv[3]) / playResY;
    return SubtitleClip(inverse: inverse, segments: <SubtitleClipSegment>[
      SubtitleClipSegment.move(x1, y1),
      SubtitleClipSegment.line(x2, y1),
      SubtitleClipSegment.line(x2, y2),
      SubtitleClipSegment.line(x1, y2),
    ]);
  }

  // 绘图形式：可选前导 `scale,`（单个正整数）+ 命令串。
  String drawing = inner;
  double divisor = 1.0;
  final int comma = inner.indexOf(',');
  if (comma > 0) {
    final int? scale = int.tryParse(inner.substring(0, comma).trim());
    if (scale != null && scale >= 1) {
      drawing = inner.substring(comma + 1);
      divisor = 1 << (scale - 1) == 0 ? 1.0 : (1 << (scale - 1)).toDouble();
    }
  }
  final List<String> tokens =
      drawing.split(RegExp(r'\s+')).where((String t) => t.isNotEmpty).toList();
  int i = 0;
  String mode = '';
  final List<double> nums = <double>[];
  void flushNums() {
    if (mode == 'm' || mode == 'n') {
      for (int k = 0; k + 1 < nums.length; k += 2) {
        segments.add(SubtitleClipSegment.move(
            nums[k] / divisor / playResX, nums[k + 1] / divisor / playResY));
      }
    } else if (mode == 'l' || mode == 's' || mode == 'p') {
      // s（B 样条）按折线近似；p（延长点）并入折线近似。
      if (mode == 'p') return;
      for (int k = 0; k + 1 < nums.length; k += 2) {
        segments.add(SubtitleClipSegment.line(
            nums[k] / divisor / playResX, nums[k + 1] / divisor / playResY));
      }
    } else if (mode == 'b') {
      for (int k = 0; k + 5 < nums.length; k += 6) {
        segments.add(SubtitleClipSegment.cubic(
          nums[k] / divisor / playResX,
          nums[k + 1] / divisor / playResY,
          nums[k + 2] / divisor / playResX,
          nums[k + 3] / divisor / playResY,
          nums[k + 4] / divisor / playResX,
          nums[k + 5] / divisor / playResY,
        ));
      }
    }
    nums.clear();
  }

  while (i < tokens.length) {
    final String t = tokens[i];
    final double? v = double.tryParse(t);
    if (v != null) {
      nums.add(v);
    } else {
      flushNums();
      mode = t.toLowerCase();
    }
    i++;
  }
  flushNums();
  if (segments.isEmpty || segments.first.op != SubtitleClipOp.move) {
    return null;
  }
  return SubtitleClip(inverse: inverse, segments: segments);
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
  });
}

/// 扫描过程内部可变的行级变换状态（`\frz` 旋转 / `\fscx\fscy` 缩放 / `\t` 缩放动画 /
/// `\move` 运动，TODO-1374）。跨同条 cue 的多个 `{...}` 块累积，扫描结束后归一成
/// [SubtitleMarkup] 的 rotationDeg / scale / move。
class _Transform {
  double? rotationDeg;
  double scaleX = 1.0;
  double scaleY = 1.0;
  bool scaleSet = false;
  // \t(...) 缩放动画目标（相对当前 scaleX/scaleY 为起点）。
  double? tScaleX;
  double? tScaleY;
  int? tStartMs;
  int? tEndMs;
  // \move(...)（归一化后坐标）。
  double? mx1, my1, mx2, my2;
  int? mt1, mt2;
  bool moveSet = false;

  /// 本 cue 的 `\clip`/`\iclip` 静态裁剪（见 [SubtitleMarkup.clip]）。
  SubtitleClip? clip;

  /// `\frx`/`\fry` 3D 旋转、`\fax`/`\fay` 切变（行级）。
  double? frxDeg;
  double? fryDeg;
  double? faxShear;
  double? fayShear;

  /// `\t(...)` 通用动画段（按出现顺序累积）。
  final List<SubtitleTransition> transitions = <SubtitleTransition>[];

  /// 卡拉 OK 音节起点累计（厘秒）：每个 \k 段的起点=之前所有 \k 时长之和。
  int kAccumCs = 0;
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
  double? fillOpacity;
  double? letterSpacingPx;
  String? kMode;
  int? kStartCs;
  int? kDurCs;

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
    ..blur = blur
    ..fillOpacity = fillOpacity
    ..letterSpacingPx = letterSpacingPx
    ..kMode = kMode
    ..kStartCs = kStartCs
    ..kDurCs = kDurCs;

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
    fillOpacity = null;
    letterSpacingPx = null;
    kMode = null;
    kStartCs = null;
    kDurCs = null;
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
      fillOpacity != null ||
      letterSpacingPx != null ||
      kMode != null ||
      (blur != null && blur! > 0);
}

/// 单条 cue 原文 → 结构化 markup。一趟扫描同时构建 plainText 与 span 边界。
///
/// [playResX]/[playResY] 仅用于把 `\pos` 归一化；srt/vtt 无 `\pos`，传 null 即可。
/// [cueStyle] 是本条 cue 引用的 ASS `[V4+ Styles]` 默认样式（TODO-1105）：原样透传到
/// 返回的 [SubtitleMarkup.cueStyle]，供渲染层作行内 span 之下的基线；行内 `{...}` 覆盖
/// 它。srt/vtt 无 Style 段传 null。
/// 支持行内 `\blur`/`\be`（辉光）、行级 `\fad`/`\fade`（淡入淡出，TODO-1373）、`\frz` 旋转
/// / `\fscx`\`\fscy`(+`\t`) 缩放 / `\move` 运动（TODO-1374）。其余不支持的标签（卡拉OK `\k`、
/// 3D 旋转 `\frx`/`\fry`、`\clip`、绘图 `\p` 正文等）静默删除，既不显示控制码也不产出样式。
SubtitleMarkup parseSubtitleMarkup(String raw,
    {double? playResX,
    double? playResY,
    SubtitleCueStyle? cueStyle,
    int layer = 0}) {
  final List<({String text, _Style style})> segments =
      <({String text, _Style style})>[];
  final StringBuffer cur = StringBuffer();
  final _Style style = _Style();
  SubtitleAnchor? anchor;
  SubtitlePos? pos;
  SubtitleFade? fade;
  final _Transform xf = _Transform();
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
        xf,
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
      // \N 硬换行：内部先写 '\n' 占位（同为 1 grapheme，span 偏移不变），扫描结束后
      // 记录其下标进 lineBreakGraphemes、并在 plainText 里替换回空格——查词 / 制卡 /
      // DB 文本与历史逐字节一致，只有渲染层看得到换行。\n（软换行，仅 WrapStyle 2 生效，
      // 罕见）/ \h（不断行空格）维持空格。
      if (next == 'N') {
        cur.write('\n');
        i += 2;
        continue;
      }
      if (next == 'n' || next == 'h') {
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
        fillOpacity: seg.style.fillOpacity,
        letterSpacingPx: seg.style.letterSpacingPx,
        kMode: seg.style.kMode,
        kStartCs: seg.style.kStartCs,
        kDurCs: seg.style.kDurCs,
      ));
    }
    plain.write(seg.text);
    g += len;
  }

  // 行级变换（\frz / \fscx\fscy / \t / \move，TODO-1374）归一：缩放取 (from)=静态
  // \fscx\fscy、(to)=\t 目标（无 \t 时 to==from）；有 \t 或静态缩放非 100% 才产出。
  final bool hasScale = xf.scaleSet || xf.tScaleX != null || xf.tScaleY != null;
  final SubtitleScale? scale = hasScale
      ? SubtitleScale(
          fromX: xf.scaleX,
          fromY: xf.scaleY,
          toX: xf.tScaleX ?? xf.scaleX,
          toY: xf.tScaleY ?? xf.scaleY,
          t1Ms: xf.tStartMs,
          t2Ms: xf.tEndMs,
        )
      : null;
  final SubtitleMove? move = xf.moveSet
      ? SubtitleMove(xf.mx1!, xf.my1!, xf.mx2!, xf.my2!,
          t1Ms: xf.mt1, t2Ms: xf.mt2)
      : null;

  // \N 硬换行占位（'\n'）→ 下标记录 + 替换回空格（plainText 与历史逐字节一致，查词 /
  // 制卡 / DB 零变化；渲染层按下标切行）。逐 grapheme 扫描一次即可（'\n' 恒单 grapheme）。
  final String rawPlain = plain.toString();
  List<int> breaks = const <int>[];
  String plainText = rawPlain;
  if (rawPlain.contains('\n')) {
    breaks = <int>[];
    int gi = 0;
    for (final String ch in rawPlain.characters) {
      if (ch == '\n') breaks.add(gi);
      gi++;
    }
    plainText = rawPlain.replaceAll('\n', ' ');
  }

  return SubtitleMarkup(
    plainText: plainText,
    spans: spans,
    // 行内 \an 优先；无行内 \an 时回退 cueStyle（V4+ Styles）的 Alignment（TODO-1105）。
    anchor: anchor ?? cueStyle?.anchor,
    posFraction: pos,
    cueStyle: cueStyle,
    // PlayResY 原样透传，供渲染层把 ASS 绝对字号 / 阴影深度缩放到播放尺寸（TODO-1246）。
    playResY: playResY,
    // PlayResX 透传，供渲染层缩放 MarginL/MarginR 水平边距（与 PlayResY 同构）。
    playResX: playResX,
    lineBreakGraphemes: breaks,
    fade: fade,
    rotationDeg: xf.rotationDeg,
    scale: scale,
    move: move,
    layer: layer,
    clip: xf.clip,
    transitions: List<SubtitleTransition>.unmodifiable(xf.transitions),
    rotationXDeg: xf.frxDeg,
    rotationYDeg: xf.fryDeg,
    shearX: xf.faxShear,
    shearY: xf.fayShear,
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
  _Transform xf,
  double? playResX,
  double? playResY,
) {
  // \t(...) 动画：内含 \fscy 等带反斜杠的子标签，会被下面 split('\\') 打碎，故先整体抽出
  // 记录目标，再从 block 里剔除（TODO-1374）。目标缩放的「起点」用后续静态 \fscx\fscy 累积值
  // （在下方循环里设），故此处只记 (t1,t2) 与目标倍数，实际 from 在扫描结束时归一。
  final String working =
      block.replaceAllMapped(RegExp(r'\\t\(([^)]*)\)'), (Match m) {
    _parseTransition(m.group(1) ?? '', xf);
    return '';
  });

  // 按 '\' 切分各 tag；首段（第一个 '\' 前，通常空或注释）忽略。
  final List<String> tags = working.split(r'\');
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

    // \frz<deg> / \fr<deg>（旧式 \fr 即 \frz，Z 轴旋转；ASS 逆时针为正，TODO-1374）。
    // \frx / \fry（3D 旋转）不支持——`frz?` 的 z 可选但后面必须紧跟数字，`frx10` 的 x
    // 非数字故不误命中。
    final RegExpMatch? frz = RegExp(r'^frz?(-?\d+(?:\.\d+)?)$').firstMatch(tag);
    if (frz != null) {
      xf.rotationDeg = double.parse(frz.group(1)!);
      continue;
    }

    // \fscx<pct> / \fscy<pct> 横 / 纵缩放（百分比，TODO-1374）。
    final RegExpMatch? fscx = RegExp(r'^fscx(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fscx != null) {
      xf.scaleX = double.parse(fscx.group(1)!) / 100.0;
      xf.scaleSet = true;
      continue;
    }
    final RegExpMatch? fscy = RegExp(r'^fscy(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fscy != null) {
      xf.scaleY = double.parse(fscy.group(1)!) / 100.0;
      xf.scaleSet = true;
      continue;
    }

    // \move(x1,y1,x2,y2[,t1,t2])：行级运动（TODO-1374）。坐标按 PlayRes 归一化（同 \pos）。
    final RegExpMatch? mv = RegExp(
            r'^move\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?:,\s*(\d+)\s*,\s*(\d+)\s*)?\)$')
        .firstMatch(tag);
    if (mv != null &&
        playResX != null &&
        playResY != null &&
        playResX > 0 &&
        playResY > 0) {
      xf.mx1 = double.parse(mv.group(1)!) / playResX;
      xf.my1 = double.parse(mv.group(2)!) / playResY;
      xf.mx2 = double.parse(mv.group(3)!) / playResX;
      xf.my2 = double.parse(mv.group(4)!) / playResY;
      xf.mt1 = mv.group(5) != null ? int.parse(mv.group(5)!) : null;
      xf.mt2 = mv.group(6) != null ? int.parse(mv.group(6)!) : null;
      xf.moveSet = true;
      continue;
    }

    // \1a&HXX& / \alpha&HXX&：主填充透明度（ASS alpha 00=不透明 FF=全透明）→
    // op=1-a/255。\alpha 一次设四通道，按主填充近似（描边/阴影 alpha 不单独建模，
    // 多层卡拉 OK 光晕层 `\1a&HFF&` 抹透明填充、留模糊描边成辉光）；\2a/\3a/\4a 忽略。
    final RegExpMatch? a1 =
        RegExp(r'^(?:1a|alpha)&?H?([0-9A-Fa-f]{1,2})&?$').firstMatch(tag);
    if (a1 != null) {
      style.fillOpacity =
          (1.0 - int.parse(a1.group(1)!, radix: 16) / 255.0).clamp(0.0, 1.0);
      continue;
    }

    // \clip(...) / \iclip(...)：静态矢量/矩形裁剪 → [SubtitleClip]（归一化分数坐标）。
    // 支持矩形四参形式与 m/l/b 绘图形式（含 scale 变体）；解析失败按无裁剪。
    final RegExpMatch? clipM = RegExp(r'^(i?)clip\((.*)\)$').firstMatch(tag);
    if (clipM != null) {
      final SubtitleClip? parsed = parseAssClip(
        inverse: clipM.group(1) == 'i',
        inner: clipM.group(2)!,
        playResX: playResX,
        playResY: playResY,
      );
      if (parsed != null) xf.clip = parsed;
      continue;
    }

    // \fsp<px>：字间距（可负/小数）。
    final RegExpMatch? fsp = RegExp(r'^fsp(-?\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fsp != null) {
      style.letterSpacingPx = double.parse(fsp.group(1)!);
      continue;
    }

    // \frx / \fry：3D 旋转（度）。\frz 已在上方处理（frz? 的 z 可选不会误吞 x/y）。
    final RegExpMatch? frx = RegExp(r'^frx(-?\d+(?:\.\d+)?)$').firstMatch(tag);
    if (frx != null) {
      xf.frxDeg = double.parse(frx.group(1)!);
      continue;
    }
    final RegExpMatch? fry = RegExp(r'^fry(-?\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fry != null) {
      xf.fryDeg = double.parse(fry.group(1)!);
      continue;
    }

    // \fax / \fay：切变因子。
    final RegExpMatch? fax = RegExp(r'^fax(-?\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fax != null) {
      xf.faxShear = double.parse(fax.group(1)!);
      continue;
    }
    final RegExpMatch? fay = RegExp(r'^fay(-?\d+(?:\.\d+)?)$').firstMatch(tag);
    if (fay != null) {
      xf.fayShear = double.parse(fay.group(1)!);
      continue;
    }

    // \k / \K / \kf / \ko<cs>：卡拉 OK 音节计时（厘秒）。本块起的文字段=一个音节：
    // 起点=之前音节时长累计，点亮方式 k=瞬切 / K=kf=渐变扫填近似 / ko=点亮前无描边。
    final RegExpMatch? kar =
        RegExp(r'^(k|K|kf|ko)(\d+(?:\.\d+)?)$').firstMatch(tag);
    if (kar != null) {
      final String mode = switch (kar.group(1)!) {
        'K' || 'kf' => 'kf',
        'ko' => 'ko',
        _ => 'k',
      };
      final int dur = double.parse(kar.group(2)!).round();
      style.kMode = mode;
      style.kStartCs = xf.kAccumCs;
      style.kDurCs = dur;
      xf.kAccumCs += dur;
      continue;
    }

    // 其余（\k \frx \fry \xbord \ybord ...）忽略。
  }
}

/// 解析 `\t(...)` 内部：形如 `t1,t2[,accel],<子标签>`、`accel,<子标签>` 或纯 `<子标签>`。
///
/// 缩放（`\fscx`/`\fscy`）沿用既有 [SubtitleScale] 通道（TODO-1374 历史兼容）；其余
/// 支持维度（`\1a`/`\alpha` 透明度、`\c`/`\1c` 颜色、`\blur`/`\be`、`\bord`、`\frz`）
/// 归一成一段 [SubtitleTransition] 追加进 [_Transform.transitions]，渲染层按
/// `p=((t-t1)/(t2-t1))^accel` 逐帧插值。不支持的子标签（\pos 渐变等）忽略。
void _parseTransition(String inner, _Transform xf) {
  int? t1;
  int? t2;
  double accel = 1.0;
  String rest = inner;
  final RegExpMatch? times =
      RegExp(r'^\s*(-?\d+)\s*,\s*(-?\d+)\s*(?:,\s*(-?\d+(?:\.\d+)?)\s*)?,')
          .firstMatch(inner);
  if (times != null) {
    t1 = int.parse(times.group(1)!);
    t2 = int.parse(times.group(2)!);
    if (times.group(3) != null) accel = double.parse(times.group(3)!);
    rest = inner.substring(times.end);
  } else {
    // 纯加速度形式：`accel,<子标签>`。
    final RegExpMatch? onlyAccel =
        RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*,').firstMatch(inner);
    if (onlyAccel != null) {
      accel = double.parse(onlyAccel.group(1)!);
      rest = inner.substring(onlyAccel.end);
    }
  }
  // 历史缩放通道（整条 cue 只支持一段缩放动画，后段覆盖）。
  if (times != null) {
    xf.tStartMs = t1;
    xf.tEndMs = t2;
  }
  final RegExpMatch? tx = RegExp(r'\\fscx(\d+(?:\.\d+)?)').firstMatch(rest);
  if (tx != null) xf.tScaleX = double.parse(tx.group(1)!) / 100.0;
  final RegExpMatch? ty = RegExp(r'\\fscy(\d+(?:\.\d+)?)').firstMatch(rest);
  if (ty != null) xf.tScaleY = double.parse(ty.group(1)!) / 100.0;

  // 通用动画维度。
  double? alphaTo;
  int? colorTo;
  double? blurTo;
  double? bordTo;
  double? frzTo;
  final RegExpMatch? ta =
      RegExp(r'\\(?:1a|alpha)&?H?([0-9A-Fa-f]{1,2})&?').firstMatch(rest);
  if (ta != null) {
    alphaTo =
        (1.0 - int.parse(ta.group(1)!, radix: 16) / 255.0).clamp(0.0, 1.0);
  }
  final RegExpMatch? tc =
      RegExp(r'\\1?c&H([0-9A-Fa-f]{1,8})&?').firstMatch(rest);
  if (tc != null) colorTo = assColorToArgb(tc.group(1)!);
  final RegExpMatch? tb =
      RegExp(r'\\(?:blur|be)(\d+(?:\.\d+)?)').firstMatch(rest);
  if (tb != null) blurTo = double.parse(tb.group(1)!);
  final RegExpMatch? tbo = RegExp(r'\\bord(\d+(?:\.\d+)?)').firstMatch(rest);
  if (tbo != null) bordTo = double.parse(tbo.group(1)!);
  final RegExpMatch? tfrz = RegExp(r'\\frz?(-?\d+(?:\.\d+)?)').firstMatch(rest);
  if (tfrz != null) frzTo = double.parse(tfrz.group(1)!);

  final SubtitleTransition tr = SubtitleTransition(
    t1Ms: t1,
    t2Ms: t2,
    accel: accel,
    alphaTo: alphaTo,
    colorToArgb: colorTo,
    blurTo: blurTo,
    bordTo: bordTo,
    frzToDeg: frzTo,
  );
  if (tr.hasTarget) xf.transitions.add(tr);
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
