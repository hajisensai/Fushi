/// 首页「复习」入口条（[HomeDashboardPanel.srsReview]）。
///
/// 一行高：前导图标 + 「复习」+ 今日新卡 / 学习中 / 到期三色计数 + 「开始复习」主按钮；
/// 点条目本身进牌组列表（复习 tab）。今天没有待复习的卡时计数与按钮换成一句
/// 「今日已完成」。下面一行是今天已做的复习（张数 · 用时 · 正确率，[srsTodayReviewSummaryProvider]，
/// 与复习统计页「今天」同口径；4mY-bG0T96）。计数直接读牌组列表同一个 provider（[srsDeckListProvider]）的顶层
/// 行之和，口径与牌组列表逐字相同，不另算一套；写操作 / 制卡 / 同步都经
/// [srsRevisionProvider] 让它重读。
///
/// 计数异步加载：数据回来前挂同尺寸骨架，行高恒定（加载前后、有卡 / 已完成三态
/// 同一高度），首页首帧不等数据库、也不跳布局。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiSkeleton, FushiSkeletonShimmer;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize, fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;

/// 首页此刻是否真被看着（首页 dashboard 按 TickerMode 写入：所在 tab 隐藏、或被别的页面盖住时为 false）。
final StateProvider<bool> homeSrsLiveProvider = StateProvider<bool>(
  (Ref ref) => true,
);

/// 首页用的牌组列表：首页看得见时订阅 [srsDeckListProvider]（写操作 / 制卡 / 同步后重读）；看不见时只取当前
/// 已有的值、不订阅——没人订阅时 [srsDeckListProvider] 不重算，用户在阅读器里制卡、后台同步收数据都不会让
/// 看不见的首页在 UI isolate 上重扫一遍全部卡片。回到首页重新订阅，脏了就重算一次。
final Provider<AsyncValue<SrsDeckListData?>> homeSrsDeckListProvider =
    Provider<AsyncValue<SrsDeckListData?>>(
      (Ref ref) => ref.watch(homeSrsLiveProvider)
          ? ref.watch(srsDeckListProvider)
          : ref.read(srsDeckListProvider),
    );

/// 今天已做的复习（[SrsDbStore.todayReviewSummary]，与复习统计页「今天」同口径）；写操作 / 作答 / 同步
/// 都经 [srsRevisionProvider] 让它重读。没有复习库时为 null。
final FutureProvider<SrsTodayReviewSummary?> srsTodayReviewSummaryProvider =
    FutureProvider<SrsTodayReviewSummary?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      return store?.todayReviewSummary();
    });

/// 首页用的「今日」复习汇总：与 [homeSrsDeckListProvider] 同一条订阅规则（首页看不见时不订阅、不重算）。
final Provider<AsyncValue<SrsTodayReviewSummary?>> homeSrsTodayReviewsProvider =
    Provider<AsyncValue<SrsTodayReviewSummary?>>(
      (Ref ref) => ref.watch(homeSrsLiveProvider)
          ? ref.watch(srsTodayReviewSummaryProvider)
          : ref.read(srsTodayReviewSummaryProvider),
    );

/// 首页复习条「今日」一行的文字：已复习张数 · 用时，有复习时再加正确率（与统计页今天一节同口径）。
/// 「N 张」类已译计数文案（如 `srs_home_deck_cards`）拆出排在大数字后面的小单位：
/// 文案以 [number] 开头时取其余部分（「84 张」→「张」、「84 cards」→「cards」）；
/// 数字不在开头（俄语「Карт: 84」这类单位前置的语言）时返回 null，大字只画数字，
/// 完整文案由调用点放进读屏标签。复用已有译文，不另立一份未翻译的单位 key。
String? homePosterUnitOf(String counted, String number) {
  if (!counted.startsWith(number)) return null;
  final String rest = counted.substring(number.length).trim();
  return rest.isEmpty ? null : rest;
}

String homeSrsTodayLine(SrsTodayReviewSummary s) {
  final String time = s.durationMs < 60000
      ? t.srs_stats_seconds(n: (s.durationMs / 1000).round())
      : formatStatTime(s.durationMs);
  final double? rate = s.correctRate;
  return <String>[
    t.home_srs_panel_today(count: s.count, time: time),
    if (rate != null) '${t.srs_stats_today_correct} ${(rate * 100).round()}%',
  ].join(' · ');
}

