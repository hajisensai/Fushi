/// 首页「复习」小组件（[HomeWidgetKind.srsReview]）。
///
/// 今天还剩的张数大字（2×1 再挂新卡 / 学习中 / 到期三色计数与「开始复习」）；点块本身
/// 进牌组列表（复习 tab）。今天没有待复习的卡时换成一行「今日已完成」。宽网格的 2×1
/// 再挂今天已做的复习（张数 · 用时 · 正确率，[srsTodayReviewSummaryProvider]，与复习
/// 统计页「今天」同口径；4mY-bG0T96）。计数直接读牌组列表同一个 provider
/// （[srsDeckListProvider]）的顶层行之和，口径与牌组列表逐字相同，不另算一套；写操作 /
/// 制卡 / 同步都经 [srsRevisionProvider] 让它重读。
///
/// 计数异步加载：数据回来前挂骨架；格子尺寸由网格决定，首页首帧不等数据库、也不跳布局。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';

import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiSkeleton, FushiSkeletonShimmer;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonMetrics, FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';

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

///
/// 两行（设计稿 11-20 #12：一行装不下时末尾的「正确率」被省略号吃掉）：第一行
/// 「今日已复习 N 张 · N 分钟」，有复习时第二行「正确率 N%」。
String homeSrsTodayLine(SrsTodayReviewSummary s) {
  final String time = s.durationMs < 60000
      ? t.srs_stats_seconds(n: (s.durationMs / 1000).round())
      : formatStatTime(s.durationMs);
  final double? rate = s.correctRate;
  return <String>[
    t.home_srs_panel_today(count: s.count, time: time),
    if (rate != null) '${t.srs_stats_today_correct} ${(rate * 100).round()}%',
  ].join('\n');
}

/// 旧首页可选面板「自动」档的判据（纯函数）：挖词目标 = Fushi 复习，或库里已有复习卡。
/// 卡数还在加载（null）时按否。
///
/// 只用于迁移：用户从没编辑过首页布局时，按它决定默认模板里放不放「复习」
/// （[migrateHomeWidgetLayout]）；组件放上首页后常驻，不再按它整块消失。
bool homeSrsAutoDefault({
  required bool miningToReview,
  required int? totalCards,
}) => miningToReview || (totalCards != null && totalCards > 0);

/// [homeSrsAutoDefault] 的 Riverpod 装配。复习模块关着时为 false（不建任何 SRS 状态）；
/// 挖词目标是复习时不读卡数。只在首页布局要现算迁移时订阅。
final Provider<bool> homeSrsAutoDefaultProvider = Provider<bool>((Ref ref) {
  if (!ref.watch(srsModuleEnabledProvider)) return false;
  final bool miningToReview = ref.watch(srsMiningToReviewProvider);
  if (miningToReview) return true;
  return homeSrsAutoDefault(
    miningToReview: false,
    totalCards: ref.watch(
      homeSrsDeckListProvider.select(
        (AsyncValue<SrsDeckListData?> d) => d.valueOrNull?.totalCards,
      ),
    ),
  );
});

/// 首页「复习」小组件（[HomeWidgetKind.srsReview]，1×1 · 2×1）。可不可用由首页按
/// 复习模块开关决定；本 widget 只管画。
///
/// 按格子的实际宽高排版（[homeWidgetIsWide] / [homeWidgetIsDense]）：
/// - 窄格：今天还剩的张数大字；高度够时再挂「开始复习」。
/// - 宽格：大字 + 新卡 / 学习中 / 到期三色计数 + 「开始复习」，不矮时再挂今日
///   已复习一行（张数 · 用时 · 正确率）。
///
/// 今天没有待复习的卡时收成一行「今日已完成」；计数加载中挂骨架。点块本身进牌组
/// 列表（复习 tab）。
class HomeSrsPanel extends ConsumerWidget {
  const HomeSrsPanel({
    super.key,
    required this.onOpenDecks,
    required this.onStartReview,
    this.poster = false,
  });

  /// 点块本身：进牌组列表。
  final VoidCallback onOpenDecks;

  /// 点「开始复习」：直接复习这个牌组（[SrsDeckListData.firstRootWithWork]）。
  final void Function(SrsDeckSummary deck) onStartReview;

  /// true = 海报色块外观。
  final bool poster;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SrsDeckListData? data = ref
        .watch(homeSrsDeckListProvider)
        .valueOrNull;
    final SrsDeckSummary? target = data?.firstRootWithWork;
    final SrsTodayReviewSummary? today = ref
        .watch(homeSrsTodayReviewsProvider)
        .valueOrNull;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-srs-panel'),
          tapKey: const ValueKey<String>('home-srs-panel-open'),
          title: t.nav_srs,
          icon: FushiIcons.repeat,
          hueKey: HomeWidgetKind.srsReview.id,
          poster: poster,
          dense: dense,
          onTap: onOpenDecks,
          child: _HomeSrsBody(
            data: data,
            target: target,
            today: today,
            wide: homeWidgetIsWide(c.maxWidth),
            dense: dense,
            onStartReview: onStartReview,
          ),
        );
      },
    );
  }
}

