/// 游戏首页 Apple（Cupertino，iOS 27 / macOS 27）版面的部件（设计稿
/// `build/games_cupertino_design/index.html` 方案 A「货架式」，用户 2026-11-24
/// 拍板）：取色渐变「继续游戏」大卡、货架平封面、「本周」柱图卡、游玩状态分段条 +
/// 分组列表、「今天玩这个？」卡、时间线行与吸顶日期头、首载骨架。
///
/// 只被 [AppleGalgameHome] 使用（`isGlassDesign` 为真）；M3E 首页不经过这里。
/// 尺寸取 [FushiAppleMetrics]（macOS 档乘 `fushiAppleMacScale`），颜色取
/// [appleColorsOf] 的系统色；圆角只取共享令牌：卡片 [fushiCardBorderRadius]、分组
/// 容器 [FushiAppleMetrics.groupBorderRadius]（都是连续曲率），封面走卡盒材质自己的
/// 外形（[ShelfCoverShape.of]）。封面一律平放，
/// 悬停只抬 2px 并加深投影（拍板点 4），按压缩放走 [FushiHoverLift] 内层的
/// [FushiPressScale]，时长只取 [fushiMotionDuration]。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/games/galgame_detail_route.dart'
    show galgameCoverHeroTag;
import 'package:fushi/src/pages/implementations/games/galgame_home_cover_art.dart';
import 'package:fushi/src/pages/implementations/games/galgame_home_model.dart';
import 'package:fushi/src/pages/implementations/games/galgame_play_status_style.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:fushi/src/stats/stat_format.dart' show formatStatTime;
import 'package:fushi/src/utils/components/apple/apple_bar_chart.dart';
import 'package:fushi/src/utils/components/apple/apple_capsule_button.dart';
import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiSkeleton, FushiSkeletonShimmer;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics, FushiGroupedListItem;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;
import 'package:fushi/src/utils/components/shelf_cover_material.dart'
    show ShelfCoverMaterial, ShelfCoverShape, kShelfGameCaseAspectRatio;
import 'package:fushi/src/utils/cover_image.dart'
    show kActivityCoverDecodePixelWidth;
import 'package:fushi/src/utils/fushi_icons.dart';

// ── 公共小件 ────────────────────────────────────────────────────────────────

/// 悬停抬 2px（拍板点 4：平封面不放大、不斜放）：外层 [FushiHoverLift]（倍数 1，
/// 只取它的 hover 态与内层按压缩放），位移按 [FushiMotion.short] 过渡。
class AppleGalgameLift extends StatelessWidget {
  const AppleGalgameLift({required this.builder, super.key});

  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: 1,
    builder: (BuildContext context, bool hovering) => AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      transform: Matrix4.translationValues(0, hovering ? -2 : 0, 0),
      child: builder(context, hovering),
    ),
  );
}

/// 平放的游戏封面：连续曲率圆角 + 双层柔影（悬停加深），与库页 / 音乐 Apple 档
/// 同一种材质。[heroTag] 非 null 时挂详情封面的共享元素（拍板点 8）。
class AppleGalgameFlatCover extends StatelessWidget {
  const AppleGalgameFlatCover({
    required this.game,
    required this.width,
    this.hovering = false,
    this.heroTag,
    this.decodeWidth = kActivityCoverDecodePixelWidth,
    super.key,
  });

  final GalgameEntry game;
  final double width;
  final bool hovering;
  final String? heroTag;
  final int decodeWidth;

  @override
  Widget build(BuildContext context) {
    final ShelfCoverShape shape = ShelfCoverShape.of(
      context,
      ShelfCoverMaterial.gameCase,
    );
    Widget art = shape.clip(
      child: GalgameCoverArt(game: game, decodeWidth: decodeWidth),
    );
    final String? tag = heroTag;
    if (tag != null) art = Hero(tag: tag, child: art);
    return SizedBox(
      width: width,
      height: width / kShelfGameCaseAspectRatio,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape.border(),
          shadows: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: hovering ? 0.18 : 0.08),
              blurRadius: hovering ? 14 : 4,
              offset: Offset(0, hovering ? 6 : 1),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: hovering ? 0.10 : 0.06),
              blurRadius: hovering ? 28 : 12,
              offset: Offset(0, hovering ? 12 : 4),
            ),
          ],
        ),
        child: art,
      ),
    );
  }
}

