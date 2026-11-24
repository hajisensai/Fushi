part of '../srs_deck_list_page.dart';

// Apple（Cupertino）复习首页的牌组树外观（拍板点 6 / 7 / 8）：
//
// - 行 = Settings 式 inset grouped 分组里的一行（secondaryGroupedBackground、首尾行
//   圆角、行间 hairline），选中行灰底（未聚焦选择色）；
// - 行首 disclosure 三角（有子牌组时）+ Reminders 式圆角方形牌组图标（系统色板按
//   牌组 id 稳定映射，白字首字母；子牌组是灰色文件夹字形）；
// - 名字 + 今日细进度条 + 副标题（新卡缩减 / 今天已完成 / 正在删除…）；
// - 行尾三色圆体计数（新 blue / 学习中 red / 待复习 green，0 变 tertiaryLabel，不画
//   药丸底）+ 强调色小圆钮 ▶（无活留位对齐）。
//
// 行为全在 [_DeckRow] / [_DeckList] / [_DeckDragShell] 里与 M3E 共用一份：点行（有活 =
// 复习，没活 = 宽屏选中 / 手机进详情）、点计数区看详情（[_countsTarget]）、行首区折叠、←/→ 与手柄 D-pad 折叠、菜单键 / Shift+F10、
// 拖放排序与「移到顶层」落点、删除进度。本文件只多两样 Apple 专属交互：右键 / 窄屏
// 长按出 Apple context menu（[_appleDeckMenuItems]，同项同序、删除红字单独一节），
// iOS 档左滑「复习」。

/// 列表里块与块之间的间距（8pt 栅格：iOS 16、macOS 16 × 缩放）。
double _appleSrsBlockGap(BuildContext context) =>
    16 * FushiAppleMetrics.of(context).scale;

/// 牌组菜单（Apple 档）：与 [_deckMenuItems] 同项同序；带 SF 风格图标，删除单独
/// 一节画成 destructive 红字。远程（已配对设备）只有三项。
///
/// [details]：第一项放「牌组详情」（与 [_deckMenuItems] 同口径：牌组行的菜单）。
List<PopupMenuEntry<_DeckAction>> _appleDeckMenuItems(
  BuildContext context, {
  required bool isDefault,
  required bool canMoveUp,
  required bool canMoveDown,
  bool remote = false,
  bool details = false,
}) {
  FushiPopupMenuItem<_DeckAction> item(
    _DeckAction action,
    IconData icon,
    String label, {
    Color? color,
  }) => FushiPopupMenuItem<_DeckAction>(
    key: ValueKey<String>('srs-deck-menu-${action.name}'),
    value: action,
    icon: icon,
    label: label,
    color: color,
  );
  final List<PopupMenuEntry<_DeckAction>> head = <PopupMenuEntry<_DeckAction>>[
    if (details) item(_DeckAction.details, FushiIcons.info, t.srs_deck_details),
  ];
  if (remote) {
    return <PopupMenuEntry<_DeckAction>>[
      ...head,
      item(
        _DeckAction.customStudy,
        FushiIcons.moreTime,
        t.srs_custom_study_title,
      ),
      item(_DeckAction.browse, FushiIcons.search, t.srs_deck_browse_cards),
      item(_DeckAction.settings, FushiIcons.settings, t.srs_deck_settings),
    ];
  }
  return <PopupMenuEntry<_DeckAction>>[
    ...head,
    item(
      _DeckAction.customStudy,
      FushiIcons.moreTime,
      t.srs_custom_study_title,
    ),
    item(_DeckAction.browse, FushiIcons.search, t.srs_deck_browse_cards),
    item(_DeckAction.addChild, FushiIcons.libraryAdd, t.srs_deck_new_child),
    item(_DeckAction.rename, FushiIcons.edit, t.srs_deck_rename),
    item(_DeckAction.move, FushiIcons.moveFile, t.srs_deck_move),
    if (canMoveUp)
      item(_DeckAction.moveUp, FushiIcons.arrowUp, t.srs_deck_move_up),
    if (canMoveDown)
      item(_DeckAction.moveDown, FushiIcons.arrowDown, t.srs_deck_move_down),
    item(_DeckAction.settings, FushiIcons.settings, t.srs_deck_settings),
    item(
      _DeckAction.fillWordAudio,
      FushiIcons.audio,
      t.srs_word_audio_backfill_title,
    ),
    item(_DeckAction.export, FushiIcons.upload, t.srs_deck_export),
    if (!isDefault) ...<PopupMenuEntry<_DeckAction>>[
      const PopupMenuDivider(),
      item(
        _DeckAction.delete,
        FushiIcons.delete,
        t.srs_deck_delete,
        color: appleColorsOf(context).destructive,
      ),
    ],
  ];
}

