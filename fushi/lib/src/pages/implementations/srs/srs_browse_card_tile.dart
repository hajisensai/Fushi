/// 浏览页列表的富卡片（正面大字 + 两个字段摘要 + 状态标签 + 保持率条 + 下次到期 + 出处小标 + 旗标）、
/// 手机左滑露出的「暂停 / 旗标」，以及出处的文字 / 图标（出处视图共用）。
library;

import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSourceKind, SrsSourceRef;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/anki/card_source_origin.dart'
    show formatCardSourceClock;
import 'package:fushi/src/pages/implementations/srs/srs_browse_dialogs.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 保持率的状态色：≥ 80% 绿、≥ 60% 橙、其余红。
FushiStatusTone srsBrowseRetentionTone(double retention) => retention >= 0.8
    ? FushiStatusTone.success
    : retention >= 0.6
    ? FushiStatusTone.warning
    : FushiStatusTone.error;

/// 「62%」。
String srsBrowsePercent(double value) => '${(value * 100).round()}%';

/// 出处种类的文字。
String srsBrowseSourceKindLabel(String? kind) => switch (kind) {
  SrsSourceKind.book ||
  SrsSourceKind.onlineNovel => t.srs_browse_source_kind_book,
  SrsSourceKind.manga => t.srs_browse_source_kind_manga,
  SrsSourceKind.video ||
  SrsSourceKind.onlineVideo => t.srs_browse_source_kind_video,
  SrsSourceKind.audiobook => t.srs_browse_source_kind_audiobook,
  SrsSourceKind.game => t.srs_browse_source_kind_game,
  SrsSourceKind.music => t.srs_browse_source_kind_music,
  SrsSourceKind.web => t.srs_browse_source_kind_web,
  _ => t.srs_browse_source_kind_other,
};

/// 出处种类的图标。
IconData srsBrowseSourceKindIcon(String? kind) => switch (kind) {
  SrsSourceKind.book || SrsSourceKind.onlineNovel => FushiIcons.books,
  SrsSourceKind.manga => FushiIcons.manga,
  SrsSourceKind.video || SrsSourceKind.onlineVideo => FushiIcons.video,
  SrsSourceKind.audiobook => FushiIcons.audiobook,
  SrsSourceKind.game => FushiIcons.games,
  SrsSourceKind.music => FushiIcons.music,
  SrsSourceKind.web => FushiIcons.globe,
  _ => FushiIcons.link,
};

/// 出处标题：出处数据自带的标题，没有就用种类名。
String srsBrowseSourceTitle(SrsSourceRef? source, String? kind) {
  final String? title = source?.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return srsBrowseSourceKindLabel(source?.kind ?? kind);
}

/// 出处里的位置（「p.97」「12:48」「§3」）；没有 null。只读出处数据里现成的定位，不查库。
String? srsBrowseSourceLocator(SrsSourceRef? source) {
  if (source == null) return null;
  final Map<String, Object?> d = source.data;
  if (d['page'] case final int page) return 'p.${page + 1}';
  if (d['startMs'] case final int ms) return formatCardSourceClock(ms);
  if (d['section'] case final int section) return '§${section + 1}';
  return null;
}

/// 下次到期的短文字（「今天」「3 天后」「新卡」…）。
String srsBrowseDueText(SrsBrowseRow c) {
  if (c.isNew) return t.srs_status_new;
  final int? days = c.dueInDays;
  if (days == null || days <= 0) return t.srs_browse_due_today;
  return t.srs_status_review_in(n: days);
}

/// 保持率条：细轨道 + 按保持率着色的填充（长度动画）。
class SrsBrowseRetentionBar extends StatelessWidget {
  const SrsBrowseRetentionBar({super.key, required this.retention, this.width});

