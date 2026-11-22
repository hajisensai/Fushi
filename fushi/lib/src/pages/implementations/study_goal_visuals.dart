/// 学习目标的共用视觉件（设计 A「目标列表」）：每种语言一个稳定的颜色、目标进度环、
/// 语言小胶囊、「语言目标」格用的语言选择。
///
/// 设置 › 目标的行、首页「语言目标」格、目标面板都从这里取色，同一种语言处处同色
/// （mockup：日本語橙、中文红、全部语言绿）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/widget_snapshot.dart'
    show StudyGoalDay, StudyGoalProgress, StudyGoalState;
import 'package:fushi/src/stats/study_goal_host.dart';
import 'package:fushi/src/pages/implementations/stat_ring.dart'
    show StatRingPainter;
import 'package:fushi/src/stats/study_goal_language_scope.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/stats/study_goals.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
    show fushiPosterHue;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show studyGoalCombinedLanguageTag, studyGoalPrimaryLanguage;

/// 常学语言的固定色相（与 mockup 对齐：日语橙、中文红；其余各占一段色环，互相
/// 拉开）。表外的语言按主语言子标签折叠出色相（跨进程稳定）。
const Map<String, double> _kLanguageHues = <String, double>{
  'ja': 22,
  'zh': 2,
  'yue': 340,
  'ko': 205,
  'en': 255,
  'fr': 228,
  'de': 48,
  'es': 32,
  'pt': 120,
  'it': 95,
  'ru': 280,
  'th': 175,
  'vi': 60,
  'id': 190,
  'tr': 315,
  'ar': 140,
};

/// 「全部语言」的色相（mockup 的 `--all`，绿）。
const double _kAllLanguagesHue = 150;

/// 不分语言的目标（复习 / 制卡）的色相（mockup 的复习琥珀色）。
const double _kNoLanguageHue = 38;

/// 一条目标（或一种语言）的色相。[language] 为 null 时：能分语言的度量 = 全部语言
/// 的绿，复习 / 制卡 = 琥珀。
double studyGoalHue(String? language, {StudyGoalId? metric}) {
  final String? primary = studyGoalPrimaryLanguage(language);
  if (primary == null) {
    return metric != null && !metric.languageScoped
        ? _kNoLanguageHue
        : _kAllLanguagesHue;
  }
  return _kLanguageHues[primary] ??
      fushiPosterHue('study-goal-language/$primary');
}

/// 一种语言的目标配色：环色、环底轨、语言胶囊底色与字色。两套主题下明度钉死、只换
/// 色相（与封面色块同一思路）；墨水屏一律黑白。
@immutable
class StudyGoalColors {
  const StudyGoalColors({
    required this.ring,
    required this.track,
    required this.soft,
    required this.onSoft,
  });

  final Color ring;
  final Color track;
  final Color soft;
  final Color onSoft;
}