/// Reminders 式牌组图标：系统色圆角方形 + 白色首字（[done] 时褪成 40%）。
class _AppleDeckIcon extends StatelessWidget {
  const _AppleDeckIcon({required this.deck, required this.size});

  final SrsDeckSummary deck;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bool done = !_srsDeckHasWork(deck);
    final Color color = appleSrsDeckColor(context, deck.deck.id);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: done ? color.withValues(alpha: 0.4) : color,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: Text(
              _srsDeckInitial(deck),
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.5,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 行尾三色圆体计数（拍板点 7）：新 / 学习中 / 待复习，系统色、0 变灰、无药丸底；
/// 到期一格与 [SrsCountTriple] 同口径（分钟单位写剩余分钟、RWKV 准备中画沙漏）。
class SrsAppleCountTriple extends StatelessWidget {
  const SrsAppleCountTriple({
    super.key,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    this.reviewPending = false,
    this.reviewMinutesLeft,
  });

  final int newCount;
  final int learnCount;
  final int reviewCount;
  final bool reviewPending;
  final int? reviewMinutesLeft;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final AppleSrsSystemColors system = AppleSrsSystemColors.of(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final TextStyle base = appleSrsRounded(
      context,
      (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: (m.desktop ? 13.5 : 16) * s,
        letterSpacing: 0,
        height: 1.2,
      ),
    );
    final double minWidth = (m.desktop ? 22 : 26) * s;
    final SrsReviewCell review = SrsReviewCell(
      due: reviewCount,
      pending: reviewPending,
      minutesLeft: reviewMinutesLeft,
    );
    Widget cell(int value, Color color, String label, {String? text}) =>
        FushiTooltip(
          message: label,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: minWidth),
            child: Text(
              text ?? '$value',
              textAlign: TextAlign.end,
              style: base.copyWith(
                color: value == 0 ? apple.tertiaryLabel : color,
                fontWeight: value == 0 ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
          ),
        );
    return Semantics(
      label:
          '${t.srs_count_new} $newCount, ${t.srs_count_learn} $learnCount, '
          '${review.label()}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: (m.desktop ? 6 : 8) * s,
          children: <Widget>[
            cell(newCount, system.blue, t.srs_count_new),
            cell(learnCount, system.red, t.srs_count_learn),
            if (reviewPending)
              FushiTooltip(
                message: t.srs_review_rwkv_pending,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: minWidth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      if (review.due > 0)
                        Text(
                          review.numbers,
                          style: base.copyWith(
                            color: system.green,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      FushiIcon(
                        FushiIcons.pending,
                        key: const ValueKey<String>('srs-count-review-pending'),
                        size: (base.fontSize ?? 14) * 1.05,
                        color: system.green,
                      ),
                    ],
                  ),
                ),
              )
            else
              cell(
                reviewCount,
                system.green,
                review.byMinutes
                    ? t.srs_count_review_minutes_left(n: reviewMinutesLeft!)
                    : t.srs_count_review,
                text: review.numbers,
              ),
          ],
        ),
      ),
    );
  }
}

