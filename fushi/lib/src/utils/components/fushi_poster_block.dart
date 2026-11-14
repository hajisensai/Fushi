import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/shell_style.dart' show shellShape;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize, fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_bleed_title.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadPalette, FushiMastheadPrimaryButton, fushiMastheadCompact;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

// =============================================================================
// 不带封面的「海报色块」（重设计外壳，设计稿 `.box` 的 `.deck` / `.stat` /
// `.word` / `.src` 一族）：浏览 / 查词 / 复习这类不是库网格的页面用。
//
// 与封面色块（`FushiCoverBlock`）同一套配色（[FushiCoverBlockColors.resolve]
// 的 HSL：只取色相、明度钉死，两套主题下前景都可读），但色相不从封面取，而是
// 由调用点按稳定的键（牌组 id、词条）折叠出来（[fushiPosterHue]）。左上 / 左下
// 一行被色块裁掉的 900 字重大字水印；悬停时水印沿 X 滑开、整块抬升
// （[FushiHoverLift]），时长只取 [FushiMotion]。本组件只管视觉：点按 / 焦点 /
// 菜单由调用点的原有外壳负责。
// =============================================================================

/// 由稳定的键折叠出色相（0–360），跨进程稳定（不用 [String.hashCode]）。
double fushiPosterHue(String key) {
  int h = 0;
  for (final int unit in key.codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return (h % 360).toDouble();
}

/// 色相 [hue] 下的色块配色（与封面色块同一套 HSL）。
FushiCoverBlockColors fushiPosterColors(BuildContext context, double hue) =>
    FushiCoverBlockColors.resolve(
      Theme.of(context),
      ColorScheme.light(primary: HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor()),
    );

/// 水印贴在色块的哪一边（设计稿 `.wm` 顶 / `.wm.lo` 底）。
enum FushiPosterWatermarkEdge { top, bottom }

/// 海报色块。见文件头。
class FushiPosterBlock extends StatelessWidget {
  const FushiPosterBlock({
    required this.watermark,
    required this.colors,
    required this.child,
    this.watermarkFontSize = 120,
    this.watermarkEdge = FushiPosterWatermarkEdge.top,
    this.watermarkStart = -8,
    this.radius,
    this.blockSize = FushiCoverBlockSize.regular,
    this.padding = const EdgeInsets.all(22),
    this.hoverEnabled = true,
    super.key,
  });

  /// 大字水印（纯装饰，不进语义、不接命中）；空串 = 不画。
  final String watermark;
  final FushiCoverBlockColors colors;

  /// 前景内容（排在 [padding] 里）。
  final Widget child;
  final double watermarkFontSize;
  final FushiPosterWatermarkEdge watermarkEdge;

  /// 水印起始边的横向偏移（设计稿 `.deck .wm{left:52%}` 这类右移由调用点给）。
  final double watermarkStart;

  /// 固定圆角半径；为空（默认）时按 [blockSize] 档随实际高度取
  /// `fushiCoverBlockRadius`，与封面色块、卡壳（`shelfCoverCard(shape:
  /// fushiCoverBlockShape(...))`）同一个外形。
  final double? radius;

  /// [radius] 为空时的色块尺寸档。
  final FushiCoverBlockSize blockSize;
  final EdgeInsetsGeometry padding;

  /// false = 不随悬停抬升 / 滑水印（块里有自己的可交互件、整块不是点按目标）。
  final bool hoverEnabled;

  @override
  Widget build(BuildContext context) {
    final double? fixed = radius;
    final OutlinedBorder shape = fixed == null
        ? fushiCoverBlockShape(context, blockSize)
        : shellShape(context, BorderRadius.circular(fixed));
    return FushiHoverLift(
      enabled: hoverEnabled,
      builder: (BuildContext context, bool hovering) => DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          color: colors.container,
          shadows: const <BoxShadow>[
            BoxShadow(
              color: Color(0x2E000000),
              offset: Offset(0, 8),
              blurRadius: 20,
            ),
          ],
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(
            shape: shape,
            textDirection: Directionality.maybeOf(context),
          ),
          child: Stack(
            children: <Widget>[
              if (watermark.isNotEmpty)
                _PosterWatermark(
                  text: watermark,
                  colors: colors,
                  fontSize: watermarkFontSize,
                  edge: watermarkEdge,
                  start: watermarkStart,
                  shifted: hovering,
                ),
              Padding(
                padding: padding,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: colors.onContainer),
                  child: IconTheme.merge(
                    data: IconThemeData(color: colors.onContainer),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PosterWatermark extends StatelessWidget {
  const _PosterWatermark({
    required this.text,
    required this.colors,
    required this.fontSize,
    required this.edge,
    required this.start,
    required this.shifted,
  });

  final String text;
  final FushiCoverBlockColors colors;
  final double fontSize;
  final FushiPosterWatermarkEdge edge;
  final double start;
  final bool shifted;

  @override
  Widget build(BuildContext context) {
    final bool top = edge == FushiPosterWatermarkEdge.top;
    // 起始边按阅读方向：RTL 下水印贴右边、悬停往起始边滑开（整块镜像）。画出来的
    // 装饰大字（不是 Text）：不进语义、不进文字查找，标题只读一遍。
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: shifted ? -40 : 0),
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        builder: (BuildContext context, double shift, Widget? _) =>
            DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodyMedium,
              child: FushiBleedTitle(
                text: text,
                textSize: fontSize,
                color: colors.accent.withValues(alpha: colors.watermarkOpacity),
                start: start,
                top: top ? fontSize * 0.02 : null,
                bottom: top ? null : -fontSize * 0.12,
                shiftOffset: shift,
              ),
            ),
      ),
    );
  }
}

/// 色块里的小胶囊（设计稿 `.chip`：实色 = 强调色底；`.chip.g` = 前景色 14% 底）。
class FushiPosterChip extends StatelessWidget {
  const FushiPosterChip({
    required this.label,
    required this.colors,
    this.solid = false,
    this.icon,
    super.key,
  });

  final String label;
  final FushiCoverBlockColors colors;
  final bool solid;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color fg = solid ? colors.container : colors.onContainer;
    final TextStyle base =
        Theme.of(context).textTheme.labelSmall ?? const TextStyle();
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: solid
            ? colors.accent
            : colors.onContainer.withValues(alpha: 0.14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: <Widget>[
            if (icon != null) FushiIcon(icon!, size: 13, color: fg),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base.copyWith(
                  fontSize: context.fushiType.labelSmall.fontSize,
                  fontWeight: FontWeight.w800,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 海报色块里的文字字阶。设计稿给色块里的粗大字定死了几档（与水印 / 大数字
/// 同一套版式比例，不随 M3E 字阶走）；页面不写字号，按角色取：
/// `FushiPosterText.caption.on(base).copyWith(color: ...)`。不带 [height] /
/// [letterSpacing] 的档沿用 [on] 传入底样式的值。
enum FushiPosterText {
  /// 副行 / 域名 / 小标签（12 w700）。
  meta(12, FontWeight.w700),

  /// 胶囊里的极小标签（11 w700）。
  badge(11, FontWeight.w700),

  /// 榜单预览行（12.5 w800，行高 1.35）。
  line(12.5, FontWeight.w800, height: 1.35),

  /// 说明行（设计稿 `.cap`，13 w800）。
  caption(13, FontWeight.w800),

  /// 半高卡的小标题（17 w900，行高 1.15）。
  label(17, FontWeight.w900, height: 1.15),

  /// 块名 / 首字圆章（20 w900）。
  name(20, FontWeight.w900),

  /// 分区标题 / 站点名（24 w900）。
  section(24, FontWeight.w900, letterSpacing: -0.5),

  /// 状态大句（26 w900，行高 1.1）。
  statement(26, FontWeight.w900, height: 1.1, letterSpacing: -0.5),

  /// 窄窗主块标题（28 w900）。
  titleCompact(28, FontWeight.w900, height: 1.05, letterSpacing: -0.5),

  /// 词条大字（32 w900）。
  term(32, FontWeight.w900, height: 1.05, letterSpacing: -1.2),

  /// 主块标题（34 w900）。
  title(34, FontWeight.w900, height: 1.05, letterSpacing: -0.5),

  /// 完成态 / 今日大标题（34 w900，行高 1）。
  headline(34, FontWeight.w900, height: 1, letterSpacing: -1),

  /// 横版今日大标题（44 w900，行高 1）。
  display(44, FontWeight.w900, height: 1, letterSpacing: -1);

  const FushiPosterText(
    this.size,
    this.weight, {
    this.height,
    this.letterSpacing,
  });

  final double size;
  final FontWeight weight;
  final double? height;
  final double? letterSpacing;

  /// 以 [base]（通常是 `textTheme.bodyMedium`）为底套上本档字号 / 字重 / 行高 /
  /// 字距。
  TextStyle on(TextStyle base) => base.copyWith(
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: letterSpacing,
  );
}

/// [FushiPosterFigure] 的字号档（设计稿 `.stat .n` 64 / `.deck .due` 92 / 横版 120）。
enum FushiPosterFigureSize {
  compact(64),
  regular(92),
  large(120);

  const FushiPosterFigureSize(this.size);

  final double size;
}

/// 色块里的大数字 + 小单位（设计稿 `.deck .due` / `.stat .n`）。
class FushiPosterFigure extends StatelessWidget {
  const FushiPosterFigure({
    required this.value,
    required this.colors,
    this.unit,
    this.size = FushiPosterFigureSize.regular,
    super.key,
  });

  final String value;
  final String? unit;
  final FushiCoverBlockColors colors;
  final FushiPosterFigureSize size;

  @override
  Widget build(BuildContext context) {
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final double fontSize = size.size;
    final String? small = unit;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: value,
            style: base.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              height: 0.86,
              letterSpacing: -0.06 * fontSize,
              color: colors.accent,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          if (small != null)
            TextSpan(
              text: ' $small',
              style: base.copyWith(
                fontSize: context.fushiType.titleMedium.fontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
                color: colors.accent,
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 页头大字顶栏右端带字的主按钮（设计稿 `.cta`：图标 + 文字）；窄窗只留图标
/// （文字进 tooltip 与语义）。形状 / 配色 / 悬停弹角由 [FushiMastheadPrimaryButton]
/// 给。
class FushiMastheadCtaButton extends StatelessWidget {
  const FushiMastheadCtaButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.buttonKey,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final bool compact = fushiMastheadCompact(context);
    final TextStyle base =
        Theme.of(context).textTheme.labelLarge ?? const TextStyle();
    return FushiMastheadPrimaryButton(
      selected: false,
      builder:
          (
            BuildContext context,
            OutlinedBorder shape,
            FushiMastheadPalette palette,
            double extent,
          ) => FushiTooltip(
            message: label,
            excludeFromSemantics: true,
            child: Semantics(
              button: true,
              label: label,
              excludeSemantics: true,
              child: Material(
                key: buttonKey,
                shape: shape,
                color: palette.indicator,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  customBorder: shape,
                  onTap: onPressed,
                  child: SizedBox(
                    height: extent,
                    width: compact ? extent : null,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 0 : 24,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 8,
                        children: <Widget>[
                          FushiIcon(icon, size: 22, color: palette.onIndicator),
                          if (!compact)
                            Text(
                              label,
                              maxLines: 1,
                              style: base.copyWith(
                                fontSize:
                                    context.fushiType.titleMedium.fontSize,
                                fontWeight: FontWeight.w800,
                                color: palette.onIndicator,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    );
  }
}

/// 色块里的按钮配色：前景 / 背景都从块自己的取色方案里拿，不用主题 primary——
/// 与封面色块「继续」主按钮（强调色底、底色字）同一口径，绿色块配绿色按钮。
/// [tonal] = 次要按钮（前景色 14% 底、前景色字）。
ButtonStyle fushiPosterButtonStyle(
  FushiCoverBlockColors colors, {
  bool tonal = false,
}) => FilledButton.styleFrom(
  backgroundColor: tonal
      ? colors.onContainer.withValues(alpha: 0.14)
      : colors.accent,
  foregroundColor: tonal ? colors.onContainer : colors.container,
  iconColor: tonal ? colors.onContainer : colors.container,
  disabledBackgroundColor: colors.onContainer.withValues(alpha: 0.08),
  disabledForegroundColor: colors.onContainer.withValues(alpha: 0.38),
  disabledIconColor: colors.onContainer.withValues(alpha: 0.38),
);

/// 色块里的完成度圆环（设计稿 `.deck .ring`）：底圈前景色 18%、弧强调色，中间默认
/// 是百分数（带 %）。[value] 为 null = 没有目标：只画底圈，中间换成 [center]（旗子等）。
/// 弧长变化走 [FushiMotion.long]。纯装饰，语义由调用点给。
class FushiPosterRing extends StatelessWidget {
  const FushiPosterRing({
    required this.value,
    required this.colors,
    this.size = 72,
    this.center,
    super.key,
  });

  /// 0–1；null = 未设目标。
  final double? value;
  final FushiCoverBlockColors colors;
  final double size;

  /// 中间件；null 时画百分数（[value] 也为 null 时留空）。
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final TextStyle base =
        Theme.of(context).textTheme.labelLarge ?? const TextStyle();
    final double? target = value;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: (target ?? 0).clamp(0.0, 1.0)),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double v, Widget? _) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _PosterRingPainter(
            value: v,
            track: colors.onContainer.withValues(alpha: 0.18),
            arc: colors.accent,
            stroke: size / 9,
          ),
          child: Center(
            child: ExcludeSemantics(
              child:
                  center ??
                  (target == null
                      ? const SizedBox.shrink()
                      : Text(
                          // 带百分号：只画一个裸数字时读不出是进度（用户
                          // 2026-11-13「含义不明的 0」）。
                          '${(v * 100).round()}%',
                          style: base.copyWith(
                            fontSize: size * 0.21,
                            fontWeight: FontWeight.w900,
                            color: colors.onContainer,
                          ),
                        )),
            ),
          ),
        ),
      ),
    );
  }
}

class _PosterRingPainter extends CustomPainter {
  const _PosterRingPainter({
    required this.value,
    required this.track,
    required this.arc,
    required this.stroke,
  });

  final double value;
  final Color track;
  final Color arc;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(stroke / 2);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        paint..color = arc,
      );
    }
  }

  @override
  bool shouldRepaint(_PosterRingPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.track != track ||
      oldDelegate.arc != arc ||
      oldDelegate.stroke != stroke;
}

/// 色块底行的小柱（设计稿 `.deck .bars`）：逐项数值按最大值归一，[highlightIndex]
/// 那根实色、其余 70%；全为 0 时贴底一线。[labels] 非空时每根柱子带悬停提示
/// （提示不进语义——整组语义由调用点包一层给）。首次出现也从底长起，时长
/// [FushiMotion.long]。
class FushiPosterBars extends StatelessWidget {
  const FushiPosterBars({
    required this.values,
    required this.colors,
    this.highlightIndex = 0,
    this.labels,
    this.height = 46,
    super.key,
  });

  final List<int> values;
  final FushiCoverBlockColors colors;
  final int highlightIndex;

  /// 与 [values] 对齐的悬停提示文案；null = 不挂提示。
  final List<String>? labels;
  final double height;

  @override
  Widget build(BuildContext context) {
    final int peak = values.fold<int>(0, math.max);
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    final List<String>? tips = labels;
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          spacing: 5,
          children: <Widget>[
            for (int i = 0; i < values.length; i++)
              Expanded(
                child: _maybeTip(
                  tips != null && i < tips.length ? tips[i] : null,
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: peak == 0 ? 0 : values[i] / peak,
                    ),
                    duration: duration,
                    curve: FushiMotion.enter,
                    builder: (BuildContext _, double f, Widget? _) => Container(
                      height: math.max(4, height * f),
                      decoration: BoxDecoration(
                        color: colors.accent.withValues(
                          alpha: i == highlightIndex ? 1 : 0.7,
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(6),
                          bottom: Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _maybeTip(String? message, Widget child) => message == null
      ? child
      : FushiTooltip(
          message: message,
          excludeFromSemantics: true,
          child: child,
        );
}
