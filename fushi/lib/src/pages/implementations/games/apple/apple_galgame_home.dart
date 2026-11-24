/// 游戏首页的 Apple（Cupertino，iOS 27 / macOS 27）版面（设计稿
/// `build/games_cupertino_design/index.html` 方案 A「货架式」，用户 2026-11-24
/// 拍板）。Apple 档只有这一种版面，不跟随「拼贴 / 封面网格」库页偏好（拍板点 2，
/// 该偏好仍对 M3E 生效）。
///
/// 自上而下一条主线：副行（总数 · 累计）→「继续游戏」取色大卡 →「最近玩过 ›」
/// 货架（至多 12，段头 › 进按最近游玩排序的库）→「本周」柱图卡 →「游玩状态」
/// 分段条 + 分组列表 →「今天玩这个？」（段头「换一个」）→「动态」分段控件 + 按日
/// 分组、日期头钉住的完整列表。宽窗（≥ 840，与复习首页 Apple 版同一断点）：首卡
/// 与「本周 / 游玩状态」并排，货架通栏，「今天玩这个？」与「动态」左右两栏（2:3）。
///
/// 只画 [GalgameHomeViewData]、只调 [GalgameHomeActions]：业务全部在
/// `_GalgameHomePageState`，与 M3E 版面同一份。整页 [FushiEntranceScope] 错峰进场
/// （首卡先到），货架项 / 时间线行逐项错峰，「换一个」交叉淡入，时长只取
/// [fushiMotionDuration]。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi_core/fushi_core.dart' show kActivityAdded, kActivityGame;
import 'package:fushi/src/pages/implementations/games/apple/apple_galgame_home_widgets.dart';
import 'package:fushi/src/pages/implementations/games/galgame_detail_route.dart'
    show galgameCoverHeroTag;
import 'package:fushi/src/pages/implementations/games/galgame_home_model.dart';
import 'package:fushi/src/pages/implementations/games/galgame_library_view_request.dart';
import 'package:fushi/src/stats/stat_format.dart' show formatStatTime;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/apple/apple_capsule_button.dart';
import 'package:fushi/src/utils/components/apple/apple_section_header.dart';
import 'package:fushi/src/utils/components/apple/apple_shelf.dart';
import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromePinnedOffset;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/shelf_cover_material.dart'
    show kShelfGameCaseAspectRatio;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 宽窗两栏的断点（与复习首页 Apple 版同一个值）。
const double kAppleGalgameHomeWideMin = 840;

/// 宽窗内容区的最大宽（macOS 档；超出部分两侧均分留白、内容居中）。
const double kAppleGalgameHomeMaxWidth = 1180;

/// 游戏首页 Apple 版面（有游戏时；空库态 / 首载骨架由 State 分派）。
class AppleGalgameHome extends StatelessWidget {
  const AppleGalgameHome({
    required this.data,
    required this.actions,
    super.key,
  });

  /// 各段的 key（测试按它们核对顺序与存在）。
  static const Key summaryKey = ValueKey<String>('apple-galgame-home-summary');
  static const Key heroKey = ValueKey<String>('apple-galgame-home-hero');
  static const Key recentKey = ValueKey<String>('apple-galgame-home-recent');
  static const Key recentOpenKey = ValueKey<String>(
    'apple-galgame-home-recent-open',
  );
  static const Key weekKey = ValueKey<String>('apple-galgame-home-week');
  static const Key statusKey = ValueKey<String>('apple-galgame-home-status');
  static const Key randomKey = ValueKey<String>('apple-galgame-home-random');
  static const Key rerollKey = ValueKey<String>('apple-galgame-home-reroll');
  static const Key activityKey = ValueKey<String>(
    'apple-galgame-home-activity',
  );

  final GalgameHomeViewData data;
  final GalgameHomeActions actions;

  static const String _filterAll = 'all';

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double basePage = tokens.spacing.page;
    // 浮动工具区的让位（游戏外壳经 MediaQuery 顶部 padding 交来）由首段内边距
    // 吃掉，吃掉后从子树摘掉，免得卡片里的列表 / SafeArea 再让一遍。
    final double chromeTop = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool wide = box.maxWidth >= kAppleGalgameHomeWideMin;
        // 宽窗内容限宽居中：超过 [kAppleGalgameHomeMaxWidth] 的部分平分到两侧，
        // 不让两栏被拉成两条细长带、也不在一侧留大片空白。
        final double page = math.max(
          basePage,
          (box.maxWidth - kAppleGalgameHomeMaxWidth) / 2,
        );
        final double gap = m.groupSpacing;
        int stagger = 0;
        Widget enter(Widget child) =>
            FushiStaggeredEntrance(index: stagger++, child: child);
        Widget padded(Widget child) => Padding(
          padding: EdgeInsets.symmetric(horizontal: page),
          child: child,
        );