/// 行尾强调色小圆钮 ▶（直接复习）：命中区 iOS 44、macOS 28 × 缩放。
class _AppleSrsPlayButton extends StatelessWidget {
  const _AppleSrsPlayButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final double dot = (m.desktop ? 22 : 28) * s;
    return FushiTooltip(
      message: t.srs_home_review_deck,
      excludeFromSemantics: true,
      child: FushiPressScale(
        child: FushiPlainButton(
          onPressed: onTap,
          semanticLabel: t.srs_home_review_deck,
          borderRadius: BorderRadius.circular(dot),
          // 宽 44（iOS 命中区）、高与单行内容同高：不把单行牌组撑过 rowMinHeight。
          child: SizedBox(
            width: m.desktop ? 28 * s : 44,
            height: m.rowMinHeight - 2 * m.rowVertical,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: apple.accent,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: dot,
                  child: Center(
                    child: FushiIcon(
                      FushiIcons.play,
                      size: dot * 0.5,
                      color: apple.onAccent,
                    ),
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

/// 行首 disclosure 三角（展开时转 90°）。命中区与行同高；没有子牌组的行只占位。
class _AppleDisclosure extends StatelessWidget {
  const _AppleDisclosure({
    required this.deckId,
    required this.visible,
    required this.collapsed,
    required this.width,
    required this.onPressed,
  });

  final String deckId;
  final bool visible;
  final bool collapsed;
  final double width;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!visible) return SizedBox(width: width);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    return Semantics(
      expanded: !collapsed,
      button: true,
      label: collapsed ? t.srs_deck_expand : t.srs_deck_collapse,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey<String>('srs-deck-toggle-$deckId'),
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: width,
          height: m.rowMinHeight - 2 * m.rowVertical,
          child: Center(
            child: FushiTreeChevron(
              expanded: !collapsed,
              child: FushiIcon(
                FushiIcons.chevronRight,
                size: (m.desktop ? 11 : 14) * m.scale,
                color: appleColorsOf(context).tertiaryLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [_DeckRow] 的 Apple 外观（行为见 [_DeckRow]）。
extension _AppleDeckRowTile on _DeckRow {
  Widget _appleTile(
    BuildContext context, {
    required bool compact,
    required Widget? bar,
    required String? note,
    required bool work,
    required _LeadingProbe probe,
    required VoidCallback onTap,
    required VoidCallback onMenu,
  }) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final double indent = (m.desktop ? 18 : 22) * s;
    // 三角命中区：iOS 36（行首窄，再宽会挤掉名字）、macOS 24。
    final double disclosure = (m.desktop ? 24 : 36) * s;
    final double iconSize = (m.desktop ? 22 : 30) * s;
    final double start = m.rowHorizontal;
    // 有树时三角贴着行的左缘（命中区自带留白），没有树时照常 inset。
    final double lead = hasTree ? 4 * s : start;
    final double gap = (m.desktop ? 8 : 12) * s;
    final Radius r = Radius.circular(m.groupRadius);
    final BorderRadius radius = BorderRadius.vertical(
      top: index == 0 ? r : Radius.zero,
      bottom: index == count - 1 ? r : Radius.zero,
    );
    final Widget icon = depth == 0
        ? _AppleDeckIcon(deck: deck, size: iconSize)
        : SizedBox.square(
            dimension: iconSize,
            child: Center(
              child: FushiIcon(
                FushiIcons.folder,
                size: iconSize * 0.62,
                color: apple.secondaryLabel,
              ),
            ),
          );
    final Widget leadingRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(width: depth * indent),
        if (hasTree)
          _AppleDisclosure(
            deckId: deck.deck.id,
            visible: hasChildren,
            collapsed: collapsed,
            width: disclosure,
            onPressed: () => onSetCollapsed(!collapsed),
          ),
        icon,
      ],
    );
    final Widget leading = hasChildren
        ? Builder(
            key: ValueKey<String>('srs-deck-leading-toggle-${deck.deck.id}'),
            builder: (BuildContext leadingContext) {
              probe.leading = leadingContext;
              return leadingRow;
            },
          )
        : leadingRow;
    final Text nameText = Text(
      deck.deck.name,
      maxLines: compact ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: m
          .titleStyle(context)
          .copyWith(fontWeight: depth == 0 ? FontWeight.w500 : FontWeight.w400),
    );
    final Widget? subtitle = _subtitle(context, note);
    final Widget body = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        lead,
        m.rowVertical,
        (m.desktop ? 6 : 8) * s,
        m.rowVertical,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: m.rowMinHeight - 2 * m.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            leading,
            SizedBox(width: gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 4 * s,
                children: <Widget>[
                  if (compact)
                    nameText
                  else
                    FushiTooltip(message: deck.fullName, child: nameText),
                  if (bar != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 200 * s),
                      child: bar,
                    ),
                  if (subtitle != null)
                    DefaultTextStyle.merge(
                      style: m.footnoteStyle(context),
                      child: subtitle,
                    ),
                ],
              ),
            ),
            SizedBox(width: gap),
            // 与 M3E 同一个计数区入口（[_countsTarget]）：本机牌组点计数看详情，
            // 有活的行点行是复习，触摸上看详情走这里。
            _countsTarget(
              SrsAppleCountTriple(
                key: ValueKey<String>('srs-counts-${deck.deck.id}'),
                newCount: deck.newCount,
                learnCount: deck.learnCount,
                reviewCount: deck.reviewCount,
                reviewPending: deck.rwkvPending,
                reviewMinutesLeft: deck.reviewMinutesLeft,
              ),
              // 点按区撑满行的内容高（不撑高行）：iOS 档约 44pt。
              minHeight: m.rowMinHeight - 2 * m.rowVertical,
            ),
            // 没活时留位不画：各行的计数列照样对齐。
            Visibility(
              visible: work,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: _AppleSrsPlayButton(
                key: ValueKey<String>('srs-deck-review-${deck.deck.id}'),
                onTap: () => onReview(deck),
              ),
            ),
          ],
        ),
      ),
    );
    final double separatorStart =
        lead + depth * indent + (hasTree ? disclosure : 0) + iconSize + gap;
    Widget row = DecoratedBox(
      decoration: BoxDecoration(
        color: apple.secondaryGroupedBackground,
        borderRadius: radius,
      ),
      child: FushiAppleRow(
        borderRadius: radius,
        selected: selected,
        onTap: onTap,
        onLongPress: compact ? onMenu : null,
        child: Stack(
          children: <Widget>[
            body,
            if (index < count - 1)
              PositionedDirectional(
                start: separatorStart,
                end: 0,
                bottom: 0,
                child: SizedBox(
                  height: fushiHairline(context),
                  child: ColoredBox(color: apple.separator),
                ),
              ),
          ],
        ),
      ),
    );
    row = ContextMenuTrigger(
      onInvoke: contextMenuInvoker(onMenu),
      child: FushiPressScale(child: row),
    );
    // iOS 档左滑「复习」（Mail 式整行滑到底触发，松手回弹，不删行）。
    if (!m.desktop && work && !remote) {
      row = Dismissible(
        key: ValueKey<String>('srs-swipe-${deck.deck.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (DismissDirection _) async {
          onReview(deck);
          return false;
        },
        background: DecoratedBox(
          decoration: BoxDecoration(color: apple.accent, borderRadius: radius),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: EdgeInsetsDirectional.only(end: 20 * s),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: <Widget>[
                  FushiIcon(FushiIcons.play, size: 18, color: apple.onAccent),
                  Text(
                    t.srs_home_review_deck,
                    style: TextStyle(
                      color: apple.onAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        child: row,
      );
    }
    return row;
  }
}

/// 拖着子牌组时列表顶上的「移到顶层」落点（Apple：虚线描边的分组面）。
class _AppleTopLevelDropZone extends StatelessWidget {
  const _AppleTopLevelDropZone({super.key, required this.onPlace});

  final _DeckPlace onPlace;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    return DragTarget<SrsDeckSummary>(
      onWillAcceptWithDetails: (DragTargetDetails<SrsDeckSummary> d) =>
          d.data.parentId != null,
      onAcceptWithDetails: (DragTargetDetails<SrsDeckSummary> d) =>
          onPlace(d.data, null, null),
      builder:
          (
            BuildContext context,
            List<SrsDeckSummary?> candidates,
            List<dynamic> _,
          ) {
            final bool hovering = candidates.isNotEmpty;
            return AnimatedContainer(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              constraints: BoxConstraints(minHeight: m.rowMinHeight),
              padding: EdgeInsets.symmetric(horizontal: m.rowHorizontal),
              decoration: BoxDecoration(
                color: hovering
                    ? apple.accent.withValues(alpha: 0.14)
                    : apple.secondaryGroupedBackground,
                border: Border.all(
                  color: hovering ? apple.accent : apple.separator,
                  width: hovering ? 2 : 1,
                ),
                borderRadius: m.groupBorderRadius,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 8,
                children: <Widget>[
                  FushiIcon(
                    FushiIcons.moveFile,
                    size: m.leadingIconSize,
                    color: apple.accent,
                  ),
                  Flexible(
                    child: Text(
                      t.srs_deck_move_drop_top_level,
                      style: m.titleStyle(context),
                    ),
                  ),
                ],
              ),
            );
          },
    );
  }
}

/// Apple 档「已配对设备」分区：分组标题 + 每台主机一组（组头 + 它的牌组行连成一组），
/// 组下脚注是远程复习说明。数据与动作同 M3E（[_SrsPairedHosts] / [_PairedDeckActions]）。
class _AppleSrsPairedSection extends StatelessWidget {
  const _AppleSrsPairedSection({super.key, required this.paired});

  final _SrsPairedHosts paired;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: paired,
    builder: (BuildContext context, Widget? _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: _appleSrsBlockGap(context) / 2,
      children: <Widget>[
        _AppleSrsSectionHeader(
          title: t.srs_home_paired_header,
          action: FushiIconButton(
            key: const ValueKey<String>('srs-home-paired-refresh'),
            icon: FushiIcons.refresh,
            tooltip: t.refresh,
            onTap: () => srsRunLogged('SrsPairedHosts.refresh', paired.refresh),
          ),
        ),
        for (final _PairedHost h in paired.hosts)
          _AppleSrsPairedDeviceGroup(
            key: ValueKey<String>('srs-paired-${h.target.hostId}'),
            host: h,
            paired: paired,
          ),
      ],
    ),
  );
}

class _AppleSrsPairedDeviceGroup extends StatelessWidget {
  const _AppleSrsPairedDeviceGroup({
    super.key,
    required this.host,
    required this.paired,
  });

  final _PairedHost host;
  final _SrsPairedHosts paired;

  @override
  Widget build(BuildContext context) {
    final SrsRemoteSession? session = host.session;
    if (session == null) return _group(context, null);
    return SrsRemoteCollectionScope(
      key: ObjectKey(session),
      store: session.store,
      media: session.media,
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? _) =>
            _group(context, ref),
      ),
    );
  }

  Widget _group(BuildContext context, WidgetRef? ref) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final List<SrsDeckSummary> decks = host.decks ?? const <SrsDeckSummary>[];
    final bool open = host.expanded && ref != null && host.decks != null;
    final Map<String, SrsDeckSummary> byId = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in decks) d.deck.id: d,
    };
    final List<bool> visible = <bool>[
      for (final SrsDeckSummary d in decks)
        open &&
            !_srsDeckHiddenByCollapse(
              d,
              byId,
              rootId: null,
              collapsed: host.isCollapsed,
            ),
    ];
    final int visibleRows = visible.where((bool v) => v).length;
    final bool empty = open && decks.isEmpty;
    // 组头是分组的第 0 行，可见的牌组行（或「没有牌组」）接在后面。
    final int count = 1 + visibleRows + (empty ? 1 : 0);
    final Set<String> parents = <String>{
      for (final SrsDeckSummary d in decks)
        if (d.parentId != null) d.parentId!,
    };
    final String hostId = host.target.hostId;
    final List<Widget> rows = <Widget>[];
    if (ref != null) {
      final _PairedDeckActions actions = _PairedDeckActions(
        context: context,
        ref: ref,
        host: host,
        paired: paired,
      );
      int shown = 1;
      for (int i = 0; i < decks.length; i++) {
        final SrsDeckSummary d = decks[i];
        final int index = visible[i] ? shown++ : shown;
        rows.add(
          FushiTreeReveal(
            key: ValueKey<String>('srs-paired-deck-$hostId-${d.deck.id}'),
            visible: visible[i],
            child: _DeckRow(
              deck: d,
              depth: d.depth,
              badge: null,
              doneToday: null,
              selected: false,
              deleting: null,
              index: index,
              count: count,
              isDefault: false,
              hasTree: parents.isNotEmpty,
              hasChildren: parents.contains(d.deck.id),
              collapsed: host.isCollapsed(d),
              onSetCollapsed: (bool c) => paired.setCollapsed(host, d, c),
              onOpen: actions.review,
              onReview: actions.review,
              onAction: actions.run,
              canMoveUp: false,
              canMoveDown: false,
              remote: true,
              apple: true,
            ),
          ),
        );
      }
    }
    final FushiAppleColors apple = appleColorsOf(context);
    final Radius r = Radius.circular(m.groupRadius);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AppleSrsPairedHeader(
          host: host,
          paired: paired,
          ref: ref,
          last: count == 1,
        ),
        ...rows,
        FushiTreeReveal(
          key: ValueKey<String>('srs-paired-empty-$hostId'),
          visible: empty,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: apple.secondaryGroupedBackground,
              borderRadius: BorderRadius.vertical(bottom: r),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: m.rowHorizontal,
                vertical: m.rowVertical * 1.5,
              ),
              child: Text(
                t.srs_remote_review_decks_empty,
                style: m.subtitleStyle(context),
              ),
            ),
          ),
        ),
        FushiTreeReveal(
          key: ValueKey<String>('srs-paired-hint-$hostId'),
          visible: open && decks.isNotEmpty,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              m.rowHorizontal,
              6 * m.scale,
              m.rowHorizontal,
              0,
            ),
            child: Text(
              t.srs_remote_review_hint,
              style: m.footnoteStyle(context),
            ),
          ),
        ),
      ],
    );
  }
}