class _HomeSrsBody extends StatelessWidget {
  const _HomeSrsBody({
    required this.data,
    required this.target,
    required this.today,
    required this.wide,
    required this.dense,
    required this.onStartReview,
  });

  final SrsDeckListData? data;
  final SrsDeckSummary? target;
  final SrsTodayReviewSummary? today;

  /// 宽格（有横向余量放计数与按钮）。
  final bool wide;
  final bool dense;
  final void Function(SrsDeckSummary deck) onStartReview;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final TextStyle caption = context.fushiType.bodySmall.copyWith(
      color: style.muted,
    );
    final SrsDeckListData? d = data;
    final Duration swap = fushiMotionDuration(context, FushiMotion.short);

    final Widget content;
    if (d == null) {
      content = const FushiSkeletonShimmer(
        key: ValueKey<String>('home-srs-panel-skeleton'),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FushiSkeleton(width: 84, height: 24),
        ),
      );
    } else if (!d.hasWorkToday && !d.rwkvPending) {
      content = Row(
        key: const ValueKey<String>('done'),
        spacing: 6,
        children: <Widget>[
          FushiIcon(FushiIcons.check, size: 18, color: style.accent),
          Expanded(
            child: Text(
              t.home_srs_panel_done,
              key: const ValueKey<String>('home-srs-panel-done'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: style.foreground,
              ),
            ),
          ),
        ],
      );
    } else {
      final int remaining = d.todayNew + d.todayLearn + d.todayReview;
      final String counted = t.srs_home_deck_cards(n: remaining);
      final Widget figure = Semantics(
        key: const ValueKey<String>('home-srs-panel-remaining'),
        label: counted,
        excludeSemantics: true,
        child: HomeWidgetFigure(
          value: '$remaining',
          unit: homePosterUnitOf(counted, '$remaining'),
        ),
      );
      final SrsDeckSummary? go = target;
      final Widget? start = go == null || dense
          ? null
          : FushiPressScale(
              child: FushiFilledButton.tonal(
                key: const ValueKey<String>('home-srs-panel-start'),
                size: FushiButtonSize.xs,
                onPressed: () => onStartReview(go),
                child: Text(
                  t.home_srs_panel_start,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
      if (!wide) {
        // 「格子不矮时再挂开始复习」按真实可用高度判：宽网格最矮档（行高夹到 104）
        // 的 1×1 放不下大字 + 按钮，只放大字（大字至少留一个按钮高）。
        final double buttonHeight = FushiButtonMetrics.of(
          FushiButtonSize.xs,
        ).height;
        content = LayoutBuilder(
          key: const ValueKey<String>('counts'),
          builder: (BuildContext context, BoxConstraints c) {
            final bool fits = c.maxHeight >= buttonHeight * 2;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Flexible(child: figure),
                if (fits) ?start,
              ],
            );
          },
        );
      } else {
        // 新 / 学习中 / 到期三个计数与大字同一行（设计稿 11-20 #12），省出的一行给
        // 下面两行的「今日已复习 · 正确率」。放不下时整组等比缩小，不出省略号。
        content = Row(
          key: const ValueKey<String>('counts'),
          spacing: 10,
          children: <Widget>[
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: <Widget>[
                    figure,
                    SrsCountTriple(
                      key: const ValueKey<String>('home-srs-panel-counts'),
                      newCount: d.todayNew,
                      learnCount: d.todayLearn,
                      reviewCount: d.todayReview,
                      reviewPending: d.rwkvPending,
                      dense: true,
                    ),
                  ],
                ),
              ),
            ),
            ?start,
          ],
        );
      }
    }
    final SrsTodayReviewSummary? s = today;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AnimatedSwitcher(
            duration: swap,
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: AlignmentDirectional.centerStart,
              children: <Widget>[...previous, ?current],
            ),
            child: content,
          ),
        ),
        if (wide && !dense)
          SizedBox(
            // 固定两行高：骨架与加载完、有没有正确率都同一高度，不跳布局。
            height: MediaQuery.textScalerOf(
              context,
            ).scale((caption.fontSize ?? 12) * (caption.height ?? 1.34) * 2),
            child: s == null
                ? const FushiSkeletonShimmer(
                    key: ValueKey<String>('home-srs-today-skeleton'),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FushiSkeleton(width: 140, height: 10),
                    ),
                  )
                : Align(
                    alignment: AlignmentDirectional.bottomStart,
                    child: Text(
                      homeSrsTodayLine(s),
                      key: const ValueKey<String>('home-srs-panel-today'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                  ),
          ),
      ],
    );
  }
}