/// 卡片底（secondarySystemGroupedBackground + 连续曲率圆角），本周 / 推荐卡共用。
class AppleGalgameCardSurface extends StatelessWidget {
  const AppleGalgameCardSurface({required this.child, this.padding, super.key});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: appleColorsOf(context).secondaryGroupedBackground,
        shape: RoundedSuperellipseBorder(
          borderRadius: fushiCardBorderRadius(context),
        ),
      ),
      child: Padding(padding: padding ?? EdgeInsets.all(16 * k), child: child),
    );
  }
}

/// 卡片的命中 / 焦点外壳：[shelfCoverCard]（点按、长按、右键、焦点、Enter）+
/// 手柄长按 A（[GamepadLongPressActions]）+ 读屏按钮语义。
Widget _appleGalgameCardShell({
  required FushiFocusId focusId,
  required String semanticLabel,
  required BorderRadius radius,
  required VoidCallback onTap,
  required VoidCallback? onLongPress,
  required Widget child,
}) => GamepadLongPressActions(
  onLongPress: onLongPress,
  child: MergeSemantics(
    child: Semantics(
      button: true,
      label: semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: shelfCoverCard(
          focusId: focusId,
          borderRadius: radius,
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: child,
        ),
      ),
    ),
  ),
);

/// 圆形字形钮（取色大卡上的「⋯」）：键盘 / 手柄可聚焦、Enter 激活。
class _AppleRoundGlyphButton extends StatelessWidget {
  const _AppleRoundGlyphButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.background,
    required this.foreground,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    final double d = 30 * k;
    return FushiPressScale(
      child: FushiFocusable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d / 2),
        ringPosition: DecorationPosition.foreground,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Container(
            width: d,
            height: d,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: FushiIcon(icon, size: 16 * k, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 「继续游戏」取色大卡 ──────────────────────────────────────────────────────

/// 「继续游戏」大卡（Apple Music Top Picks 式）：底色是封面取色（复用
/// [GalgameBlockPalette] 的 coverColorSchemeCache，不另写取色器）的纯色渐变，左侧
/// 平封面，右侧眉标（游戏中 / 继续游戏）+ 标题 + 最后游玩 · 累计，底部按钮行
/// 「▶ 继续游戏」（白底黑字）、「查看详情」（半透明）、「⋯」（同一份条目菜单）。
/// 本机有 Hook 会话时卡底多一条「正在捕获 · 捕获工作台 ›」。
///
/// 点卡 = 启动（拍板点 5，与 M3E 一致），长按 / 右键 / 手柄长按 A = 条目菜单。
/// 卡内按钮是卡的兄弟层（不嵌进卡片的焦点节点），键盘左右键在卡与按钮间移动。
class AppleGalgameHeroCard extends StatelessWidget {
  const AppleGalgameHeroCard({
    required this.game,
    required this.running,
    required this.lastPlayedLabel,
    required this.onLaunch,
    required this.onDetail,
    required this.onMenu,
    this.onWorkbench,
    super.key,
  });

  /// 「继续游戏」主按钮 / 「查看详情」/「⋯」/ 会话行的 key（测试与焦点驱动用）。
  static const Key launchKey = ValueKey<String>('apple-galgame-hero-launch');
  static const Key detailKey = ValueKey<String>('apple-galgame-hero-detail');
  static const Key moreKey = ValueKey<String>('apple-galgame-hero-more');
  static const Key sessionKey = ValueKey<String>('apple-galgame-hero-session');

  final GalgameEntry game;
  final bool running;
  final String? lastPlayedLabel;
  final VoidCallback onLaunch;
  final VoidCallback onDetail;
  final VoidCallback onMenu;

  /// 切到捕获工作台；null = 没有 Hook 会话（不画会话行）。
  final VoidCallback? onWorkbench;

  /// 封面取色的渐变两端：取色相，饱和度 / 亮度钉死（白字在两套主题下都可读）；
  /// 还没取到色（或没有色相）时是中性深灰。
  static List<Color> gradientFor(double? hue) {
    if (hue == null) {
      return const <Color>[Color(0xFF48484A), Color(0xFF2C2C2E)];
    }
    return <Color>[
      HSLColor.fromAHSL(1, hue, 0.42, 0.40).toColor(),
      HSLColor.fromAHSL(1, hue, 0.48, 0.24).toColor(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final double pad = 16 * k;
    final double buttonsH = 30 * k;
    final VoidCallback? workbench = onWorkbench;
    final double sessionH = workbench == null ? 0 : 40 * k;
    final BorderRadius radius = fushiCardBorderRadius(context);
    final bool played = game.lastPlayedMs > 0;
    final String primary = played ? t.game_focus_continue : t.game_launch;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // 封面是首卡的主角：iOS 档 116（窄于 360 收到 96），macOS 档 150 × 缩放。
        final double coverW = m.desktop
            ? 150 * k
            : (box.maxWidth < 360 ? 96.0 : 116.0);
        final double coverH = coverW / kShelfGameCaseAspectRatio;
        final double height = pad * 2 + coverH + sessionH;
        return GalgameBlockPalette(
          title: game.displayName,
          image: galgameHomeCoverImage(
            game,
            decodeWidth: kActivityCoverDecodePixelWidth,
          ),
          builder: (BuildContext context, colors) {
            final List<Color> gradient = gradientFor(colors.hue);
            const Color on = Colors.white;
            final Color onSoft = Colors.white.withValues(alpha: 0.74);
            final Widget visual = DecoratedBox(
              decoration: ShapeDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradient,
                ),
                shape: RoundedSuperellipseBorder(borderRadius: radius),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, pad, pad, pad + sessionH),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AppleGalgameFlatCover(
                      game: game,
                      width: coverW,
                      heroTag: galgameCoverHeroTag(game.id),
                    ),
                    SizedBox(width: pad),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (running) ...<Widget>[
                                Container(
                                  width: 7 * k,
                                  height: 7 * k,
                                  decoration: BoxDecoration(
                                    color: appleColorsOf(context).destructive,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                SizedBox(width: 5 * k),
                              ],
                              Flexible(
                                child: Text(
                                  running
                                      ? t.game_home_live_chip
                                      : t.game_focus_continue,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: appleTextStyle(
                                    context,
                                    size: 13 * k,
                                    weight: FontWeight.w600,
                                    color: onSoft,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 4 * k),
                          Text(
                            game.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: appleTextStyle(
                              context,
                              size: (m.desktop ? 20 : 22) * k,
                              weight: FontWeight.w700,
                              color: on,
                              height: 1.18,
                            ),
                          ),
                          SizedBox(height: 4 * k),
                          Text(
                            <String>[
                              ?lastPlayedLabel,
                              '${t.game_stat_total_time} '
                                  '${formatStatTime(game.totalPlaySeconds * 1000)}',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: appleTextStyle(
                              context,
                              size: 13 * k,
                              color: onSoft,
                            ),
                          ),
                          const Spacer(),
                          SizedBox(height: buttonsH),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
            return AppleGalgameLift(
              builder: (BuildContext context, bool hovering) => SizedBox(
                height: height,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          shape: RoundedSuperellipseBorder(
                            borderRadius: radius,
                          ),
                          shadows: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: hovering ? 0.24 : 0.12,
                              ),
                              blurRadius: hovering ? 26 : 16,
                              offset: Offset(0, hovering ? 10 : 6),
                            ),
                          ],
                        ),
                        child: _appleGalgameCardShell(
                          focusId: FushiFocusId(
                            'game-dashboard-hero-${game.id}',
                          ),
                          semanticLabel: '$primary · ${game.displayName}',
                          radius: radius,
                          onTap: onLaunch,
                          onLongPress: onMenu,
                          child: visual,
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: pad + coverW + pad,
                      end: pad,
                      bottom: pad + sessionH,
                      height: buttonsH,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            AppleCapsuleButton(
                              key: launchKey,
                              icon: FushiIcons.play,
                              label: primary,
                              onTap: onLaunch,
                              background: Colors.white,
                              foreground: Colors.black,
                            ),
                            SizedBox(width: 8 * k),
                            AppleCapsuleButton(
                              key: detailKey,
                              icon: null,
                              label: t.game_view_detail,
                              onTap: onDetail,
                              background: Colors.white.withValues(alpha: 0.2),
                              foreground: on,
                            ),
                            SizedBox(width: 8 * k),
                            _AppleRoundGlyphButton(
                              key: moreKey,
                              icon: FushiIcons.moreHoriz,
                              label: t.common_more_actions,
                              onTap: onMenu,
                              background: Colors.white.withValues(alpha: 0.2),
                              foreground: on,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (workbench != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: sessionH,
                        child: FushiFocusable(
                          key: sessionKey,
                          onTap: workbench,
                          borderRadius: BorderRadius.vertical(
                            bottom: radius.bottomLeft,
                          ),
                          ringPosition: DecorationPosition.foreground,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: pad),
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.16),
                                  width: 0.5,
                                ),
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                Container(
                                  width: 7 * k,
                                  height: 7 * k,
                                  decoration: BoxDecoration(
                                    color: appleColorsOf(context).destructive,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                SizedBox(width: 6 * k),
                                Expanded(
                                  child: Text(
                                    t.game_capture_active,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: appleTextStyle(
                                      context,
                                      size: 13 * k,
                                      color: onSoft,
                                    ),
                                  ),
                                ),
                                Text(
                                  t.game_capture_workbench,
                                  style: appleTextStyle(
                                    context,
                                    size: 13 * k,
                                    weight: FontWeight.w600,
                                    color: on,
                                  ),
                                ),
                                FushiIcon(
                                  FushiIcons.chevronRight,
                                  size: 14 * k,
                                  color: onSoft,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ── 「最近玩过」货架 ─────────────────────────────────────────────────────────

/// 货架里的一张游戏：平封面 + 标题 + 最后游玩（相对时间）。点按 = 启动，长按 /
/// 右键 / 手柄长按 A = 条目菜单；焦点站点 `game-recent-<id>`。
class AppleGalgameShelfTile extends StatelessWidget {
  const AppleGalgameShelfTile({
    required this.game,
    required this.width,
    required this.subtitle,
    required this.onLaunch,
    required this.onMenu,
    super.key,
  });

  final GalgameEntry game;
  final double width;
  final String? subtitle;
  final VoidCallback onLaunch;
  final VoidCallback onMenu;

  static const double _titleSize = 13;
  static const double _subtitleSize = 12;
  static const double _titleGap = 7;
  static const double _subtitleGap = 2;

  /// 货架单项宽：iOS 108，macOS 档 120 × 缩放。
  static double widthFor(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    return m.desktop ? 120 * m.scale : 108;
  }

  /// [width] 宽的单项总高（封面 + 标题行 + 副行，按 textScaler 与 macOS 档缩放）。
  static double heightFor(BuildContext context, double width) {
    final double k = FushiAppleMetrics.of(context).scale;
    return width / kShelfGameCaseAspectRatio +
        _titleGap * k +
        appleLineExtent(context, _titleSize * k) +
        _subtitleGap * k +
        appleLineExtent(context, _subtitleSize * k);
  }

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    final FushiAppleColors c = appleColorsOf(context);
    return AppleGalgameLift(
      builder: (BuildContext context, bool hovering) => _appleGalgameCardShell(
        focusId: FushiFocusId('game-recent-${game.id}'),
        semanticLabel: game.displayName,
        radius: ShelfCoverShape.of(
          context,
          ShelfCoverMaterial.gameCase,
        ).nominalRadius,
        onTap: onLaunch,
        onLongPress: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppleGalgameFlatCover(
              game: game,
              width: width,
              hovering: hovering,
              heroTag: galgameCoverHeroTag(game.id),
            ),
            SizedBox(height: _titleGap * k),
            SizedBox(
              height: appleLineExtent(context, _titleSize * k),
              child: Text(
                game.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: appleTextStyle(
                  context,
                  size: _titleSize * k,
                  weight: FontWeight.w500,
                ),
              ),
            ),
            SizedBox(height: _subtitleGap * k),
            SizedBox(
              height: appleLineExtent(context, _subtitleSize * k),
              child: Text(
                subtitle ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: appleTextStyle(
                  context,
                  size: _subtitleSize * k,
                  color: c.secondaryLabel,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 「本周」柱图卡 ───────────────────────────────────────────────────────────

/// 「本周」卡（屏幕使用时间式）：本周大数 + 今日 + 近 7 日柱（今天强调色、其余
/// 55%）+ 日均虚线（共享 [AppleBarChart]，柱从底部长出）。数据只用 State 已算好
/// 的近 7 日秒数，不新查库。
class AppleGalgameWeekCard extends StatelessWidget {
  const AppleGalgameWeekCard({
    required this.weekSeconds,
    required this.todaySeconds,
    required this.days,
    super.key,
  });

  /// 紧凑形态（本周没有游玩）的 key。
  static const Key compactKey = ValueKey<String>('apple-galgame-week-compact');

  final int weekSeconds;
  final int todaySeconds;

  /// 近 7 天每天的游玩秒数（最旧 → 今天）。
  final List<int> days;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final FushiAppleColors c = appleColorsOf(context);
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    final DateTime now = DateTime.now();
    final String week = formatStatTime(weekSeconds * 1000);
    final String today = t.game_home_today_time(
      time: formatStatTime(todaySeconds * 1000),
    );
    final List<int> minutes = <int>[for (final int s in days) (s / 60).round()];
    final int total = minutes.fold<int>(0, (int a, int b) => a + b);
    final double average = minutes.isEmpty ? 0 : total / minutes.length;
    // 本周没玩：紧凑形态（只有数字行），不画一张全是零高柱的空图。
    if (total == 0) {
      return AppleGalgameCardSurface(
        key: compactKey,
        child: Semantics(
          label: '${t.game_home_week_title}: $week, $today',
          excludeSemantics: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                week,
                style: appleTextStyle(
                  context,
                  size: (m.desktop ? 20 : 22) * k,
                  weight: FontWeight.w700,
                ),
              ),
              SizedBox(width: 10 * k),
              Expanded(
                child: Text(
                  today,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: appleTextStyle(
                    context,
                    size: 13 * k,
                    color: c.secondaryLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return AppleGalgameCardSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            label: '${t.game_home_week_title}: $week, $today',
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  week,
                  style:
                      appleTextStyle(
                        context,
                        size: (m.desktop ? 24 : 28) * k,
                        weight: FontWeight.w700,
                      ).copyWith(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                ),
                SizedBox(height: 2 * k),
                Text(
                  today,
                  style: appleTextStyle(
                    context,
                    size: 13 * k,
                    color: c.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 12 * k),
          AppleBarChart(
            height: 112 * k,
            color: c.accent,
            highlightLast: true,
            average: average > 0 ? average : null,
            averageLabel: t.stat_daily_average,
            semanticLabel: t.game_home_week_title,
            bars: <AppleChartBar>[
              for (int i = 0; i < minutes.length; i++)
                AppleChartBar(
                  value: minutes[i],
                  title:
                      '${l10n.narrowWeekdays[now.subtract(Duration(days: minutes.length - 1 - i)).weekday % 7]}'
                      ' · ${formatStatTime(days[i] * 1000)}',
                  label:
                      l10n.narrowWeekdays[now
                              .subtract(Duration(days: minutes.length - 1 - i))
                              .weekday %
                          7],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 游玩状态 ─────────────────────────────────────────────────────────────────

/// 「游玩状态」段：一条分段条（各档占比）+ 有游戏的各档一行的分组列表（色点 · 状态名 · 计数 ›，
/// 行高 ≥ 48）；点行 = 带着该状态的视图进游戏库。焦点站点
/// `game-dashboard-status-<状态>`。
class AppleGalgameStatusCard extends StatelessWidget {
  const AppleGalgameStatusCard({
    required this.counts,
    required this.onStatus,
    super.key,
  });

  final Map<GalgamePlayStatus, int> counts;
  final void Function(GalgamePlayStatus status) onStatus;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final FushiAppleColors c = appleColorsOf(context);
    final Brightness b = Theme.of(context).brightness;
    final int total = counts.values.fold<int>(0, (int a, int v) => a + v);
    // 只列有游戏的档（数据少时紧凑：库里全是「未设置」就只有一行）。
    final List<GalgamePlayStatus> order = <GalgamePlayStatus>[
      for (final GalgamePlayStatus s in kGalgameHomeStatusOrder)
        if ((counts[s] ?? 0) > 0) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ExcludeSemantics(
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(5 * k),
            child: SizedBox(
              height: 10 * k,
              child: total == 0
                  ? ColoredBox(color: c.fill)
                  : Row(
                      children: <Widget>[
                        for (final GalgamePlayStatus s in order)
                          if ((counts[s] ?? 0) > 0)
                            Expanded(
                              flex: counts[s]!,
                              child: ColoredBox(
                                color: galgamePlayStatusDotColor(s, b),
                              ),
                            ),
                      ],
                    ),
            ),
          ),
        ),
        SizedBox(height: 12 * k),
        for (int i = 0; i < order.length; i++)
          FushiGroupedListItem(
            key: ValueKey<String>('apple-galgame-status-${order[i].name}'),
            index: i,
            count: order.length,
            separatorIndent: m.rowHorizontal + 10 * k + 12 * k,
            focusId: FushiFocusId('game-dashboard-status-${order[i].name}'),
            onTap: () => onStatus(order[i]),
            child: Semantics(
              button: true,
              label:
                  '${galgamePlayStatusLabel(order[i])}: ${counts[order[i]] ?? 0}',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: m.rowMinHeight < 48 ? 48 : m.rowMinHeight,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: m.rowHorizontal),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 10 * k,
                        height: 10 * k,
                        decoration: BoxDecoration(
                          color: galgamePlayStatusDotColor(order[i], b),
                          shape: BoxShape.circle,
                        ),
                      ),
                      SizedBox(width: 12 * k),
                      Expanded(
                        child: Text(
                          galgamePlayStatusLabel(order[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: appleTextStyle(context, size: m.titleSize),
                        ),
                      ),
                      Text(
                        '${counts[order[i]] ?? 0}',
                        style: appleTextStyle(
                          context,
                          size: m.titleSize,
                          color: c.secondaryLabel,
                        ),
                      ),
                      SizedBox(width: 6 * k),
                      FushiIcon(
                        FushiIcons.chevronRight,
                        size: 14 * k,
                        color: c.tertiaryLabel,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── 「今天玩这个？」 ─────────────────────────────────────────────────────────

/// 随机推荐卡：平封面 + 标题 / 开发商 / 标签 + 一枚纯视觉的「▶ 启动」胶囊（卡片
/// 外壳的点按就是这个动作，不另立焦点目标）。点按 = 启动，长按 / 右键 = 详情（与
/// M3E 同一约定）。焦点站点 `game-dashboard-random-<id>`。
class AppleGalgameRandomCard extends StatelessWidget {
  const AppleGalgameRandomCard({
    required this.game,
    required this.onLaunch,
    required this.onDetail,
    super.key,
  });

  final GalgameEntry game;
  final VoidCallback onLaunch;
  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final FushiAppleColors c = appleColorsOf(context);
    final BorderRadius radius = fushiCardBorderRadius(context);
    final String meta = <String>[
      if (game.developer case final String d when d.trim().isNotEmpty) d.trim(),
      ...game.tags.take(3),
    ].join(' · ');
    return AppleGalgameLift(
      builder: (BuildContext context, bool hovering) => _appleGalgameCardShell(
        focusId: FushiFocusId('game-dashboard-random-${game.id}'),
        semanticLabel: '${t.game_home_random_eyebrow} ${game.displayName}',
        radius: radius,
        onTap: onLaunch,
        onLongPress: onDetail,
        child: AppleGalgameCardSurface(
          padding: EdgeInsets.all(12 * k),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AppleGalgameFlatCover(
                game: game,
                width: (m.desktop ? 72 : 76) * k,
                hovering: hovering,
              ),
              SizedBox(width: 14 * k),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      game.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: appleTextStyle(
                        context,
                        size: (m.desktop ? 15 : 17) * k,
                        weight: FontWeight.w600,
                      ),
                    ),
                    if (meta.isNotEmpty) ...<Widget>[
                      SizedBox(height: 3 * k),
                      Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: appleTextStyle(
                          context,
                          size: 13 * k,
                          color: c.secondaryLabel,
                        ),
                      ),
                    ],
                    SizedBox(height: 12 * k),
                    ExcludeSemantics(
                      child: Container(
                        height: 28 * k,
                        padding: EdgeInsets.symmetric(horizontal: 12 * k),
                        decoration: BoxDecoration(
                          color: c.fill,
                          borderRadius: BorderRadius.circular(14 * k),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            FushiIcon(
                              FushiIcons.play,
                              size: 12 * k,
                              color: c.accent,
                              fill: 1,
                            ),
                            SizedBox(width: 4 * k),
                            Text(
                              t.game_launch,
                              style: appleTextStyle(
                                context,
                                size: 13 * k,
                                weight: FontWeight.w600,
                                color: c.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 动态 ─────────────────────────────────────────────────────────────────────

/// 时间线吸顶日期头（Apple 分组小标题文字，垫页面底色让内容从它下面滚过）。
class AppleGalgameDateHeader extends StatelessWidget {
  const AppleGalgameDateHeader({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ColoredBox(
      color: tokens.surfaces.page,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(label, style: tokens.type.sectionLabel),
        ),
      ),
    );
  }
}

/// 时间线一行（inset grouped）：行首封面缩略（游戏已删除时回落字形）、标题 +
/// 相对时间、行尾「n 次会话 · 时长 / 加入游戏库」；库里还在的游戏可点 / Enter
/// 进详情。焦点站点 `game-dashboard-activity-<dateKey>-<行号>`。
class AppleGalgameTimelineRow extends StatelessWidget {
  const AppleGalgameTimelineRow({
    required this.entry,
    required this.index,
    required this.count,
    required this.onOpen,
    super.key,
  });

  final GalgameHomeTimelineEntry entry;
  final int index;
  final int count;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final FushiAppleColors c = appleColorsOf(context);
    final double thumb = 36 * k;
    final GalgameEntry? game = entry.game;
    return FushiGroupedListItem(
      index: index,
      count: count,
      separatorIndent:
          m.rowHorizontal + thumb * kShelfGameCaseAspectRatio + 12 * k,
      focusId: FushiFocusId('game-dashboard-activity-${entry.key}'),
      onTap: onOpen,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: m.rowHorizontal,
          vertical: m.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: thumb * kShelfGameCaseAspectRatio,
              height: thumb,
              child: game == null
                  ? Center(
                      child: FushiIcon(
                        entry.added ? FushiIcons.libraryAdd : FushiIcons.games,
                        size: 18 * k,
                        color: c.secondaryLabel,
                      ),
                    )
                  : ShelfCoverShape.of(
                      context,
                      ShelfCoverMaterial.gameCase,
                    ).clip(
                      child: GalgameCoverArt(
                        game: game,
                        decodeWidth: kActivityCoverDecodePixelWidth,
                      ),
                    ),
            ),
            SizedBox(width: 12 * k),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: appleTextStyle(context, size: m.titleSize),
                  ),
                  SizedBox(height: 1 * k),
                  Text(
                    entry.relative,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: appleTextStyle(
                      context,
                      size: m.subtitleSize,
                      color: c.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 8 * k),
            Flexible(
              child: Text(
                entry.trailing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: appleTextStyle(
                  context,
                  size: m.subtitleSize,
                  color: c.secondaryLabel,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 首载骨架 ─────────────────────────────────────────────────────────────────

/// 首载骨架：与真版面同轮廓（副行 → 取色大卡 → 货架 → 本周卡），连续曲率圆角，
/// 一层共享闪光扫过整组（减弱动效停止闪烁）。
class AppleGalgameHomeSkeleton extends StatelessWidget {
  const AppleGalgameHomeSkeleton({super.key});

  static const Key skeletonKey = ValueKey<String>(
    'apple-galgame-home-skeleton',
  );

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    final double tile = AppleGalgameShelfTile.widthFor(context);
    final BorderRadius card = fushiCardBorderRadius(context);
    final BorderRadius cover = ShelfCoverShape.of(
      context,
      ShelfCoverMaterial.gameCase,
    ).nominalRadius;
    Widget block({
      double? width,
      required double height,
      required BorderRadius r,
    }) => ClipRSuperellipse(
      borderRadius: r,
      child: FushiSkeleton(
        width: width,
        height: height,
        borderRadius: BorderRadius.zero,
      ),
    );
    return FushiSkeletonShimmer(
      key: skeletonKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSkeleton.line(widthFactor: 0.4, height: 14 * k),
          SizedBox(height: 14 * k),
          block(height: 216 * k, r: card),
          SizedBox(height: 28 * k),
          FushiSkeleton.line(widthFactor: 0.3, height: 20 * k),
          SizedBox(height: 12 * k),
          SizedBox(
            height: tile / kShelfGameCaseAspectRatio,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              children: <Widget>[
                for (int i = 0; i < 6; i++)
                  Padding(
                    padding: EdgeInsetsDirectional.only(end: 12 * k),
                    child: block(
                      width: tile,
                      height: tile / kShelfGameCaseAspectRatio,
                      r: cover,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: 28 * k),
          block(height: 180 * k, r: card),
        ],
      ),
    );
  }
}