/// 主机组头：灰色设备图标、名字、状态副标题、三色计数、出错重试、⋯ 菜单、展开三角。
/// 点组头展开 / 收起；出错时点组头重试。
class _AppleSrsPairedHeader extends StatelessWidget {
  const _AppleSrsPairedHeader({
    required this.host,
    required this.paired,
    required this.ref,
    required this.last,
  });

  final _PairedHost host;
  final _SrsPairedHosts paired;
  final WidgetRef? ref;

  /// 组里只有组头（收起 / 没连上）：底边也圆角。
  final bool last;

  void _retry() => srsRunLogged('SrsPairedHosts.load', () => paired.load(host));

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final List<SrsDeckSummary>? decks = host.decks;
    final _PairedDeckTotals? totals = decks == null
        ? null
        : _PairedDeckTotals.of(decks);
    final String? error = host.error;
    final String hostId = host.target.hostId;
    final String status = _srsPairedStatus(
      context,
      host,
      paired,
      totals,
      error,
    );
    final WidgetRef? scoped = ref;
    final bool canExpand = totals != null && host.session != null;
    final Radius r = Radius.circular(m.groupRadius);
    final BorderRadius radius = BorderRadius.vertical(
      top: r,
      bottom: last ? r : Radius.zero,
    );
    final double tile = m.iconTileSize + 4 * s;
    return FushiPressScale(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: apple.secondaryGroupedBackground,
          borderRadius: radius,
        ),
        child: FushiAppleRow(
          key: ValueKey<String>('srs-paired-header-$hostId'),
          borderRadius: radius,
          onTap: error != null
              ? _retry
              : canExpand
              ? () => paired.toggleExpanded(host)
              : null,
          child: Semantics(
            expanded: canExpand ? host.expanded : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: m.rowHorizontal,
                vertical: m.rowVertical,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: m.rowMinHeight - 2 * m.rowVertical,
                ),
                child: Row(
                  spacing: (m.desktop ? 8 : 12) * s,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        color: AppleSrsSystemColors.of(context).gray,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(tile * 0.28),
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: tile,
                        child: Center(
                          child: FushiIcon(
                            FushiIcons.laptop,
                            size: tile * 0.6,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            host.target.displayName,
                            style: m.titleStyle(context),
                          ),
                          if (status.isNotEmpty)
                            Text(status, style: m.footnoteStyle(context)),
                        ],
                      ),
                    ),
                    if (totals != null)
                      SrsAppleCountTriple(
                        newCount: totals.newCount,
                        learnCount: totals.learnCount,
                        reviewCount: totals.reviewCount,
                        reviewPending: totals.rwkvPending,
                      ),
                    if (error != null)
                      FushiIconButton(
                        key: ValueKey<String>('srs-paired-retry-$hostId'),
                        icon: FushiIcons.refresh,
                        tooltip: t.retry,
                        onTap: _retry,
                      ),
                    if (scoped != null)
                      FushiPopupMenuButton<_PairedHostAction>(
                        key: ValueKey<String>('srs-paired-menu-$hostId'),
                        tooltip: t.srs_deck_menu,
                        icon: const FushiIcon(FushiIcons.more),
                        onSelected: (_PairedHostAction a) => _PairedDeckActions(
                          context: context,
                          ref: scoped,
                          host: host,
                          paired: paired,
                        ).runHost(a),
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<_PairedHostAction>>[
                              FushiPopupMenuItem<_PairedHostAction>(
                                value: _PairedHostAction.addNote,
                                icon: FushiIcons.add,
                                label: t.srs_note_add,
                              ),
                              FushiPopupMenuItem<_PairedHostAction>(
                                value: _PairedHostAction.browse,
                                icon: FushiIcons.search,
                                label: t.srs_browse_title,
                              ),
                              FushiPopupMenuItem<_PairedHostAction>(
                                value: _PairedHostAction.refresh,
                                icon: FushiIcons.refresh,
                                label: t.refresh,
                              ),
                            ],
                      ),
                    if (canExpand)
                      FushiTreeChevron(
                        expanded: host.expanded,
                        child: FushiIcon(
                          FushiIcons.chevronRight,
                          size: m.chevronSize,
                          color: apple.tertiaryLabel,
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