  final double retention;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final Color track = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final Color fill = fushiStatusColor(
      context,
      srsBrowseRetentionTone(retention),
    );
    return SizedBox(
      width: width,
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: DecoratedBox(
          decoration: BoxDecoration(color: track),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: retention.clamp(0, 1)),
              duration: fushiMotionDuration(context, FushiMotion.long),
              curve: FushiMotion.enter,
              builder: (BuildContext context, double f, Widget? _) =>
                  FractionallySizedBox(
                    widthFactor: f,
                    heightFactor: 1,
                    child: ColoredBox(color: fill),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表里的一张富卡片。
class SrsBrowseCardTile extends StatelessWidget {
  const SrsBrowseCardTile({
    super.key,
    required this.row,
    required this.id,
    required this.cardsMode,
    required this.selected,
    required this.current,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTap,
    required this.onToggle,
  });

  final SrsBrowseRow row;

  /// 行 id（卡片模式 = 卡 id，笔记模式 = 笔记 id）。
  final String id;
  final bool cardsMode;
  final bool selected;
  final bool current;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onSecondaryTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : scheme.onSurfaceVariant;
    final SrsBrowseRow c = row;
    final Color? flag = srsFlagColor(c.flag);
    final double? retention = c.retention;
    final SrsSourceRef? source = c.source;
    final String? locator = srsBrowseSourceLocator(source);
    final TextStyle meta = context.fushiType.bodySmall.copyWith(color: muted);
    final List<String> metaParts = <String>[
      if (retention != null)
        t.srs_browse_retention(p: srsBrowsePercent(retention)),
      if (cardsMode)
        srsBrowseDueText(c)
      else
        t.srs_browse_count_cards(n: c.cardCount),
      if (c.lapses >= 4) t.srs_browse_lapses(n: c.lapses),
      if (c.deckName.isNotEmpty) c.deckName,
    ];
    final Widget front = Text(
      c.sortText.isEmpty ? '—' : c.sortText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.fushiType.titleLargeEmphasized,
    );
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Expanded(child: front),
            if (cardsMode)
              FushiTag(
                key: ValueKey<String>('srs-browse-status-$id'),
                text: srsBrowseCardStatus(c),
                tone: srsBrowseCardStatusTone(c),
                dense: true,
              ),
            if (c.hasPendingDecision)
              FushiIcon(
                FushiIcons.warning,
                size: 18,
                color: fushiStatusColor(context, FushiStatusTone.error),
              ),
            if (flag != null)
              FushiIcon(FushiIcons.flag, size: 18, color: flag, fill: 1),
          ],
        ),
        for (final String f in c.fieldPreview)
          Text(
            f,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodyMedium.copyWith(color: muted),
          ),
        Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            if (retention != null)
              SrsBrowseRetentionBar(retention: retention, width: 48),
            Expanded(
              child: Text(
                metaParts.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta,
              ),
            ),
            if (source != null)
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: <Widget>[
                    FushiIcon(
                      srsBrowseSourceKindIcon(source.kind),
                      size: 14,
                      color: muted,
                    ),
                    Flexible(
                      child: Text(
                        <String>[
                          srsBrowseSourceTitle(source, c.sourceKind),
                          ?locator,
                        ].join(' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: meta,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
    return FushiHoverLift(
      enabled: !selecting,
      scale: 1.01,
      builder: (BuildContext context, bool hovering) => FushiCard(
        key: ValueKey<String>('srs-browse-row-$id'),
        selected: selected || current,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onSecondaryTap,
        padding: EdgeInsetsDirectional.fromSTEB(
          tokens.spacing.gap * 1.5,
          tokens.spacing.gap * 1.25,
          tokens.spacing.gap * 1.5,
          tokens.spacing.gap * 1.25,
        ),
        child: Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            AnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: selecting
                  ? FushiCheckbox(
                      key: ValueKey<String>('srs-browse-check-$id'),
                      value: selected,
                      onChanged: (_) => onToggle(),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// 一个左滑露出的动作。
class SrsBrowseSwipeAction {
  const SrsBrowseSwipeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.keyName,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String? keyName;
}

/// 手机行的左滑：往左拖露出 [actions]（右滑不做，免得和系统返回手势冲突），拖过一半松手停在展开态，
/// 点动作或点卡片收回。
class SrsBrowseSwipeReveal extends StatefulWidget {
  const SrsBrowseSwipeReveal({
    super.key,
    required this.child,
    required this.actions,
    this.enabled = true,
  });

  final Widget child;
  final List<SrsBrowseSwipeAction> actions;
  final bool enabled;

  @override
  State<SrsBrowseSwipeReveal> createState() => _SrsBrowseSwipeRevealState();
}

class _SrsBrowseSwipeRevealState extends State<SrsBrowseSwipeReveal>
    with SingleTickerProviderStateMixin {
  static const double _actionWidth = 76;
  late final AnimationController _open = AnimationController(vsync: this);

  double get _extent => _actionWidth * widget.actions.length;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  void _settle(bool open) {
    _open.animateTo(
      open ? 1 : 0,
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
    );
  }

  @override
  void didUpdateWidget(SrsBrowseSwipeReveal old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && _open.value > 0) _open.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    // 停用（多选中 / 忙）时只关掉手势与底层动作，子树形状不变：换成裸 child 会把整张卡（悬停 / 按压动效的
    // 状态）销毁重建，长按进多选那一下松手的指针事件就打到已销毁的状态上。
    final bool enabled = widget.enabled && widget.actions.isNotEmpty;
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color under = apple
        ? appleColorsOf(context).tertiaryGroupedBackground
        : scheme.surfaceContainerHighest;
    final TextDirection dir = Directionality.of(context);
    final double sign = dir == TextDirection.rtl ? 1 : -1;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: !enabled
          ? null
          : (DragUpdateDetails d) {
              _open.value = (_open.value + d.primaryDelta! * sign / _extent)
                  .clamp(0, 1);
            },
      onHorizontalDragEnd: !enabled
          ? null
          : (DragEndDetails d) {
              final double v = (d.primaryVelocity ?? 0) * sign;
              _settle(v > 300 || (v > -300 && _open.value > 0.5));
            },
      child: ClipRRect(
        borderRadius: apple
            ? FushiAppleMetrics.of(context).groupBorderRadius
            : FushiM3eShape.cardRadius,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _open,
                builder: (BuildContext context, Widget? child) =>
                    Offstage(offstage: _open.value == 0, child: child),
                child: ColoredBox(
                  color: under,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final SrsBrowseSwipeAction a in widget.actions)
                          SizedBox(
                            width: _actionWidth,
                            child: Semantics(
                              button: true,
                              label: a.label,
                              child: FushiPressScale(
                                child: GestureDetector(
                                  key: a.keyName == null
                                      ? null
                                      : ValueKey<String>(a.keyName!),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    _settle(false);
                                    a.onPressed();
                                  },
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    spacing: 4,
                                    children: <Widget>[
                                      FushiIcon(a.icon, size: 22),
                                      Text(
                                        a.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.fushiType.labelSmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _open,
              builder: (BuildContext context, Widget? child) =>
                  Transform.translate(
                    offset: Offset(sign * _extent * _open.value, 0),
                    child: child,
                  ),
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  if (_open.value > 0) _settle(false);
                  return false;
                },
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
