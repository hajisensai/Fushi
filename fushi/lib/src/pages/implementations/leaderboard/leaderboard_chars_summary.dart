// 排行榜页顶部的「总字数」卡：一个大数字 + 三句话（本周增量与占比、离下一个
// 百万还差多少、够读完几卷某部热门作品），外加一条到下一个百万的进度条。
// 数字来自服务端字数榜的「我」（总榜 = 总字数，周榜 = 本周），不在本地另算。
// 参照作品每次打开页面轮换（随包 jiten 数据，不联网）。

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import 'package:fushi/src/leaderboard/leaderboard_reference_works.dart';
import 'package:fushi/src/leaderboard/leaderboard_reference_works_data.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/utils.dart';

/// 换算量：一位小数，整数时不带 `.0`（82.5 / 3）。
String leaderboardEquivalentAmount(double amount) =>
    NumberFormat('#,##0.#', Intl.getCurrentLocale()).format(amount);

/// 「够读完 N 卷《作品》」那句。
String leaderboardEquivalentText(LeaderboardReferenceEquivalent e) {
  final String n = leaderboardEquivalentAmount(e.amount);
  final String title = e.work.title;
  final LeaderboardReferenceWork work = e.work;
  switch (work.kind) {
    case LeaderboardReferenceKind.novel:
    case LeaderboardReferenceKind.manga:
      return work.countsParts
          ? t.leaderboard_summary_equiv_volumes(n: n, title: title)
          : t.leaderboard_summary_equiv_read_times(n: n, title: title);
    case LeaderboardReferenceKind.anime:
      return work.countsParts
          ? t.leaderboard_summary_equiv_episodes(n: n, title: title)
          : t.leaderboard_summary_equiv_watch_times(n: n, title: title);
    case LeaderboardReferenceKind.visualNovel:
      return t.leaderboard_summary_equiv_play_times(n: n, title: title);
  }
}

/// 总字数卡。[total] / [week] 为 null = 还在加载；[error] 非 null 且 [total] 为 null =
/// 加载失败（显示原因，不再停在加载条上）。
class LeaderboardCharsSummaryCard extends StatefulWidget {
  const LeaderboardCharsSummaryCard({
    required this.total,
    required this.week,
    this.error,
    this.works = kLeaderboardReferenceWorks,
    this.random,
    super.key,
  });

  final int? total;
  final int? week;
  final Object? error;
  final List<LeaderboardReferenceWork> works;

  /// 轮换用的随机源（测试注入固定种子）；null = 每次打开随机。
  final math.Random? random;

  @override
  State<LeaderboardCharsSummaryCard> createState() =>
      _LeaderboardCharsSummaryCardState();
}

class _LeaderboardCharsSummaryCardState
    extends State<LeaderboardCharsSummaryCard> {
  /// 每次打开页面（State 新建）定一个随机种子：同一次打开里数字刷新也不换作品。
  late final int _seed = (widget.random ?? math.Random()).nextInt(1 << 31);

  LeaderboardReferenceEquivalent? _equivalent(int total) =>
      pickLeaderboardReference(total, widget.works, math.Random(_seed));

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final int? total = widget.total;
    final int week = widget.week ?? 0;
    final Duration countUp = fushiMotionDuration(context, FushiMotion.long * 2);

    final List<Widget> lines = <Widget>[];
    if (total != null && total > 0) {
      final int next = leaderboardNextMillion(total);
      final double progress = (total % 1000000) / 1000000;
      final double share = week <= 0 ? 0 : math.min(week / total, 1);
      final LeaderboardReferenceEquivalent? equivalent = _equivalent(total);
      lines.addAll(<Widget>[
        if (week > 0)
          Text(
            t.leaderboard_summary_week(
              n: leaderboardGroupedNumber(week),
              pct: NumberFormat.decimalPercentPattern(
                locale: Intl.getCurrentLocale(),
                decimalDigits: 1,
              ).format(share),
            ),
            key: const ValueKey<String>('leaderboard-summary-week'),
            style: tokens.type.listTitle,
          ),
        SizedBox(height: tokens.spacing.gap),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: progress),
          duration: countUp,
          curve: FushiMotion.standard,
          builder: (BuildContext context, double value, Widget? _) =>
              FushiLinearProgressIndicator(
                value: value.clamp(0, 1),
                minHeight: 8,
                borderRadius: const BorderRadius.all(Radius.circular(4)),
              ),
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        Text(
          t.leaderboard_summary_next(n: leaderboardGroupedNumber(next - total)),
          key: const ValueKey<String>('leaderboard-summary-next'),
          style: tokens.type.listSubtitle,
        ),
        if (equivalent != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Text(
            leaderboardEquivalentText(equivalent),
            key: const ValueKey<String>('leaderboard-summary-equivalent'),
            style: tokens.type.listTitle.copyWith(color: colors.primary),
          ),
        ],
      ]);
    }

    return FushiCard(
      key: const ValueKey<String>('leaderboard-summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.leaderboard_summary_total,
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (total == null && widget.error != null)
            Text(
              leaderboardErrorText(widget.error!),
              key: const ValueKey<String>('leaderboard-summary-error'),
              style: tokens.type.listSubtitle,
            )
          else if (total == null)
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap),
              child: const SizedBox(
                height: 4,
                child: FushiLinearProgressIndicator(),
              ),
            )
          else if (total <= 0)
            Text(
              t.leaderboard_summary_empty,
              key: const ValueKey<String>('leaderboard-summary-empty'),
              style: tokens.type.listTitle,
            )
          else
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: total.toDouble()),
              duration: countUp,
              curve: FushiMotion.standard,
              builder: (BuildContext context, double value, Widget? _) => Text(
                leaderboardGroupedNumber(value.round()),
                key: const ValueKey<String>('leaderboard-summary-total'),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ...lines,
        ],
      ),
    );
  }
}