        final Widget summary = enter(_summary(context));
        final GalgameEntry? hero = data.hero;
        final Widget? heroCard = hero == null
            ? null
            : enter(KeyedSubtree(key: heroKey, child: _hero(hero)));
        final Widget week = enter(
          KeyedSubtree(
            key: weekKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppleSectionHeader(
                  title: t.game_kpi_week,
                  horizontalPadding: 0,
                ),
                AppleGalgameWeekCard(
                  weekSeconds: data.weekSeconds,
                  todaySeconds: data.todaySeconds,
                  days: data.weekDays,
                ),
              ],
            ),
          ),
        );
        final Widget status = enter(
          KeyedSubtree(
            key: statusKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppleSectionHeader(
                  title: t.game_play_status,
                  horizontalPadding: 0,
                ),
                AppleGalgameStatusCard(
                  counts: data.statusCounts,
                  onStatus: (GalgamePlayStatus s) => actions.openLibraryWith(
                    GalgameLibraryViewRequest.status(s),
                  ),
                ),
              ],
            ),
          ),
        );
        final Widget? recent = data.recent.isEmpty
            ? null
            : enter(
                KeyedSubtree(key: recentKey, child: _recent(context, page)),
              );
        final GalgameEntry? randomGame = data.random;
        final Widget? random = randomGame == null
            ? null
            : enter(
                KeyedSubtree(
                  key: randomKey,
                  child: _random(context, randomGame),
                ),
              );
        final int activityBase = stagger + 1;
        final Widget activityHead = enter(
          KeyedSubtree(key: activityKey, child: _activityHeader(context)),
        );

        final List<Widget> slivers = <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              page,
              tokens.spacing.rowVertical + chromeTop,
              page,
              0,
            ),
            sliver: SliverToBoxAdapter(child: summary),
          ),
          if (wide) ...<Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(page, 12 * m.scale, page, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(flex: 3, child: heroCard ?? const SizedBox()),
                    SizedBox(width: gap),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[week, status],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (recent != null) SliverToBoxAdapter(child: recent),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: page),
              sliver: SliverCrossAxisGroup(
                slivers: <Widget>[
                  SliverCrossAxisExpanded(
                    flex: 2,
                    sliver: SliverPadding(
                      padding: EdgeInsetsDirectional.only(end: gap),
                      sliver: SliverToBoxAdapter(
                        child: random ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  SliverCrossAxisExpanded(
                    flex: 3,
                    sliver: SliverMainAxisGroup(
                      slivers: <Widget>[
                        SliverToBoxAdapter(child: activityHead),
                        ..._activityDays(context, activityBase),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else ...<Widget>[
            if (heroCard != null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 12 * m.scale, page, 0),
                sliver: SliverToBoxAdapter(child: heroCard),
              ),
            if (recent != null) SliverToBoxAdapter(child: recent),
            SliverToBoxAdapter(child: padded(week)),
            SliverToBoxAdapter(child: padded(status)),
            if (random != null) SliverToBoxAdapter(child: padded(random)),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: page),
              sliver: SliverMainAxisGroup(
                slivers: <Widget>[
                  SliverToBoxAdapter(child: activityHead),
                  ..._activityDays(context, activityBase),
                ],
              ),
            ),
          ],
          SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.section)),
        ];
        return FushiEntranceScope(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: CustomScrollView(slivers: slivers),
          ),
        );
      },
    );
  }

  /// 大标题下的副行（Apple subheadline / secondaryLabel）：总数 · 累计。
  Widget _summary(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    return Text(
      t.game_home_summary(
        count: data.totalGames,
        time: formatStatTime(data.totalSeconds * 1000),
      ),
      key: summaryKey,
      style: appleTextStyle(
        context,
        size: (m.desktop ? 13 : 15) * m.scale,
        color: appleColorsOf(context).secondaryLabel,
      ),
    );
  }

  Widget _hero(GalgameEntry game) {
    final String tag = galgameCoverHeroTag(game.id);
    return AppleGalgameHeroCard(
      key: ValueKey<String>('games_home_hero_${game.id}'),
      game: game,
      running: data.heroRunning,
      lastPlayedLabel: game.lastPlayedMs > 0
          ? '${t.game_stat_last_played} '
                '${galgameHomeRelativeTime(game.lastPlayedMs, DateTime.now())}'
          : null,
      onLaunch: () => actions.launch(game),
      onDetail: () => actions.openDetail(game, coverHeroTag: tag),
      onMenu: () => actions.showMenu(game, coverHeroTag: tag),
      onWorkbench: data.sessionActive ? actions.openWorkbench : null,
    );
  }

  /// 「最近玩过 ›」：段头 › 进按最近游玩排序的库；货架横滑（iOS 按条吸附、macOS
  /// 悬停两端箭头），逐项错峰。
  Widget _recent(BuildContext context, double page) {
    final double w = AppleGalgameShelfTile.widthFor(context);
    final double h = AppleGalgameShelfTile.heightFor(context, w);
    final DateTime now = DateTime.now();
    final List<GalgameEntry> games = data.recent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppleSectionHeader(
          title: t.game_recently_played,
          horizontalPadding: page,
          openKey: recentOpenKey,
          onOpen: () => actions.openLibraryWith(
            const GalgameLibraryViewRequest.recentlyPlayed(),
          ),
        ),
        AppleShelf(
          itemCount: games.length,
          itemExtent: w,
          // 悬停抬 2px 与投影留在货架高度里，不被下一段压住。
          height: h + 8,
          arrowCenter: w / kShelfGameCaseAspectRatio / 2,
          arrowKeyPrefix: 'apple-galgame-shelf',
          horizontalPadding: page,
          itemBuilder: (BuildContext context, int i) {
            final GalgameEntry g = games[i];
            return FushiStaggeredEntrance(
              index: i,
              child: Align(
                alignment: Alignment.topCenter,
                child: AppleGalgameShelfTile(
                  key: ValueKey<String>('games_home_continue_${g.id}'),
                  game: g,
                  width: w,
                  subtitle: g.lastPlayedMs > 0
                      ? galgameHomeRelativeTime(g.lastPlayedMs, now)
                      : null,
                  onLaunch: () => actions.launch(g),
                  onMenu: () => actions.showMenu(
                    g,
                    coverHeroTag: galgameCoverHeroTag(g.id),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// 「今天玩这个？」：段头带「换一个」，换的时候交叉淡入。
  Widget _random(BuildContext context, GalgameEntry game) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppleSectionHeader(
          title: t.game_home_random_eyebrow,
          horizontalPadding: 0,
          trailing: AppleCapsuleButton(
            key: rerollKey,
            icon: FushiIcons.refresh,
            label: t.game_random_reroll,
            onTap: actions.reroll,
          ),
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          reverseDuration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.standard,
          switchOutCurve: FushiMotion.standard,
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previous, ?current],
          ),
          child: AppleGalgameRandomCard(
            key: ValueKey<String>('games_home_random_${game.id}'),
            game: game,
            onLaunch: () => actions.launch(game),
            onDetail: () => actions.openDetail(game),
          ),
        ),
      ],
    );
  }

  /// 「动态」段头 + 分段控件（全部 / 游戏 / 新增）。
  Widget _activityHeader(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppleSectionHeader(title: t.home_activity, horizontalPadding: 0),
        adaptiveSegmentedButton<String>(
          context: context,
          segments: <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: _filterAll,
              label: Text(t.home_filter_all),
            ),
            ButtonSegment<String>(
              value: kActivityGame,
              label: Text(t.home_filter_game),
            ),
            ButtonSegment<String>(
              value: kActivityAdded,
              label: Text(t.home_filter_added),
            ),
          ],
          selected: <String>{data.timelineFilter ?? _filterAll},
          onSelectionChanged: (Set<String> next) {
            final String v = next.first;
            actions.setTimelineFilter(v == _filterAll ? null : v);
          },
        ),
        SizedBox(height: 4 * k),
      ],
    );
  }

  /// 按日分组的完整时间线：每天一个 [SliverMainAxisGroup]（日期头只在本组可见时
  /// 钉住，钉在浮动工具区的可见下沿）+ 当天的 inset grouped 行。
  List<Widget> _activityDays(BuildContext context, int staggerBase) {
    if (data.timeline.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.history,
            message: t.home_activity_empty,
          ),
        ),
      ];
    }
    return <Widget>[
      for (final GalgameHomeTimelineDay day in data.timeline)
        SliverMainAxisGroup(
          key: ValueKey<String>('game-timeline-${day.dateKey}'),
          slivers: <Widget>[
            PinnedHeaderSliver(
              child: FushiFloatingChromePinnedOffset(
                child: AppleGalgameDateHeader(label: day.label),
              ),
            ),
            SliverList.builder(
              itemCount: day.entries.length,
              itemBuilder: (BuildContext context, int i) {
                final GalgameHomeTimelineEntry e = day.entries[i];
                final GalgameEntry? game = e.game;
                return FushiStaggeredEntrance(
                  index: staggerBase + i,
                  child: AppleGalgameTimelineRow(
                    entry: e,
                    index: i,
                    count: day.entries.length,
                    onOpen: game == null
                        ? null
                        : () => actions.openDetail(game),
                  ),
                );
              },
            ),
          ],
        ),
    ];
  }
}
