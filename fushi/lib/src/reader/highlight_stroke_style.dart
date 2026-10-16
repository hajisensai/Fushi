/// 阅读器高亮条的笔触样式（用户 2026-10-15：「高亮条自定义做成配置，用户自己可自选样式，
/// 并且支持可视化调节」「全部高亮都要能选可以自定义高亮」）。
///
/// 四类高亮——收藏句、查词选中、有声书当前句、搜索命中——各有一套独立配置。经典样式就是
/// 阅读器一直以来的 1em 窄条（收藏另有下划线）；其余六种由窄条层 `__fushiLanes`
/// （reader_selection_scripts.dart）把该组改画成 SVG 笔触。配置经正文 CSS 的 `:root`
/// 变量（[highlightStrokeCssVariables]）传给 JS——改设置走现有的正文样式热替换，不需要
/// 额外的桥调用。
///
/// 正文 CSS 生成器、偏好读写与设置页预览共用。落笔动画的节奏只取 [FushiMotion]
/// token（[highlightStrokeSweepLineDuration]），减弱动态效果 / 墨水屏时归零。
library;

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 高亮条的笔触样式。[wireName] 同时是偏好值与 CSS 变量 `--fushi-mark-<种类>-style`
/// 的值，与 JS 的 `MARK_STYLES` 逐字对应（测试钉住）。
enum HighlightStrokeStyle {
  /// 1em 窄条（历史行为；收藏另有下划线）。
  classic('classic'),

  /// 斜切马克笔：两端平行斜切，收笔端微毛、略积墨。
  marker('marker'),

  /// 水性荧光笔：毛边、起收笔积墨、中段拖痕。
  fluo('fluo'),

  /// 手绘双笔：两道略带弧度的粗笔叠画。
  rough('rough'),

  /// 半截荧光：只涂字的下半截，永远不挡振假名。
  under('under'),

  /// 彩铅涂抹：颗粒感、边缘不规则。
  crayon('crayon'),

  /// 和纸胶带：两端撕口、略歪、细斜纹。
  tape('tape');

  const HighlightStrokeStyle(this.wireName);

  final String wireName;

  /// 偏好值 → 样式；未知值（旧数据 / 手改）回落经典。
  static HighlightStrokeStyle fromWire(String? value) {
    for (final HighlightStrokeStyle style in values) {
      if (style.wireName == value) return style;
    }
    return HighlightStrokeStyle.classic;
  }

  /// 「盖住振假名」对这个样式有没有意义（经典恒 1em、半截只涂下半截）。
  bool get supportsCoverRuby =>
      this != HighlightStrokeStyle.classic &&
      this != HighlightStrokeStyle.under;

  /// 粗细 / 抖动对这个样式有没有意义（经典恒 1em 窄条）。
  bool get isStroke => this != HighlightStrokeStyle.classic;
}

/// 阅读器里的四类高亮。每类一套独立的 [HighlightStrokeConfig]。
enum HighlightKind {
  // 顺序即设置页「应用于」的分段顺序（用户 2026-10-16：有声书第一、查词第二、收藏第三）。
  // 偏好键按名字存，改顺序不影响已有设置。

  /// 有声书当前句：读到哪句就画出哪句。
  audio('audio', 'audio_highlight'),

  /// 查词选中（含拖选）：选中一处新的词时画出来；拖选扩大选区不重播。
  lookup('lookup', 'lookup_highlight'),

  /// 收藏句（五色）：新收藏时放一次落笔动画。
  favorite('favorite', 'favorite_highlight'),

  /// 搜索命中：跳到一处新的命中时画出来。
  search('search', 'search_highlight');

  const HighlightKind(this.cssName, this.prefPrefix);

  /// CSS 变量里的种类名（`--fushi-mark-<cssName>-*`），与 JS 的 `KIND_OF` 对应。
  final String cssName;

  /// 偏好键前缀（`<prefPrefix>_style` 等）。存量的 `audio_highlight_color` /
  /// `_background` / `_text_color` 与这里的 `_style` / `_thickness` … 不重名。
  final String prefPrefix;

