part of 'media_item_dialog_page.dart';

// ---------------------------------------------------------------------------
// 统一条目菜单（2026-11-20 #4b，设计稿 fushi/build/feedback_1120_design #i4b）
// ---------------------------------------------------------------------------
//
// 书 / 漫画、视频、游戏、合集的右键菜单与手机长按底部面板共用这一套骨架，四种
// 媒体只负责往 [ItemMenuSlot] 里填数据：
//
//   头部（封面 · 标题 · 进度）
//   主操作行（大号「继续」+ 至多 3 个带文字的常用操作）
//   工作台入口（媒体专属，副行显示状态）
//   整理（「编辑信息 ›」簇 · 平铺项 · 「排序 ›」簇）
//   开关行（私密 / NSFW，看得出当前开关）
//   更多 ›（二级菜单，副文字列出里面有哪些项）
//   危险操作（单独一段，红色）
//
// 键盘：↑ / ↓ 在行间移动，主操作行里 ← / → 左右移动；子菜单行上 → / Enter 进
// 二级菜单，← / Esc 返回；最外层 Esc 关菜单。桌面右键二级菜单浮在行旁；手机
// 底部面板里改成面板内下钻（同一份数据）。

/// 分好段的菜单数据（右键菜单与底部面板共用）。
class _ItemMenuModel {
  _ItemMenuModel._({
    required this.primary,
    required this.workbench,
    required this.edit,
    required this.organize,
    required this.sort,
    required this.toggles,
    required this.more,
    required this.danger,
  });

  factory _ItemMenuModel.of(MediaItemDialogFrame frame) {
    final List<DialogAction> all = <DialogAction>[
      ...frame.quickActions,
      ...frame.listActions,
    ];
    List<DialogAction> inSlot(ItemMenuSlot slot) =>
        all.where((DialogAction a) => a.menuSlot == slot).toList();
    final List<DialogAction> primaryAll = inSlot(ItemMenuSlot.primary);
    final List<DialogAction> edit = inSlot(ItemMenuSlot.edit);
    final List<DialogAction> sort = inSlot(ItemMenuSlot.sort);
    final List<DialogAction> organizeAll = inSlot(ItemMenuSlot.organize);
    final int clusterRows = (edit.isEmpty ? 0 : 1) + (sort.isEmpty ? 0 : 1);
    final int room = math.max(
      0,
      MediaItemDialogFrame.organizeMaxRows - clusterRows,
    );
    final List<DialogAction> overflow = <DialogAction>[
      ...primaryAll.skip(MediaItemDialogFrame.primaryMax),
      ...organizeAll.skip(room),
      ...inSlot(ItemMenuSlot.more),
    ];
    return _ItemMenuModel._(
      primary: primaryAll.take(MediaItemDialogFrame.primaryMax).toList(),
      workbench: inSlot(ItemMenuSlot.workbench),
      edit: edit,
      organize: organizeAll.take(room).toList(),
      sort: sort,
      toggles: inSlot(
        ItemMenuSlot.toggle,
      ).whereType<DialogToggleAction>().toList(),
      // 「更多」里按分组排：整理 → 内容 → 进度 → 设置，同组保持原顺序。
      more: <DialogAction>[
        for (final DialogActionGroup group in DialogActionGroup.values)
          ...overflow.where((DialogAction a) => a.group == group),
      ],
      danger: frame.dangerActions,
    );
  }

  final List<DialogAction> primary;
  final List<DialogAction> workbench;
  final List<DialogAction> edit;
  final List<DialogAction> organize;
  final List<DialogAction> sort;
  final List<DialogToggleAction> toggles;
  final List<DialogAction> more;
  final List<DialogDangerAction> danger;

  bool get hasOrganize =>
      edit.isNotEmpty || organize.isNotEmpty || sort.isNotEmpty;
}

/// 一组子项的副文字：列出里面有哪些项（去掉与簇名相同的那一项）。
String _itemMenuSummary(List<DialogAction> actions, {String? except}) => actions
    .map((DialogAction a) => a.label)
    .where((String label) => label != except)
    .join(' · ');