/// 复习条该不该出现在首页（纯函数，判据的唯一实现）。
///
/// - 复习模块关着：恒不显示（模块关着时不建任何 SRS 状态，档位也不读）。
/// - 用户钉了显示 / 隐藏：照办。
/// - 自动：挖词目标 = Fushi 复习，或库里已有复习卡（[totalCards] > 0）。卡数还在
///   加载（null）时先不显示——制卡仍发 Anki 的用户不会因为加载期而闪出一栏。
bool resolveHomeSrsPanelVisible({
  required bool moduleEnabled,
  required HomeDashboardPanelMode mode,
  required bool miningToReview,
  required int? totalCards,
}) {
  if (!moduleEnabled) return false;
  return switch (mode) {
    HomeDashboardPanelMode.shown => true,
    HomeDashboardPanelMode.hidden => false,
    HomeDashboardPanelMode.auto =>
      miningToReview || (totalCards != null && totalCards > 0),
  };
}

/// [resolveHomeSrsPanelVisible] 的 Riverpod 装配（首页 dashboard 订阅它决定是否
/// 挂这一栏）。只有自动档且挖词目标不是复习时才需要卡数，才去读牌组列表。
final Provider<bool> homeSrsPanelVisibleProvider = Provider<bool>((Ref ref) {
  final bool moduleEnabled = ref.watch(srsModuleEnabledProvider);
  if (!moduleEnabled) return false;
  final HomeDashboardPanelMode mode = ref.watch(
    appProvider.select(
      (AppModel app) =>
          app.homeDashboardPanelMode(HomeDashboardPanel.srsReview),
    ),
  );
  final bool miningToReview = ref.watch(srsMiningToReviewProvider);
  final bool needsCount =
      mode == HomeDashboardPanelMode.auto && !miningToReview;
  final int? totalCards = needsCount
      ? ref.watch(
          homeSrsDeckListProvider.select(
            (AsyncValue<SrsDeckListData?> d) => d.valueOrNull?.totalCards,
          ),
        )
      : null;
  return resolveHomeSrsPanelVisible(
    moduleEnabled: moduleEnabled,
    mode: mode,
    miningToReview: miningToReview,
    totalCards: totalCards,
  );
});

/// 首页复习条。显隐由 dashboard 按 [homeSrsPanelVisibleProvider] 决定；本 widget
/// 只管画。
class HomeSrsPanel extends ConsumerWidget {
  const HomeSrsPanel({
    super.key,
    required this.onOpenDecks,
    required this.onStartReview,
    this.poster = false,
  });

  /// 点条目本身：进牌组列表。
  final VoidCallback onOpenDecks;

  /// 点「开始复习」：直接复习这个牌组（[SrsDeckListData.firstRootWithWork]）。
  final void Function(SrsDeckSummary deck) onStartReview;

  /// true = 重设计外壳的海报色块形态（[_HomeSrsPoster]，与复习页「今日计划」
  /// 色块同一套件）；false = 原一行条。由首页按外壳门控传入。
  final bool poster;

  /// 内容行的固定高度：骨架 / 计数 / 已完成三态同高，切换时不跳布局。
  static const double rowHeight = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsDeckListData? data = ref
        .watch(homeSrsDeckListProvider)
        .valueOrNull;
    final SrsDeckSummary? target = data?.firstRootWithWork;
    final SrsTodayReviewSummary? today = ref
        .watch(homeSrsTodayReviewsProvider)
        .valueOrNull;
    if (poster) {
      return _HomeSrsPoster(
        data: data,
        target: target,
        today: today,
        onOpenDecks: onOpenDecks,
        onStartReview: onStartReview,
      );
    }
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = apple
        ? FushiAppleMetrics.of(context).groupBorderRadius
        : FushiBorderRadius.card;
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.group;