  /// 这类高亮的默认配置：都从经典开始（不改变任何人的现状）；落笔动画默认开，和设置页的
  /// 预览一样画出来（经典样式没有笔划，这个开关在选笔触样式之前不起作用）。
  HighlightStrokeConfig get defaults => const HighlightStrokeConfig();
}

/// 一类高亮的完整笔触配置。各数值的取值范围见 `kHighlightStroke*` 常量。
class HighlightStrokeConfig {
  const HighlightStrokeConfig({
    this.style = HighlightStrokeStyle.classic,
    this.thickness = kHighlightStrokeThicknessDefault,
    this.opacity = kHighlightStrokeOpacityDefault,
    this.coverRuby = false,
    this.roughness = kHighlightStrokeRoughnessDefault,
    this.animate = true,
  });

  final HighlightStrokeStyle style;

  /// 笔划粗细：乘在该样式自然粗细（[kHighlightStrokeNaturalEm]）上的倍数。
  final double thickness;

  /// 颜色浓度（0–1 的不透明度）。颜色本身仍由各类高亮原有的颜色设置决定。
  final double opacity;

  /// 笔划往振假名一侧加厚、盖住注音（振假名字本身仍压在笔划上面）。
  final bool coverRuby;

  /// 笔触抖动：0 = 规整，1 = 最潦草。
  final double roughness;

  /// 落笔动画：新出现的高亮沿书写方向画出来（与设置页预览同一套时长与缓动）。
  final bool animate;

  HighlightStrokeConfig copyWith({
    HighlightStrokeStyle? style,
    double? thickness,
    double? opacity,
    bool? coverRuby,
    double? roughness,
    bool? animate,
  }) => HighlightStrokeConfig(
    style: style ?? this.style,
    thickness: thickness ?? this.thickness,
    opacity: opacity ?? this.opacity,
    coverRuby: coverRuby ?? this.coverRuby,
    roughness: roughness ?? this.roughness,
    animate: animate ?? this.animate,
  );

  @override
  bool operator ==(Object other) =>
      other is HighlightStrokeConfig &&
      other.style == style &&
      other.thickness == thickness &&
      other.opacity == opacity &&
      other.coverRuby == coverRuby &&
      other.roughness == roughness &&
      other.animate == animate;

  @override
  int get hashCode =>
      Object.hash(style, thickness, opacity, coverRuby, roughness, animate);
}

/// 各笔触的自然粗细（em，粗细倍数 1.0 时的笔划厚度）。经典窄条守「一个字高」；笔触样式以
/// 好看为先，允许超过字高、擦到甚至盖到振假名（用户 2026-10-16 拍板），默认取几乎填满行距
/// 的粗细。与窄条层 JS 的 `MARK_NATURAL_EM` 逐项相同（测试钉住）。半截荧光只涂字的下半截，
/// 不在表里。
const Map<HighlightStrokeStyle, double> kHighlightStrokeNaturalEm =
    <HighlightStrokeStyle, double>{
      HighlightStrokeStyle.marker: 1.35,
      HighlightStrokeStyle.fluo: 1.3,
      HighlightStrokeStyle.rough: 1.25,
      HighlightStrokeStyle.crayon: 1.38,
      HighlightStrokeStyle.tape: 1.45,
    };

/// 粗细倍数（乘在 [kHighlightStrokeNaturalEm] 上）。
const double kHighlightStrokeThicknessMin = 0.5;
const double kHighlightStrokeThicknessMax = 1.8;
const double kHighlightStrokeThicknessDefault = 1.0;

const double kHighlightStrokeOpacityMin = 0.15;
const double kHighlightStrokeOpacityMax = 0.8;
const double kHighlightStrokeOpacityDefault = 0.35;

const double kHighlightStrokeRoughnessMin = 0;
const double kHighlightStrokeRoughnessMax = 1;
const double kHighlightStrokeRoughnessDefault = 0.5;

/// 落笔动画里一行的时长：[FushiMotion.micro] + 行长(em) × [FushiMotion.strokeSweepPerEm]。
/// 正文（JS SMIL，经 [highlightStrokeCssVariables] 下发）与设置页预览同一公式。
Duration highlightStrokeSweepLineDuration(double lengthEm) =>
    FushiMotion.micro + FushiMotion.strokeSweepPerEm * lengthEm;