/// 面板内下钻的一页（手机底部面板的二级菜单）。
class _ItemMenuPage {
  const _ItemMenuPage({
    required this.title,
    required this.actions,
    required this.origin,
  });

  final String title;
  final List<DialogAction> actions;

  /// 打开本页的那一行：返回时把焦点还给它。
  final FocusNode origin;
}

/// 统一条目菜单本体。[flyout] = 桌面右键菜单（定宽，二级菜单浮在行旁）；
/// 否则 = 手机底部面板（铺满宽度，二级菜单面板内下钻）。
class _ItemMenuPanel extends StatefulWidget {
  const _ItemMenuPanel({
    required this.frame,
    required this.aspect,
    required this.flyout,
  });

  final MediaItemDialogFrame frame;
  final double? aspect;
  final bool flyout;

  static const double width = 320;

  @override
  State<_ItemMenuPanel> createState() => _ItemMenuPanelState();
}

class _ItemMenuPanelState extends State<_ItemMenuPanel> {
  _ItemMenuPage? _page;

  void _openPage(String title, List<DialogAction> actions, FocusNode origin) {
    setState(
      () =>
          _page = _ItemMenuPage(title: title, actions: actions, origin: origin),
    );
  }

  void _closePage() {
    final _ItemMenuPage? page = _page;
    if (page == null) return;
    setState(() => _page = null);
    page.origin.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_page == null || event is KeyUpEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.arrowLeft) {
      _closePage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final MediaItemDialogFrame frame = widget.frame;
    final _ItemMenuModel model = _ItemMenuModel.of(frame);
    final _ItemMenuPage? page = _page;
    final Widget main = _buildMain(context, model);
    final Widget content = page == null
        ? main
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 主菜单保持挂载（行的焦点节点还在，返回时焦点回到打开它的那一行），
              // 只是不占位、不进焦点链。
              Offstage(child: ExcludeFocus(child: main)),
              _buildPage(context, page),
            ],
          );
    final Widget body = Focus(
      onKeyEvent: _onKey,
      skipTraversal: true,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Padding(
            padding: EdgeInsets.all(widget.flyout ? 6 : 12),
            child: content,
          ),
        ),
      ),
    );
    if (!widget.flyout) return body;
    return SizedBox(
      width: _ItemMenuPanel.width,
      child: _ItemMenuSurface(child: SingleChildScrollView(child: body)),
    );
  }

  Widget _buildMain(BuildContext context, _ItemMenuModel model) {
    final MediaItemDialogFrame frame = widget.frame;
    final bool flyout = widget.flyout;
    int index = 0;
    Widget enter(Widget child) =>
        FushiStaggeredEntrance(index: index++, child: child);
    Widget submenu({
      required IconData icon,
      required String label,
      required List<DialogAction> actions,
      String? subtitle,
      Key? key,
    }) => _ItemSubmenuRow(
      key: key,
      icon: icon,
      label: label,
      subtitle: subtitle ?? _itemMenuSummary(actions, except: label),
      actions: actions,
      flyout: flyout,
      onOpenPage: _openPage,
    );
    Widget plain(DialogAction action) => _ContextMenuRow(
      icon: action.icon,
      label: action.label,
      subtitle: action.subtitle,
      onPressed: action.onPressed,
      selected: action.selected,
    );
    final List<Widget> organizeRows = <Widget>[
      if (model.edit.length == 1) plain(model.edit.single),
      if (model.edit.length > 1)
        submenu(
          key: const ValueKey<String>('item_menu_edit_group'),
          icon: FushiIcons.edit,
          label: t.dialog_edit_info,
          actions: model.edit,
        ),
      for (final DialogAction action in model.organize) plain(action),
      if (model.sort.length == 1) plain(model.sort.single),
      if (model.sort.length > 1)
        submenu(
          key: const ValueKey<String>('item_menu_sort_group'),
          icon: FushiIcons.dragIndicator,
          label: t.item_menu_sort_group,
          actions: model.sort,
        ),
    ];
    final bool hasPrimary = frame._hasLaunch || model.primary.isNotEmpty;
    final List<Widget> children = <Widget>[
      enter(_ItemMenuHeader(frame: frame, aspect: widget.aspect)),
      if (hasPrimary)
        enter(
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
            child: _ItemMenuPrimaryRow(
              launchLabel: frame._hasLaunch ? frame.launchLabel : null,
              onLaunch: frame._hasLaunch ? frame.onLaunch : null,
              actions: model.primary,
            ),
          ),
        ),
      for (final DialogAction action in model.workbench)
        enter(
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
            child: _ItemWorkbenchRow(
              action: action,
              flyout: flyout,
              onOpenPage: _openPage,
            ),
          ),
        ),
      if (model.hasOrganize) ...<Widget>[
        _ItemMenuSectionLabel(text: t.item_actions_group_organize),
        for (final Widget row in organizeRows) enter(row),
      ],
      if (model.toggles.isNotEmpty) ...<Widget>[
        if (model.hasOrganize || hasPrimary) const _MenuDivider(),
        for (final DialogToggleAction action in model.toggles)
          enter(_ItemToggleRow(key: ValueKey(action.label), action: action)),
      ],
      if (model.more.isNotEmpty) ...<Widget>[
        if (model.toggles.isEmpty && (model.hasOrganize || hasPrimary))
          const _MenuDivider(),
        enter(
          submenu(
            key: const ValueKey<String>('item_menu_more'),
            icon: FushiIcons.moreHoriz,
            label: t.item_menu_more,
            actions: model.more,
          ),
        ),
      ],
      if (model.danger.isNotEmpty) ...<Widget>[
        const _MenuDivider(),
        for (final DialogDangerAction action in model.danger)
          enter(
            action.enabled
                ? _ContextMenuRow(
                    icon: action.icon,
                    label: action.label,
                    onPressed: action.onPressed,
                    destructive: !action.muted,
                  )
                : _ContextMenuDisabledRow(action: action),
          ),
      ],
    ];
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildPage(BuildContext context, _ItemMenuPage page) {
    return FushiEntranceScope(
      key: ValueKey<String>('item_menu_page_${page.title}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: _ItemMenuBackRow(title: page.title, onPressed: _closePage),
          ),
          const _MenuDivider(),
          for (int i = 0; i < page.actions.length; i++)
            FushiStaggeredEntrance(
              index: i + 1,
              child: _ContextMenuRow(
                icon: page.actions[i].icon,
                label: page.actions[i].label,
                subtitle: page.actions[i].subtitle,
                onPressed: page.actions[i].onPressed,
                selected: page.actions[i].selected,
              ),
            ),
        ],
      ),
    );
  }
}