    final Widget status;
    if (data == null) {
      status = const _HomeSrsCountsSkeleton(key: ValueKey<String>('loading'));
    } else if (!data.hasWorkToday && !data.rwkvPending) {
      status = Row(
        key: const ValueKey<String>('done'),
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          FushiIcon(
            FushiIcons.check,
            size: 18,
            color: tokens.type.metadata.color,
          ),
          Flexible(
            child: Text(
              t.home_srs_panel_done,
              key: const ValueKey<String>('home-srs-panel-done'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.metadata,
            ),
          ),
        ],
      );
    } else {
      status = Row(
        key: const ValueKey<String>('counts'),
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          SrsCountTriple(
            key: const ValueKey<String>('home-srs-panel-counts'),
            newCount: data.todayNew,
            learnCount: data.todayLearn,
            reviewCount: data.todayReview,
            reviewPending: data.rwkvPending,
            dense: true,
          ),
          if (target != null)
            Flexible(
              child: FushiFilledButton.tonal(
                key: const ValueKey<String>('home-srs-panel-start'),
                onPressed: () => onStartReview(target),
                child: Text(
                  t.home_srs_panel_start,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      );
    }

    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: Material(
          key: const ValueKey<String>('home-srs-panel'),
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: eink
                ? BorderSide(color: tokens.surfaces.outline)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey<String>('home-srs-panel-open'),
            onTap: onOpenDecks,
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.spacing.gap + 4,
                tokens.spacing.gap / 2,
                tokens.spacing.gap / 2 + 4,
                tokens.spacing.gap / 2,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    height: rowHeight,
                    child: Row(
                      children: <Widget>[
                        FushiIcon(
                          FushiIcons.repeat,
                          size: 18,
                          color: tokens.type.sectionLabel.color,
                        ),
                        SizedBox(width: tokens.spacing.gap / 2),
                        Text(
                          t.nav_srs,
                          maxLines: 1,
                          style: tokens.type.sectionLabel,
                        ),
                        SizedBox(width: tokens.spacing.gap),
                        Expanded(
                          child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: AnimatedSwitcher(
                              duration: fushiMotionDuration(
                                context,
                                FushiMotion.short,
                              ),
                              switchInCurve: FushiMotion.enter,
                              switchOutCurve: FushiMotion.exit,
                              layoutBuilder:
                                  (Widget? current, List<Widget> previous) =>
                                      Stack(
                                        alignment:
                                            AlignmentDirectional.centerEnd,
                                        children: <Widget>[
                                          ...previous,
                                          if (current != null) current,
                                        ],
                                      ),
                              child: status,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _HomeSrsTodayLine(today: today),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「今日」一行（今天已复习张数 · 用时 · 正确率）：固定行高，数据回来前挂同高骨架，不跳布局。
class _HomeSrsTodayLine extends StatelessWidget {
  const _HomeSrsTodayLine({required this.today});

  final SrsTodayReviewSummary? today;

  /// 行高：骨架 / 文字两态同高。
  static const double height = 20;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsTodayReviewSummary? s = today;
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: 18 + tokens.spacing.gap / 2),
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: AlignmentDirectional.centerStart,
            children: <Widget>[...previous, ?current],
          ),
          child: s == null
              ? const FushiSkeletonShimmer(
                  key: ValueKey<String>('home-srs-today-skeleton'),
                  child: FushiSkeleton(width: 140, height: 12),
                )
              : Text(
                  homeSrsTodayLine(s),
                  key: const ValueKey<String>('home-srs-panel-today'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
        ),
      ),
    );
  }
}

/// 重设计外壳下的首页复习面板（[HomeSrsPanel.poster]）：与复习页首块「今日计划」
/// （`srs_deck_home.dart` 的 `_SrsTodayPoster`）同一套海报色块——按「从哪个牌组
/// 开始」的牌组 id 取色（两页同一张色块同一个色），「复习」大字水印；左上是
/// 「复习」chip、右上是今日完成度圆环；中间是今天还剩的张数大字（全部完成时换成
/// 「今日已完成」）；下面到期 / 学习中 / 新卡三个计数 chip；底行是今日已复习
/// 张数 · 用时 · 正确率 + 「开始复习」。点色块本身进牌组列表。
///
/// 信息与原一行条一一对应，key 沿用（`home-srs-panel` / `-open` / `-counts` /
/// `-start` / `-done` / `-today` / `-skeleton`）。
class _HomeSrsPoster extends StatelessWidget {
  const _HomeSrsPoster({
    required this.data,
    required this.target,
    required this.today,
    required this.onOpenDecks,
    required this.onStartReview,
  });

  final SrsDeckListData? data;
  final SrsDeckSummary? target;
  final SrsTodayReviewSummary? today;
  final VoidCallback onOpenDecks;
  final void Function(SrsDeckSummary deck) onStartReview;

  @override
  Widget build(BuildContext context) {
    final SrsDeckListData? d = data;
    final SrsDeckSummary? go = target;
    final SrsTodayReviewSummary? s = today;
    final FushiCoverBlockColors colors = fushiPosterColors(
      context,
      fushiPosterHue(go?.deck.id ?? 'srs-today'),
    );
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final TextStyle caption = FushiPosterText.caption
        .on(base)
        .copyWith(color: colors.onContainer.withValues(alpha: 0.85));
    final bool allDone = d != null && !d.hasWorkToday && !d.rwkvPending;
    final int remaining = d == null
        ? 0
        : d.todayNew + d.todayLearn + d.todayReview;
    final int done = s?.count ?? 0;
    final int total = done + remaining;
    final double ratio = total == 0 ? (allDone ? 1 : 0) : done / total;
    final Duration swap = fushiMotionDuration(context, FushiMotion.short);

    final Widget figure;
    if (d == null) {
      figure = const FushiSkeletonShimmer(
        key: ValueKey<String>('home-srs-panel-skeleton'),
        child: FushiSkeleton(width: 140, height: 56),
      );
    } else if (allDone) {
      figure = Text(
        t.home_srs_panel_done,
        key: const ValueKey<String>('home-srs-panel-done'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: FushiPosterText.headline.on(base).copyWith(color: colors.accent),
      );
    } else {
      final String counted = t.srs_home_deck_cards(n: remaining);
      figure = Semantics(
        key: const ValueKey<String>('home-srs-panel-remaining'),
        label: counted,
        excludeSemantics: true,
        child: FushiPosterFigure(
          value: '$remaining',
          unit: homePosterUnitOf(counted, '$remaining'),
          colors: colors,
          size: FushiPosterFigureSize.compact,
        ),
      );
    }

    final Widget? start = go == null || allDone
        ? null
        : FushiPressScale(
            child: FushiFilledButton.icon(
              key: const ValueKey<String>('home-srs-panel-start'),
              size: FushiButtonSize.m,
              // 按钮色取块自己的配色（与「继续」主块同口径），不用主题紫。
              style: fushiPosterButtonStyle(colors),
              onPressed: () => onStartReview(go),
              icon: const FushiIcon(FushiIcons.play),
              label: Text(
                t.home_srs_panel_start,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );

    final Widget poster = FushiPosterBlock(
      watermark: t.nav_srs,
      colors: colors,
      watermarkFontSize: 110,
      watermarkEdge: FushiPosterWatermarkEdge.bottom,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FushiPosterChip(
                    colors: colors,
                    icon: FushiIcons.repeat,
                    label: t.nav_srs,
                  ),
                ),
              ),
              if (d != null)
                Semantics(
                  label: t.srs_home_done_count(n: done),
                  child: FushiPosterRing(
                    value: ratio,
                    colors: colors,
                    size: 56,
                  ),
                ),
            ],
          ),
          AnimatedSwitcher(
            duration: swap,
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: AlignmentDirectional.centerStart,
              children: <Widget>[...previous, ?current],
            ),
            child: figure,
          ),
          if (d != null && !allDone)
            Wrap(
              key: const ValueKey<String>('home-srs-panel-counts'),
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                FushiPosterChip(
                  colors: colors,
                  solid: true,
                  label: d.rwkvPending && d.todayReview == 0
                      ? '${t.srs_home_meta_due(n: 0)} '
                            '(${t.srs_home_meta_pending})'
                      : t.srs_home_meta_due(n: d.todayReview),
                ),
                FushiPosterChip(
                  colors: colors,
                  label: t.srs_home_meta_learning(n: d.todayLearn),
                ),
                FushiPosterChip(
                  colors: colors,
                  label: t.srs_home_meta_new(n: d.todayNew),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 12,
            children: <Widget>[
              Expanded(
                child: AnimatedSwitcher(
                  duration: swap,
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  layoutBuilder: (Widget? current, List<Widget> previous) =>
                      Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: <Widget>[...previous, ?current],
                      ),
                  child: s == null
                      ? const FushiSkeletonShimmer(
                          key: ValueKey<String>('home-srs-today-skeleton'),
                          child: FushiSkeleton(width: 140, height: 12),
                        )
                      : Text(
                          homeSrsTodayLine(s),
                          key: const ValueKey<String>('home-srs-panel-today'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: caption,
                        ),
                ),
              ),
              ?start,
            ],
          ),
        ],
      ),
    );

    return KeyedSubtree(
      key: const ValueKey<String>('home-srs-panel'),
      child: shelfCoverCard(
        key: const ValueKey<String>('home-srs-panel-open'),
        shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
        onTap: onOpenDecks,
        child: poster,
      ),
    );
  }
}

/// 计数位的骨架：三格数字 + 按钮的轮廓。
class _HomeSrsCountsSkeleton extends StatelessWidget {
  const _HomeSrsCountsSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiSkeletonShimmer(
      child: Row(
        key: const ValueKey<String>('home-srs-panel-skeleton'),
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.spacing.gap,
        // 面板在窄列里（首页 dashboard 双列 / 手机竖屏）计数位可能不足 180 宽：
        // 骨架按可用宽度收窄，不溢出。
        children: const <Widget>[
          Flexible(child: FushiSkeleton(width: 84, height: 16)),
          Flexible(child: FushiSkeleton(width: 88, height: 36)),
        ],
      ),
    );
  }
}
