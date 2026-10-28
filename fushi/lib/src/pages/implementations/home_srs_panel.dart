/// 首页「复习」入口条（[HomeDashboardPanel.srsReview]）。
///
/// 一行高：前导图标 + 「复习」+ 今日新卡 / 学习中 / 到期三色计数 + 「开始复习」主按钮；
/// 点条目本身进牌组列表（复习 tab）。今天没有待复习的卡时计数与按钮换成一句
/// 「今日已完成」。计数直接读牌组列表同一个 provider（[srsDeckListProvider]）的顶层
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
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiSkeleton, FushiSkeletonShimmer;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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
  });

  /// 点条目本身：进牌组列表。
  final VoidCallback onOpenDecks;

  /// 点「开始复习」：直接复习这个牌组（[SrsDeckListData.firstRootWithWork]）。
  final void Function(SrsDeckSummary deck) onStartReview;

  /// 内容行的固定高度：骨架 / 计数 / 已完成三态同高，切换时不跳布局。
  static const double rowHeight = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsDeckListData? data = ref
        .watch(homeSrsDeckListProvider)
        .valueOrNull;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = apple
        ? FushiAppleMetrics.of(context).groupBorderRadius
        : FushiBorderRadius.card;
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.group;
    final SrsDeckSummary? target = data?.firstRootWithWork;

    final Widget status;
    if (data == null) {
      status = const _HomeSrsCountsSkeleton(key: ValueKey<String>('loading'));
    } else if (!data.hasWorkToday) {
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
              child: SizedBox(
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
                              (Widget? current, List<Widget> previous) => Stack(
                                alignment: AlignmentDirectional.centerEnd,
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
            ),
          ),
        ),
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