/// 浮层面板的底：MD3 surfaceContainer 圆角 16 + 投影；Apple 系统实色悬浮面。
class _ItemMenuSurface extends StatelessWidget {
  const _ItemMenuSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(apple ? 12 : 20)),
    );
    if (apple) {
      // 与 showFushiMenu 同一块 Apple 菜单面板（随玻璃画质、菜单圆角）。
      return FushiAppleMenuSurface(child: child);
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: shape,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 头部：小封面 + 标题（两行）+ 进度行。
class _ItemMenuHeader extends StatelessWidget {
  const _ItemMenuHeader({required this.frame, required this.aspect});

  final MediaItemDialogFrame frame;
  final double? aspect;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color titleColor = apple
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurface;
    // iOS 27 上下文菜单顶部的标题：13pt secondaryLabel（不抢菜单行的视觉）。
    final TextStyle? appleTitle = apple
        ? TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: titleColor,
            letterSpacing: 0,
          )
        : null;
    final String? line = frame.progressLabel ?? frame.author;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: Row(
        children: <Widget>[
          if (frame.cover != null) ...<Widget>[
            frame._buildCoverCard(
              context,
              aspect: aspect,
              maxWidth: 34,
              maxHeight: 48,
              radius: 6,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiTooltip(
                  message: frame.title,
                  child: Text(
                    frame.title,
                    key: const ValueKey<String>('item_menu_title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        appleTitle ??
                        (textTheme.titleSmall ?? const TextStyle()).copyWith(
                          color: titleColor,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (line != null && line.isNotEmpty)
                  Text(
                    line,
                    key: const ValueKey<String>('item_menu_progress'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: apple
                        ? TextStyle(
                            fontSize: 13,
                            color: appleColorsOf(context).tertiaryLabel,
                            letterSpacing: 0,
                          )
                        : (textTheme.bodySmall ?? const TextStyle()).copyWith(
                            color: frame._authorStyle(context).color,
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemMenuSectionLabel extends StatelessWidget {
  const _ItemMenuSectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return FushiAppleMenuSectionHeader(text, alignWithCheck: false);
    }
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        text,
        style: (Theme.of(context).textTheme.labelSmall ?? const TextStyle())
            .copyWith(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// 主操作行：大号「继续」（主色实心）+ 至多 3 个带文字的常用操作（图标在上、
/// 文字在下）。行内 ← / → 左右移动焦点。
class _ItemMenuPrimaryRow extends StatelessWidget {
  const _ItemMenuPrimaryRow({
    required this.launchLabel,
    required this.onLaunch,
    required this.actions,
  });

  final String? launchLabel;
  final VoidCallback? onLaunch;
  final List<DialogAction> actions;

  @override
  Widget build(BuildContext context) {
    final String? launch = launchLabel;
    final VoidCallback? onLaunch = this.onLaunch;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowRight): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): PreviousFocusIntent(),
      },
      child: SizedBox(
        height: 58,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: <Widget>[
            if (launch != null && onLaunch != null)
              Expanded(
                flex: 16,
                child: _ItemPrimaryButton(
                  key: const ValueKey<String>('item_menu_launch'),
                  icon: FushiIcons.play,
                  label: launch,
                  onPressed: onLaunch,
                  filled: true,
                ),
              ),
            for (final DialogAction action in actions)
              Expanded(
                flex: 10,
                child: _ItemPrimaryButton(
                  icon: action.icon,
                  label: action.label,
                  onPressed: action.onPressed,
                  selected: action.selected,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ItemPrimaryButton extends StatelessWidget {
  const _ItemPrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiAppleColors? palette = apple ? appleColorsOf(context) : null;
    // Apple：iOS 27 上下文菜单顶部那排横排动作——一律 secondaryFill 圆角底、
    // 图标在上文字在下、label 色，不着强调色（「继续」也一样；选中项底色
    // 加深成 fill）。MD3 不变。
    final bool tile = apple || !filled;
    final Color background = apple
        ? (selected ? palette!.fill : palette!.secondaryFill)
        : filled
        ? scheme.primary
        : (selected
              ? scheme.secondaryContainer
              : scheme.surfaceContainerLowest);
    final Color foreground = apple
        ? palette!.label
        : filled
        ? scheme.onPrimary
        : (selected ? scheme.onSecondaryContainer : scheme.onSurface);
    final TextTheme text = Theme.of(context).textTheme;
    final Widget content = !tile
        ? Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              FushiIcon(icon, size: 20, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (text.labelLarge ?? const TextStyle()).copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          )
        : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              FushiIcon(icon, size: 20, color: foreground),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: apple
                    ? TextStyle(
                        fontSize: 12,
                        color: foreground,
                        letterSpacing: 0,
                      )
                    : (text.labelSmall ?? const TextStyle()).copyWith(
                        color: foreground,
                      ),
              ),
            ],
          );
    return FushiTooltip(
      message: label,
      child: FushiPressScale(
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(apple ? 12 : 16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            focusColor: apple
                ? palette!.tertiaryFill
                : (filled ? null : scheme.secondaryContainer),
            hoverColor: apple
                ? palette!.tertiaryFill
                : (filled ? null : scheme.secondaryContainer),
            splashFactory: apple ? NoSplash.splashFactory : null,
            child: Semantics(
              button: true,
              selected: selected,
              label: label,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 工作台入口：主色调的一整行，左图标 + 名称、右边状态副行 + chevron。
/// 带子项（[DialogWorkbenchAction.children]）时是一个子菜单行，否则点了打开
/// 工作台页（[DialogAction.onPressed]）。状态先显示同步给的 [subtitle]，
/// [DialogWorkbenchAction.loadStatus] 回来后换成真实进度。
class _ItemWorkbenchRow extends StatefulWidget {
  const _ItemWorkbenchRow({
    required this.action,
    required this.flyout,
    required this.onOpenPage,
  });

  final DialogAction action;
  final bool flyout;
  final void Function(String, List<DialogAction>, FocusNode) onOpenPage;

  @override
  State<_ItemWorkbenchRow> createState() => _ItemWorkbenchRowState();
}

class _ItemWorkbenchRowState extends State<_ItemWorkbenchRow> {
  String? _status;

  @override
  void initState() {
    super.initState();
    _status = widget.action.subtitle;
    final DialogAction action = widget.action;
    if (action is DialogWorkbenchAction) {
      final Future<String?> Function()? load = action.loadStatus;
      if (load != null) unawaited(_load(load));
    }
  }

  Future<void> _load(Future<String?> Function() load) async {
    final String? status;
    try {
      status = await load();
    } on Object catch (error, stack) {
      // 状态只是副行提示：读不到就保留同步文案，但要留痕，不静默。
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'item menu',
          context: ErrorDescription('loading workbench status'),
        ),
      );
      return;
    }
    if (status != null && mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final DialogAction action = widget.action;
    final List<DialogAction> children = action is DialogWorkbenchAction
        ? action.children
        : const <DialogAction>[];
    final bool emphasized =
        action is! DialogWorkbenchAction || action.emphasized;
    if (children.isNotEmpty) {
      return _ItemSubmenuRow(
        key: const ValueKey<String>('item_menu_workbench'),
        icon: action.icon,
        label: action.label,
        subtitle: _status ?? _itemMenuSummary(children),
        actions: children,
        flyout: widget.flyout,
        onOpenPage: widget.onOpenPage,
        workbench: true,
        workbenchEmphasized: emphasized,
      );
    }
    return _ItemWorkbenchTile(
      key: const ValueKey<String>('item_menu_workbench'),
      icon: action.icon,
      label: action.label,
      status: _status,
      emphasized: emphasized,
      onPressed: action.onPressed,
    );
  }
}

/// 工作台行的外观（主色调容器；[emphasized] 为 false 时是中性底色的同级次要行，
/// 见 [DialogWorkbenchAction.emphasized]）。子菜单形态与直达形态共用。
class _ItemWorkbenchTile extends StatelessWidget {
  const _ItemWorkbenchTile({
    required this.icon,
    required this.label,
    required this.status,
    required this.onPressed,
    this.emphasized = true,
    this.focusNode,
    this.onHover,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? status;
  final VoidCallback onPressed;
  final bool emphasized;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    if (apple) {
      // iOS 27 菜单行：[图标][文字 / 状态副标题][›]。
      final String? status = this.status;
      return MouseRegion(
        onEnter: (_) => onHover?.call(true),
        onExit: (_) => onHover?.call(false),
        child: Semantics(
          button: true,
          label: status == null ? label : '$label, $status',
          excludeSemantics: true,
          child: FushiAppleMenuItemRow(
            icon: icon,
            label: label,
            subtitle: status,
            onPressed: onPressed,
            focusNode: focusNode,
            trailing: FushiIcon(
              FushiIcons.chevronRight,
              size: fushiAppleCompact(context)
                  ? 11 * fushiAppleMacScale(context)
                  : 17,
              color: appleColorsOf(context).label,
            ),
          ),
        ),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiAppleColors? palette = apple ? appleColorsOf(context) : null;
    final Color background = emphasized
        ? palette?.accent.withValues(alpha: 0.14) ?? scheme.primaryContainer
        : palette?.fill ?? scheme.surfaceContainerHighest;
    final Color foreground =
        palette?.label ??
        (emphasized ? scheme.onPrimaryContainer : scheme.onSurface);
    final Color secondary =
        palette?.secondaryLabel ??
        (emphasized
            ? scheme.onPrimaryContainer.withValues(alpha: 0.78)
            : scheme.onSurfaceVariant);
    final TextTheme text = Theme.of(context).textTheme;
    final String? status = this.status;
    return FushiPressScale(
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(apple ? 10 : 14)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          onHover: onHover,
          onTap: onPressed,
          child: Semantics(
            button: true,
            label: status == null ? label : '$label, $status',
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: <Widget>[
                    FushiIcon(icon, size: 20, color: foreground),
                    const SizedBox(width: 10),
                    Text(
                      label,
                      maxLines: 1,
                      style: (text.labelLarge ?? const TextStyle()).copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        status ?? '',
                        key: const ValueKey<String>(
                          'item_menu_workbench_status',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: (text.bodySmall ?? const TextStyle()).copyWith(
                          color: secondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    FushiIcon(
                      FushiIcons.chevronRight,
                      size: 18,
                      color: secondary,
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

/// 开关行（私密 / NSFW）：打开时读当前有效状态，点一下直接拨动并落库，菜单
/// 不关；状态来自继承（合集 / 来源库）拨不掉时，点行打开完整的说明对话框。
class _ItemToggleRow extends StatefulWidget {
  const _ItemToggleRow({required this.action, super.key});

  final DialogToggleAction action;

  @override
  State<_ItemToggleRow> createState() => _ItemToggleRowState();
}

class _ItemToggleRowState extends State<_ItemToggleRow> {
  ItemMenuToggleState? _state;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ItemMenuToggleState state;
    try {
      state = await widget.action.loadState();
    } on Object catch (error, stack) {
      // 读不到当前状态：开关保持未知（不可拨），点行改走完整对话框（它会明示
      // 读取失败并给重试）。
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'item menu',
          context: ErrorDescription('loading ${widget.action.label} state'),
        ),
      );
      return;
    }
    if (mounted) setState(() => _state = state);
  }

  Future<void> _toggle() async {
    final ItemMenuToggleState? state = _state;
    if (state == null || state.locked) {
      widget.action.onPressed();
      return;
    }
    if (_writing) return;
    final bool next = !state.value;
    setState(() {
      _writing = true;
      _state = (value: next, locked: false);
    });
    try {
      await widget.action.onChanged(next);
    } on Object {
      // 写失败：onChanged 自己给了错误提示，这里把开关拨回去。
      if (mounted) setState(() => _state = state);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ItemMenuToggleState? state = _state;
    final bool on = state?.value ?? false;
    if (isGlassDesign(context)) {
      // iOS 菜单的开关项：行首 ✓ 表示开着，不放开关控件。
      return Semantics(
        checked: state == null ? null : on,
        child: FushiAppleMenuItemRow(
          key: ValueKey<String>('item_menu_toggle_${widget.action.label}'),
          icon: widget.action.icon,
          label: widget.action.label,
          selected: on,
          checkColumn: true,
          onPressed: () => unawaited(_toggle()),
        ),
      );
    }
    return Semantics(
      toggled: state == null ? null : on,
      child: _ContextMenuRow(
        icon: widget.action.icon,
        label: widget.action.label,
        onPressed: () => unawaited(_toggle()),
        trailing: ExcludeFocus(
          child: IgnorePointer(
            child: SizedBox(
              height: 24,
              child: FittedBox(
                child: FushiSwitch.adaptive(
                  key: ValueKey<String>(
                    'item_menu_toggle_${widget.action.label}',
                  ),
                  value: on,
                  onChanged: state == null || state.locked ? null : (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 下钻页顶部的返回行。
class _ItemMenuBackRow extends StatelessWidget {
  const _ItemMenuBackRow({required this.title, required this.onPressed});

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ContextMenuRow(
      key: const ValueKey<String>('item_menu_back'),
      icon: FushiIcons.chevronLeft,
      label: title,
      onPressed: onPressed,
      emphasized: true,
      autofocus: true,
    );
  }
}

/// 子菜单行（「更多 ›」「编辑信息 ›」「排序 ›」、带子项的工作台）。
///
/// [flyout]：悬停、点按、Enter 或 → 打开紧贴本行的浮出二级菜单（右侧放不下时
/// 翻到左侧，纵向夹在屏幕内），焦点移进二级菜单首项；← / Esc 收起并把焦点还给
/// 本行。否则（手机底部面板）点了在面板内下钻。
class _ItemSubmenuRow extends StatefulWidget {
  const _ItemSubmenuRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.actions,
    required this.flyout,
    required this.onOpenPage,
    this.workbench = false,
    this.workbenchEmphasized = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final List<DialogAction> actions;
  final bool flyout;
  final void Function(String, List<DialogAction>, FocusNode) onOpenPage;

  /// 画成工作台外观（[_ItemWorkbenchTile]）而不是普通菜单行。
  final bool workbench;

  /// [workbench] 时传给 [_ItemWorkbenchTile.emphasized]。
  final bool workbenchEmphasized;

  @override
  State<_ItemSubmenuRow> createState() => _ItemSubmenuRowState();
}

class _ItemSubmenuRowState extends State<_ItemSubmenuRow> {
  final OverlayPortalController _portal = OverlayPortalController();
  late final FocusNode _rowFocus = FocusNode(
    debugLabel: 'item_menu_submenu_row ${widget.label}',
  );
  final FocusScopeNode _menuScope = FocusScopeNode(
    debugLabel: 'item_menu_submenu',
  );
  bool _hoverRow = false;
  bool _hoverMenu = false;

  static const double _width = 248;

  /// 二级菜单与本行的水平间隙。这条缝算在二级菜单的悬停区里（见
  /// [_buildPositionedSubmenu] 里包住二级菜单的 [MouseRegion]），指针从行横移到二级菜单全程至少落在其中一块上。
  static const double _gap = 4;

  /// 二级菜单的内边距：首项与本行顶边对齐，所以整体上提这么多。
  static const double _padding = 6;

  @override
  void dispose() {
    _rowFocus.dispose();
    _menuScope.dispose();
    super.dispose();
  }

  void _activate() {
    if (!widget.flyout) {
      widget.onOpenPage(widget.label, widget.actions, _rowFocus);
      return;
    }
    _open(focusFirst: true);
  }

  void _open({bool focusFirst = false}) {
    if (!_portal.isShowing) setState(_portal.show);
    if (focusFirst) {
      // 二级菜单这一帧才挂进 Overlay：等它建好再把焦点移进去。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _menuScope.requestFocus();
        _menuScope.nextFocus();
      });
    }
  }

  void _close({bool refocusRow = false}) {
    if (_portal.isShowing) setState(_portal.hide);
    if (refocusRow) _rowFocus.requestFocus();
  }

  void _syncHover() {
    // 行与二级菜单的悬停区首尾相接（缝归二级菜单），但同一次指针移动里「离开行」
    // 与「进入二级菜单」是先后两个回调：等这一帧的进出事件都到齐再判。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hoverRow || _hoverMenu) {
        _open();
      } else if (!_menuScope.hasFocus) {
        _close();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onHoverRow(bool hovering) {
    if (!widget.flyout) return;
    _hoverRow = hovering;
    _syncHover();
  }

  /// 本行在 Overlay 坐标系里的矩形（二级菜单据此定位）。
  Rect? _rowRect(BuildContext overlayContext) {
    final RenderObject? row = context.findRenderObject();
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    if (row is! RenderBox || !row.hasSize || overlay is! RenderBox) {
      return null;
    }
    return row.localToGlobal(Offset.zero, ancestor: overlay) & row.size;
  }

  @override
  Widget build(BuildContext context) {
    final Color chevron = isGlassDesign(context)
        ? appleColorsOf(context).label
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final Widget row = widget.workbench
        ? _ItemWorkbenchTile(
            icon: widget.icon,
            label: widget.label,
            status: widget.subtitle,
            emphasized: widget.workbenchEmphasized,
            onPressed: _activate,
            focusNode: _rowFocus,
            onHover: _onHoverRow,
          )
        : _ContextMenuRow(
            icon: widget.icon,
            label: widget.label,
            subtitle: widget.subtitle,
            focusNode: _rowFocus,
            onPressed: _activate,
            onHover: _onHoverRow,
            trailing: FushiIcon(
              FushiIcons.chevronRight,
              size: 18,
              color: chevron,
            ),
          );
    final Widget anchored = Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowRight): ActivateIntent(),
      },
      child: row,
    );
    if (!widget.flyout) return anchored;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext overlayContext) {
        final Rect? rect = _rowRect(overlayContext);
        if (rect == null) return const SizedBox.shrink();
        final EdgeInsets safe = MediaQuery.paddingOf(overlayContext);
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              _buildPositionedSubmenu(
                overlayContext,
                rect,
                safe,
                _SubmenuLayout.opensLeft(
                  row: rect,
                  overlay: constraints.biggest,
                  padding: safe,
                  width: _width + _gap,
                ),
              ),
        );
      },
      child: anchored,
    );
  }

  /// 按 [flip] 摆好的二级菜单（含悬停区与键盘导航）。
  Widget _buildPositionedSubmenu(
    BuildContext overlayContext,
    Rect rect,
    EdgeInsets safe,
    bool flip,
  ) {
    return CustomSingleChildLayout(
      delegate: _SubmenuLayout(
        row: rect,
        padding: safe,
        flip: flip,
        inset: _padding,
      ),
      // 二级菜单离本行留 [_gap] 的缝，但这条缝必须仍是二级菜单的悬停区：缝若
      // 落在悬停区外，指针横移时只要有一次事件落进缝里，行与二级菜单就都判为
      // 未悬停，二级菜单被收起、再也移不进去（反馈 iEhadpzweB，BUG-4926）。
      // 所以缝做成二级菜单 [MouseRegion] 里朝向本行的透明内边距，定位时二级
      // 菜单与本行首尾相接。
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.opaque,
        onEnter: (_) {
          _hoverMenu = true;
          _syncHover();
        },
        onExit: (_) {
          _hoverMenu = false;
          _syncHover();
        },
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
            SingleActivator(LogicalKeyboardKey.arrowLeft): DismissIntent(),
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (DismissIntent intent) {
                  _close(refocusRow: true);
                  return null;
                },
              ),
            },
            child: Padding(
              padding: EdgeInsets.only(
                left: flip ? 0 : _gap,
                right: flip ? _gap : 0,
              ),
              child: FocusScope(
                node: _menuScope,
                child: _buildSubmenu(overlayContext),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubmenu(BuildContext context) {
    return SizedBox(
      key: ValueKey<String>('item_menu_submenu_${widget.label}'),
      width: _width,
      child: _ItemMenuSurface(
        child: SingleChildScrollView(
          child: FushiEntranceScope(
            child: Padding(
              padding: const EdgeInsets.all(_padding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < widget.actions.length; i++)
                    FushiStaggeredEntrance(
                      index: i,
                      child: _ContextMenuRow(
                        icon: widget.actions[i].icon,
                        label: widget.actions[i].label,
                        subtitle: widget.actions[i].subtitle,
                        onPressed: widget.actions[i].onPressed,
                        selected: widget.actions[i].selected,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 二级菜单定位：默认贴在本行右侧、首项与本行顶边对齐；右侧放不下翻到左侧
/// （[opensLeft]）；纵向夹在屏幕安全区内（放不下时整体上移，而不是伸出屏幕外），
/// 高度上限是安全区高度（极端情况下二级菜单自己滚动）。子节点与本行首尾相接，
/// 视觉上的缝由子节点自己朝向本行的内边距给出（缝要算进二级菜单的悬停区）。
class _SubmenuLayout extends SingleChildLayoutDelegate {
  const _SubmenuLayout({
    required this.row,
    required this.padding,
    required this.flip,
    required this.inset,
  });

  final Rect row;
  final EdgeInsets padding;

  /// 翻到本行左侧（由 [opensLeft] 判定）。
  final bool flip;
  final double inset;

  static const double _margin = 8;

  /// 宽 [width]（含缝）的二级菜单贴本行右侧放不下、要翻到左侧时为真。
  static bool opensLeft({
    required Rect row,
    required Size overlay,
    required EdgeInsets padding,
    required double width,
  }) => row.right + width > overlay.width - padding.right - _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double height =
        constraints.maxHeight - padding.vertical - _margin * 2;
    return BoxConstraints(maxHeight: math.max(0, height));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double left = padding.left + _margin;
    final double top = padding.top + _margin;
    final double bottom = size.height - padding.bottom - _margin;
    final double x = flip
        ? math.max(left, row.left - childSize.width)
        : row.right;
    final double y = (row.top - inset).clamp(
      top,
      math.max(top, bottom - childSize.height),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_SubmenuLayout oldDelegate) =>
      row != oldDelegate.row ||
      padding != oldDelegate.padding ||
      flip != oldDelegate.flip;
}