/// 落笔动画相邻两行的间隔（[FushiMotion.staggerStep]）。
const Duration kHighlightStrokeSweepGap = FushiMotion.staggerStep;

/// 正文 CSS `:root` 里的笔触变量（窄条层 `markConfigs()` 读同名变量）。
///
/// - 墨水屏强制经典：墨水屏把所有高亮改成线式标记、窄条层整层隐藏。
/// - [darkBackground] 与 [paperColor] 给 JS 画荧光笔拖痕 / 胶带斜纹 / 彩铅颗粒用的「纸色」。
/// - [motionEnabled]：页面的 `fushiMotionEnabled`（系统「减弱动态效果」/ 墨水屏为 false）。
///   为 false 时各类 `-animate` 一律写 0、落笔节奏写 0，JS 不放落笔动画——动画开关与时长的
///   唯一真相源在 Dart，JS 不自定时长、不自己读 `prefers-reduced-motion`。
String highlightStrokeCssVariables(
  Map<HighlightKind, HighlightStrokeConfig> configs, {
  required bool einkMode,
  required bool darkBackground,
  required String paperColor,
  bool motionEnabled = true,
}) {
  final bool sweep = motionEnabled && !einkMode;
  final StringBuffer out = StringBuffer();
  for (final HighlightKind kind in HighlightKind.values) {
    final HighlightStrokeConfig c = configs[kind] ?? kind.defaults;
    final HighlightStrokeStyle style = einkMode
        ? HighlightStrokeStyle.classic
        : c.style;
    final String p = '  --fushi-mark-${kind.cssName}';
    out
      ..write('$p-style: ${style.wireName};\n')
      ..write(
        '$p-thickness: ${_n(c.thickness.clamp(kHighlightStrokeThicknessMin, kHighlightStrokeThicknessMax))};\n',
      )
      ..write(
        '$p-opacity: ${_n(c.opacity.clamp(kHighlightStrokeOpacityMin, kHighlightStrokeOpacityMax))};\n',
      )
      ..write(
        '$p-cover-ruby: ${c.coverRuby && style.supportsCoverRuby ? 1 : 0};\n',
      )
      ..write(
        '$p-roughness: ${_n(c.roughness.clamp(kHighlightStrokeRoughnessMin, kHighlightStrokeRoughnessMax))};\n',
      )
      ..write('$p-animate: ${sweep && c.animate ? 1 : 0};\n');
  }
  out
    ..write(
      '  --fushi-mark-sweep-base-ms: ${sweep ? highlightStrokeSweepLineDuration(0).inMilliseconds : 0};\n',
    )
    ..write(
      '  --fushi-mark-sweep-per-em-ms: ${sweep ? FushiMotion.strokeSweepPerEm.inMilliseconds : 0};\n',
    )
    ..write(
      '  --fushi-mark-sweep-gap-ms: ${sweep ? kHighlightStrokeSweepGap.inMilliseconds : 0};\n',
    )
    ..write('  --fushi-mark-dark: ${darkBackground ? 1 : 0};\n')
    ..write('  --fushi-mark-paper: $paperColor;\n');
  return out.toString();
}

/// 收藏选了笔触样式时不再画下划线：形状本身就是标记，下划线叠上去像两道。旧 WebView 的
/// 包裹 span 把下划线写在内联样式上，所以这里要 `!important`。经典样式返回空串。
/// （其余三类高亮本来就没有下划线。）
String favoriteHighlightUnderlineOverrideCss(
  HighlightStrokeConfig favorite, {
  required bool einkMode,
}) {
  if (einkMode || !favorite.style.isStroke) return '';
  const List<String> colors = <String>[
    'yellow',
    'green',
    'blue',
    'pink',
    'purple',
  ];
  final String selectors = colors
      .map(
        (String c) =>
            '::highlight(fushi-hl-$c), .fushi-hl-$c, ruby.fushi-hl-$c-ruby-active',
      )
      .join(',\n');
  return '/* 收藏笔触样式：形状本身就是标记，不再叠下划线。 */\n'
      '$selectors {\n'
      '  text-decoration-line: none !important;\n'
      '}\n';
}

String _n(double v) {
  final String fixed = v.toStringAsFixed(3);
  return fixed.contains('.')
      ? fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : fixed;
}