StudyGoalColors studyGoalColorsOf(
  BuildContext context, {
  String? language,
  StudyGoalId? metric,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  if (isEinkTheme(context)) {
    // 墨水屏的 outlineVariant 是纯黑、中性块色是纯白：底轨都不能用（一个和进度弧
    // 一样黑、环读不出进度；一个看不见，空环 / 没满的环只剩半截弧）。底轨用浅灰
    // （前景 30%），墨水屏的灰阶画得出来，进度弧仍是纯黑。
    return StudyGoalColors(
      ring: scheme.onSurface,
      track: scheme.onSurface.withValues(alpha: 0.3),
      soft: scheme.surface,
      onSoft: scheme.onSurface,
    );
  }
  final double hue = studyGoalHue(language, metric: metric);
  Color hsl(double s, double l) => HSLColor.fromAHSL(1, hue, s, l).toColor();
  if (theme.brightness == Brightness.dark) {
    return StudyGoalColors(
      ring: hsl(0.75, 0.68),
      track: hsl(0.18, 0.28),
      soft: hsl(0.35, 0.22),
      onSoft: hsl(0.70, 0.84),
    );
  }
  return StudyGoalColors(
    ring: hsl(0.70, 0.46),
    track: hsl(0.30, 0.88),
    soft: hsl(0.70, 0.91),
    onSoft: hsl(0.65, 0.30),
  );
}

/// 目标进度环（设置行、首页「今日」格、「语言目标」格、统计页共用的一个视觉件）：
/// 底轨 + 进度弧，按 [state] 画完成状态——
/// - 没开始 / 进行中：弧长 = 进度，环心（够大时）写百分数；
/// - 已完成 / 超出：弧满一圈（超出也只画满，不绕第二圈），环心画对勾；真实数值与
///   「+4.8K」由调用方写在旁边；
/// - 休息日：环与底轨都淡下去（不是失败色），环心（够大时）一个月亮。
/// 配色全部走 [color] / [track]（语言色或色块色），不用红色、不写失败字样。
class StudyGoalRing extends StatelessWidget {
  const StudyGoalRing({
    super.key,
    required this.fraction,
    required this.color,
    required this.track,
    this.size = 44,
    this.showPercent = true,
    this.labelColor,
    this.state,
    this.detail,
  });

  /// [progress] 的环：比例与状态都从同一条进度取。
  StudyGoalRing.progress(
    StudyGoalProgress progress, {
    Key? key,
    required Color color,
    required Color track,
    double size = 44,
    bool showPercent = true,
    Color? labelColor,
    String? detail,
  }) : this(
         key: key,
         fraction: progress.fraction,
         color: color,
         track: track,
         size: size,
         showPercent: showPercent,
         labelColor: labelColor,
         state: progress.state,
         detail: detail,
       );

  /// 0..1。
  final double fraction;
  final Color color;
  final Color track;
  final double size;

  /// 环心写百分数（环小于 36 时不写：放不下）。完成 / 超出时换成对勾（环不小于 18
  /// 就画，不受这个开关影响：完成状态要一眼看得出）。
  final bool showPercent;
  final Color? labelColor;

  /// null = 只按 [fraction] 画（满一圈也不画对勾），给没有目标记录、只作可视化的环。
  final StudyGoalState? state;

  /// 环心第二行小字（统计页的大环写「3700/10000」）；环小于 72 时不写。
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final StudyGoalState? s = state;
    final bool reached = s?.reached ?? false;
    final bool rest = s == StudyGoalState.restDay;
    // 平环（mockup 的 conic 环 / 统计页 [StatRing] 同一支画笔），铺满 [size]：
    // M3E 波浪指示器有固定 40 的外框与内边距，放进 22～40 的槽里会缩成一小团、
    // 百分数压在弧上（2026-11-20 走查截图）。
    final double stroke = (size * 0.12).clamp(3.0, 9.0);
    final bool big = size >= 72;
    final bool label = showPercent && size >= 36;
    final Color text = labelColor ?? tokens.surfaces.onSurface;
    final Color arc = rest ? color.withValues(alpha: color.a * 0.45) : color;
    final Color rail = rest ? track.withValues(alpha: track.a * 0.6) : track;
    final TextStyle percentStyle =
        (big ? tokens.type.listTitle : tokens.type.metadata).copyWith(
          fontWeight: FontWeight.w700,
          color: text,
        );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: 0,
        end: reached ? 1.0 : fraction.clamp(0.0, 1.0),
      ),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double value, Widget? _) {
        Widget? center;
        if (reached && size >= 18) {
          center = FushiIcon(
            FushiIcons.check,
            size: (size * (big ? 0.34 : 0.48)).clamp(10.0, 40.0),
            color: color,
          );
        } else if (rest && size >= 28) {
          center = FushiIcon(
            FushiIcons.darkMode,
            size: (size * 0.4).clamp(10.0, 32.0),
            color: text.withValues(alpha: 0.6),
          );
        } else if (label) {
          center = Text(
            '${(value * 100).round()}%',
            maxLines: 1,
            style: percentStyle,
          );
        }
        final String? second = big ? detail : null;
        if (second != null) {
          center = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ?center,
              Text(
                second,
                maxLines: 1,
                style: tokens.type.metadata.copyWith(
                  color: text.withValues(alpha: 0.72),
                ),
              ),
            ],
          );
        }
        return SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              SizedBox.square(
                dimension: size,
                child: CustomPaint(
                  painter: StatRingPainter(
                    fraction: value,
                    color: arc,
                    trackColor: rail,
                    strokeWidth: stroke,
                  ),
                ),
              ),
              if (center != null)
                Padding(
                  padding: EdgeInsets.all(stroke + 3),
                  child: FittedBox(fit: BoxFit.scaleDown, child: center),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 周 / 月目标的双环（首页「今日」格聚焦页，设计 A）：粗的内环 = 今天（今日量 /
/// 今日份额，[StudyGoalProgress.todayState]），细的外环 = 整个周期的进度
/// （[StudyGoalProgress.state]）。两环的完成状态各管各的：外环达成画满、内环达成
/// 环心画对勾，今天休息时内环淡下去、环心一个月亮。配色同 [StudyGoalRing]。
class StudyGoalDualRing extends StatelessWidget {
  const StudyGoalDualRing({
    super.key,
    required this.progress,
    required this.color,
    required this.track,
    this.size = 64,
    this.labelColor,
  });

  final StudyGoalProgress progress;
  final Color color;
  final Color track;
  final double size;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final StudyGoalState today = progress.todayState;
    final bool periodReached = progress.state.reached;
    final bool rest = today == StudyGoalState.restDay;
    final double outerStroke = (size * 0.05).clamp(2.0, 4.0);
    final double gap = (size * 0.05).clamp(2.0, 4.0);
    final double innerSize = size - 2 * (outerStroke + gap);
    final double innerStroke = (innerSize * 0.14).clamp(3.0, 9.0);
    final Color text = labelColor ?? tokens.surfaces.onSurface;
    final Color innerArc = rest
        ? color.withValues(alpha: color.a * 0.45)
        : color;
    final Color innerRail = rest
        ? track.withValues(alpha: track.a * 0.6)
        : track;
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: 0,
              end: periodReached ? 1.0 : progress.fraction,
            ),
            duration: duration,
            curve: FushiMotion.enter,
            builder: (BuildContext context, double value, Widget? _) =>
                SizedBox.square(
                  key: const ValueKey<String>('study-goal-ring-period'),
                  dimension: size,
                  child: CustomPaint(
                    painter: StatRingPainter(
                      fraction: value,
                      color: color,
                      trackColor: track,
                      strokeWidth: outerStroke,
                    ),
                  ),
                ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: 0,
              end: today.reached ? 1.0 : progress.todayFraction,
            ),
            duration: duration,
            curve: FushiMotion.enter,
            builder: (BuildContext context, double value, Widget? _) {
              Widget? center;
              if (today.reached && innerSize >= 18) {
                center = FushiIcon(
                  FushiIcons.check,
                  size: (innerSize * 0.48).clamp(10.0, 32.0),
                  color: color,
                );
              } else if (rest && innerSize >= 24) {
                center = FushiIcon(
                  FushiIcons.darkMode,
                  size: (innerSize * 0.42).clamp(10.0, 28.0),
                  color: text.withValues(alpha: 0.6),
                );
              } else if (innerSize >= 32) {
                center = Text(
                  '${(value * 100).round()}%',
                  maxLines: 1,
                  style: tokens.type.metadata.copyWith(
                    fontWeight: FontWeight.w700,
                    color: text,
                  ),
                );
              }
              return SizedBox.square(
                key: const ValueKey<String>('study-goal-ring-today'),
                dimension: innerSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    SizedBox.square(
                      dimension: innerSize,
                      child: CustomPaint(
                        painter: StatRingPainter(
                          fraction: value,
                          color: innerArc,
                          trackColor: innerRail,
                          strokeWidth: innerStroke,
                        ),
                      ),
                    ),
                    if (center != null)
                      Padding(
                        padding: EdgeInsets.all(innerStroke + 2),
                        child: FittedBox(fit: BoxFit.scaleDown, child: center),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 周 / 月目标的「本周」柱条（首页「今日」格，设计 B）：本周起 7 格，生效日一根柱
/// （柱高 = 那天做的量）+ 一道短横（那天的份额，[StudyGoalDay.share]）；不生效 /
/// 不在周期里的日子是一个小点；今天实色，过去的日子淡色，之后的日子只有份额横线。
/// 两套外观（分区卡 / 色块）都用它，颜色由调用方给；墨水屏由调用方传黑白。
class StudyGoalDayStrip extends StatelessWidget {
  const StudyGoalDayStrip({
    super.key,
    required this.days,
    required this.labels,
    required this.semanticLabel,
    required this.color,
    required this.past,
    required this.tick,
    required this.dot,
    this.height = 44,
  });

  final List<StudyGoalDay> days;

  /// 与 [days] 对齐的悬停提示。
  final List<String> labels;
  final String semanticLabel;

  /// 今天那根柱的颜色。
  final Color color;

  /// 过去日子的柱色。
  final Color past;

  /// 份额短横的颜色。
  final Color tick;

  /// 不生效日小点的颜色。
  final Color dot;
  final double height;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    double peak = 0;
    for (final StudyGoalDay d in days) {
      if (!d.active) continue;
      peak = math.max(peak, math.max(d.value, d.share).toDouble());
    }
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    const double tickHeight = 2;
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        key: const ValueKey<String>('study-goal-day-strip'),
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < days.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: tokens.spacing.gap / 2),
              Expanded(
                child: FushiTooltip(
                  message: i < labels.length ? labels[i] : '',
                  excludeFromSemantics: true,
                  child: _day(days[i], peak, duration, tickHeight),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _day(
    StudyGoalDay d,
    double peak,
    Duration duration,
    double tickHeight,
  ) {
    if (!d.active) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox.square(
          key: ValueKey<String>('study-goal-day-dot-${d.dayKey}'),
          dimension: 5,
          child: DecoratedBox(
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
        ),
      );
    }
    final double room = height - tickHeight;
    final double shareAt = peak <= 0 ? 0 : d.share / peak * room;
    // 整格高的 Stack：柱贴底，份额短横按高度定位（Stack 只按柱高定尺寸时短横会被裁掉）。
    return SizedBox(
      key: ValueKey<String>('study-goal-day-${d.dayKey}'),
      height: height,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: <Widget>[
          if (!d.future)
            TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: 0,
                end: peak <= 0 ? 0 : d.value / peak,
              ),
              duration: duration,
              curve: FushiMotion.standard,
              builder: (BuildContext _, double f, Widget? _) => Container(
                height: math.max(3, room * f),
                decoration: BoxDecoration(
                  color: d.isToday ? color : past,
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
              ),
            ),
          if (d.share > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: shareAt,
              child: Container(
                height: tickHeight,
                decoration: BoxDecoration(
                  color: tick,
                  borderRadius: const BorderRadius.all(Radius.circular(1)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一条进度的读屏 / 提示文案：「日本語 · Chars · 3.7K / 10K · 6.3K left」——标签、
/// 紧凑数值对、状态短句（「已完成」「+4.8K」「休息日」）。首页各格与设置行共用。
String studyGoalSemanticsLabel(StudyGoalProgress g, String label) {
  final ({String value, String target}) pair = studyGoalCompactPair(
    g.value,
    g.target,
    isTime: g.id.isTime,
  );
  final String base =
      '$label · ${pair.value} / ${pair.target} · ${studyGoalStatusLabel(g)}';
  // 周 / 月目标再读今天：「5 / 18 today · 27 behind」。
  return g.splitsPeriod ? '$base · ${studyGoalTodayText(g).line}' : base;
}

/// 进度条（「今日」格总览一行下面那条）：圆头底轨 + 进度，完成 / 超出时满格，休息日
/// 淡下去。弧长变化走 [FushiMotion.long]。
class StudyGoalProgressBar extends StatelessWidget {
  const StudyGoalProgressBar({
    super.key,
    required this.progress,
    required this.color,
    required this.track,
    this.height = 4,
  });

  final StudyGoalProgress progress;
  final Color color;
  final Color track;
  final double height;

  @override
  Widget build(BuildContext context) {
    final StudyGoalState state = progress.state;
    final bool rest = state == StudyGoalState.restDay;
    final double end = state.reached ? 1.0 : progress.fraction.clamp(0.0, 1.0);
    final BorderRadius radius = BorderRadius.circular(height);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: end),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double value, Widget? _) => SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: rest ? track.withValues(alpha: track.a * 0.6) : track,
            borderRadius: radius,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: value,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: rest ? color.withValues(alpha: color.a * 0.45) : color,
                  borderRadius: radius,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 语言小胶囊（mockup `.lang`）：语言色的浅底 + 深字。
class StudyGoalLanguagePill extends StatelessWidget {
  const StudyGoalLanguagePill({
    super.key,
    required this.label,
    required this.colors,
  });

  final String label;
  final StudyGoalColors colors;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.soft,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tokens.type.metadata.copyWith(
            color: colors.onSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// 「语言目标」格挑语言：全部语言 + 候选语言（[loadStudyGoalCandidateLanguages]：已有
/// 目标的语言、默认内容语言、Profile 绑定的语言）+「其他…」（完整的内容语言表）。
/// [taken] 是首页已有格子的语言（null = 全部语言那块），带「首页已有」说明、不可选
/// （[current] 本身除外）。返回 null = 关掉没选。给了 [onChooseGoals]（改已有格子时）
/// 列表末尾多一项「挑选目标…」：点了关掉本框、返回 null 并调它。
Future<({String? language})?> showStudyGoalLanguagePicker({
  required BuildContext context,
  required StudyGoalHost appModel,
  required String? current,
  Set<String?> taken = const <String?>{},
  VoidCallback? onChooseGoals,
}) async {
  final List<String> candidates = await loadStudyGoalCandidateLanguages(
    appModel.database,
    appModel.prefsRepo,
  );
  if (!context.mounted) return null;
  // 有文字之分的语言（中文）：整门语言在前，紧跟「只算简体 / 繁体」两项。
  final List<String?> options = <String?>[null];
  void add(String? tag) {
    if (options.any((String? e) => studyGoalSameLanguage(e, tag))) return;
    options.add(tag);
  }

  for (final String tag in <String>[...candidates, ?current]) {
    final List<String> variants = studyGoalScriptVariantsOf(tag);
    if (variants.isEmpty) {
      add(tag);
      continue;
    }
    add(studyGoalCombinedLanguageTag(tag));
    variants.forEach(add);
  }
  final Set<String?> scriptOnly = <String?>{
    for (final String? tag in options)
      if (tag != null &&
          studyGoalScriptVariantsOf(
            tag,
          ).any((String v) => studyGoalSameLanguage(v, tag)))
        tag,
  };
  bool isTaken(String? tag) =>
      !studyGoalSameLanguage(tag, current) &&
      taken.any((String? e) => studyGoalSameLanguage(e, tag));

  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final Object? picked = await showAppDialog<Object?>(
    context: context,
    builder: (BuildContext dialogContext) => FushiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.78,
      child: FushiModalSheetFrame(
        title: t.stat_goal_language,
        subtitle: t.home_language_goals_pick_description,
        leadingIcon: FushiIcons.language,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String? tag in options)
              FushiListItem(
                key: ValueKey<String>('study-goal-language-pick-${tag ?? '*'}'),
                leading: _LanguageDot(
                  colors: studyGoalColorsOf(dialogContext, language: tag),
                ),
                title: Text(studyGoalLanguageLabel(tag)),
                subtitle: isTaken(tag)
                    ? Text(t.home_language_goals_pick_taken)
                    : scriptOnly.contains(tag)
                    ? Text(t.study_goal_language_script_only_hint)
                    : null,
                selected: studyGoalSameLanguage(tag, current),
                trailing: studyGoalSameLanguage(tag, current)
                    ? const FushiIcon(FushiIcons.check)
                    : null,
                onTap: isTaken(tag)
                    ? null
                    : () => Navigator.pop(dialogContext, (language: tag)),
              ),
            FushiListItem(
              key: const ValueKey<String>('study-goal-language-pick-other'),
              leading: const FushiIcon(FushiIcons.language),
              title: Text(t.study_goal_sheet_language_other),
              onTap: () => Navigator.pop(dialogContext, _PickOther.other),
            ),
            if (onChooseGoals != null)
              FushiListItem(
                key: const ValueKey<String>('study-goal-language-pick-goals'),
                leading: const FushiIcon(FushiIcons.checklist),
                title: Text(t.home_language_goals_choose),
                onTap: () => Navigator.pop(dialogContext, _PickOther.goals),
              ),
          ],
        ),
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            adaptiveDialogAction(
              context: dialogContext,
              child: Text(t.dialog_cancel),
              onPressed: () => Navigator.pop(dialogContext),
            ),
          ],
        ),
      ),
    ),
  );
  if (picked is ({String? language})) return picked;
  if (picked == _PickOther.goals) {
    onChooseGoals?.call();
    return null;
  }
  if (picked != _PickOther.other || !context.mounted) return null;
  ({String? language})? other;
  await showContentLanguagePicker(
    context: context,
    title: t.stat_goal_language,
    description: t.home_language_goals_pick_description,
    current: current,
    autoDetected: '',
    autoLabel: t.stat_goal_language_all,
    onSelected: (String? tag) => other = (language: tag),
  );
  return other;
}

enum _PickOther { other, goals }

/// 「语言目标」格挑显示哪些目标：勾选目标记录（先列格子语言 [language] 的，
/// 「显示全部语言」打开后列全部，可混语言），至多 [kStudyGoalRingSlots] 条，顺序 =
/// 勾选顺序（行尾写序号）。返回挑的记录 id（空 = 自动：这种语言的目标按周期挑）；
/// null = 取消。
Future<List<String>?> showHomeTileGoalsPicker({
  required BuildContext context,
  required StudyGoalHost appModel,
  required String? language,
  required List<String> current,
}) async {
  final List<StudyGoal> goals = appModel.studyGoals;
  final List<String> chosen = <String>[
    for (final String id in current)
      if (goals.any((StudyGoal g) => g.id == id)) id,
  ];
  bool allLanguages = chosen.any(
    (String id) => !studyGoalSameLanguage(
      goals.firstWhere((StudyGoal g) => g.id == id).language,
      language,
    ),
  );
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final Object? result = await showAppDialog<Object?>(
    context: context,
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) {
        final List<StudyGoal> shown = <StudyGoal>[
          for (final StudyGoal g in goals)
            if (allLanguages ||
                studyGoalSameLanguage(g.language, language) ||
                chosen.contains(g.id))
              g,
        ];
        final bool full = chosen.length >= kStudyGoalRingSlots;
        return FushiDialogFrame(
          maxWidth: 460,
          maxHeightFactor: 0.82,
          child: FushiModalSheetFrame(
            title: t.home_language_goals_choose_title,
            subtitle: t.home_language_goals_choose_description(
              max: kStudyGoalRingSlots,
            ),
            leadingIcon: FushiIcons.checklist,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiListItem(
                  key: const ValueKey<String>('home-tile-goals-all-languages'),
                  title: Text(t.home_language_goals_choose_all_languages),
                  trailing: adaptiveSwitch(
                    context: context,
                    value: allLanguages,
                    onChanged: (bool on) => setState(() => allLanguages = on),
                  ),
                  onTap: () => setState(() => allLanguages = !allLanguages),
                ),
                if (shown.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(tokens.spacing.card),
                    child: Text(
                      t.home_language_goals_choose_empty,
                      style: tokens.type.metadata,
                    ),
                  ),
                for (final StudyGoal g in shown)
                  _goalPickRow(
                    context,
                    appModel,
                    g,
                    order: chosen.indexOf(g.id),
                    full: full,
                    onToggle: () => setState(
                      () => chosen.contains(g.id)
                          ? chosen.remove(g.id)
                          : chosen.add(g.id),
                    ),
                  ),
              ],
            ),
            footer: Row(
              children: <Widget>[
                adaptiveDialogAction(
                  context: dialogContext,
                  child: Text(t.home_language_goals_choose_auto),
                  onPressed: () =>
                      Navigator.pop(dialogContext, const <String>[]),
                ),
                const Spacer(),
                adaptiveDialogAction(
                  context: dialogContext,
                  child: Text(t.dialog_cancel),
                  onPressed: () => Navigator.pop(dialogContext),
                ),
                adaptiveDialogAction(
                  context: dialogContext,
                  isDefaultAction: true,
                  child: Text(t.dialog_done),
                  onPressed: () =>
                      Navigator.pop(dialogContext, List<String>.of(chosen)),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  return result is List<String> ? result : null;
}

/// 挑目标框里的一行：语言色点、目标名、周期 · 目标量；勾上的行尾写序号。已挑满时
/// 没勾的行不可点。
Widget _goalPickRow(
  BuildContext context,
  StudyGoalHost appModel,
  StudyGoal goal, {
  required int order,
  required bool full,
  required VoidCallback onToggle,
}) {
  final bool on = order >= 0;
  return FushiListItem(
    key: ValueKey<String>('home-tile-goals-item-${goal.id}'),
    leading: _LanguageDot(
      colors: studyGoalColorsOf(context, language: goal.language),
    ),
    title: Text(studyGoalLabel(goal, unitChoice: appModel.readingGoalTextUnit)),
    subtitle: Text(
      '${studyGoalPeriodLabel(goal.period)} · ${studyGoalTargetLabel(goal)}',
    ),
    selected: on,
    trailing: on ? _OrderBadge(order: order + 1) : null,
    onTap: !on && full ? null : onToggle,
  );
}

/// 勾选目标的序号（1 / 2 / 3）。
class _OrderBadge extends StatelessWidget {
  const _OrderBadge({required this.order});

  final int order;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 26,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            '$order',
            style: TextStyle(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguageDot extends StatelessWidget {
  const _LanguageDot({required this.colors});

  final StudyGoalColors colors;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 14,
    child: DecoratedBox(
      decoration: BoxDecoration(color: colors.ring, shape: BoxShape.circle),
    ),
  );
}
