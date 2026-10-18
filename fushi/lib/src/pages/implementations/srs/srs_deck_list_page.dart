/// 复习模块主页：牌组列表（底栏 / 侧栏「复习」tab，见 `HomeTab.srs`）。
///
/// 每行：牌组名（子牌组前面按层级画细竖线）+ 新卡 / 学习 / 到期三色计数；新卡被自动
/// 缩减时多一行小字。点行进复习；行内菜单：新建子牌组 / 改名 / 牌组设置 / 删除（默认
/// 牌组不可删；空着又没有子牌组时不显示，见 [srsVisibleDecks]）。
/// 顶栏动作默认平铺、放不下才按优先级收进「⋯」（MD3 = [FushiFloatingTopBar] 的
/// 自适应溢出；Apple = 导航栏动作，由 [FushiPageHeader] 自己收）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_backups_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_types_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';

/// 行内菜单动作。
enum _DeckAction { addChild, rename, settings, delete }

class SrsDeckListPage extends ConsumerStatefulWidget {
  const SrsDeckListPage({super.key});

  @override
  ConsumerState<SrsDeckListPage> createState() => _SrsDeckListPageState();
}

class _SrsDeckListPageState extends ConsumerState<SrsDeckListPage> {
  Future<T?> _push<T>(Widget Function(BuildContext context) builder) async {
    final T? result = await Navigator.of(
      context,
    ).push<T>(adaptivePageRoute<T>(context: context, builder: builder));
    // 子页里写过数据（复习 / 编辑 / 设置）：回来时重读计数。
    if (mounted) bumpSrsRevision(ref);
    return result;
  }

  Future<void> _addNote({String? deckId}) =>
      _push<void>((_) => SrsNoteEditorPage(initialDeckId: deckId));

  Future<void> _openBrowse() => _push<void>(
    (_) => const SrsBrowsePage(
      onChangeNoteType: showSrsChangeNoteTypeFlow,
      onMigrateToFushiCard: srsMigrateNotesToFushiCard,
    ),
  );

  Future<void> _openNoteTypes() => _push<void>((_) => const SrsNoteTypesPage());

  Future<void> _openConflicts() => _push<void>((_) => const SrsConflictsPage());

  Future<void> _openReview(SrsDeckSummary deck) => _push<void>(
    (_) => SrsReviewPage(deckId: deck.deck.id, deckName: deck.fullName),
  );

  Future<void> _createDeck({String? parentId}) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: parentId == null ? t.srs_deck_new : t.srs_deck_new_child,
      labelText: t.srs_deck_name,
      icon: FushiIcons.libraryAdd,
      validator: _validateDeckName,
    );
    if (name == null || !mounted) return;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.createDeck(name, parentId: parentId);
    if (mounted) bumpSrsRevision(ref);
  }

  /// 「::」是层级分隔符（导入 / AnkiConnect 按它拆路径），名字里不能出现。
  String? _validateDeckName(String value) =>
      value.contains('::') ? t.srs_deck_name_invalid : null;

  Future<void> _rename(SrsDeckSummary deck) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.srs_deck_rename,
      labelText: t.srs_deck_name,
      initialValue: deck.deck.name,
      icon: FushiIcons.rename,
      validator: _validateDeckName,
    );
    if (name == null || name == deck.deck.name || !mounted) return;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.editField(
      SrsEntityKind.deck,
      deck.deck.id,
      SrsFieldKeys.name,
      name,
    );
    if (mounted) bumpSrsRevision(ref);
  }

  Future<void> _delete(SrsDeckSummary deck) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.srs_deck_delete,
      message: t.srs_deck_delete_confirm(name: deck.fullName),
      confirmLabel: t.srs_deck_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.deleteDeck(deck.deck.id);
    if (mounted) bumpSrsRevision(ref);
  }

  /// 收起 / 展开子牌组：写进牌组本身（Anki deck collapsed），随同步到其它设备。
  Future<void> _setCollapsed(SrsDeckSummary deck, bool collapsed) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.setDeckCollapsed(deck.deck.id, collapsed);
    if (mounted) bumpSrsRevision(ref);
  }

  void _onDeckAction(SrsDeckSummary deck, _DeckAction action) {
    switch (action) {
      case _DeckAction.addChild:
        srsRunLogged(
          'SrsDeckList.addChild',
          () => _createDeck(parentId: deck.deck.id),
        );
      case _DeckAction.rename:
        srsRunLogged('SrsDeckList.rename', () => _rename(deck));
      case _DeckAction.settings:
        srsRunLogged(
          'SrsDeckList.settings',
          () => _push<void>((_) => SrsDeckSettingsPage(deckId: deck.deck.id)),
        );
      case _DeckAction.delete:
        srsRunLogged('SrsDeckList.delete', () => _delete(deck));
    }
  }

  /// 复习的「今天」从几点开始：与统计页共用日界（stats_day_reset_hour）。
  Future<void> _showDayBoundary() async {
    final int hour = ref.read(appProvider).statDayResetHour;
    await showFushiConfirmDialog(
      context: context,
      title: t.srs_day_boundary_title,
      message: t.srs_day_boundary_body(hour: hour),
      icon: FushiIcons.schedule,
      confirmLabel: t.dialog_ok,
      cancelLabel: t.cancel,
    );
  }

  /// 低优先级动作（MD3 顶栏的 [FushiFloatingTopBar.overflow]：宽度够平铺、不够收进「⋯」；
  /// Apple 导航栏由 [FushiPageHeader] 自己收）。
  List<FushiToolbarItem> _secondaryItems() => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_sync_now'),
      icon: FushiIcons.sync,
      label: t.srs_sync_now,
      onPressed: () => srsRunLogged(
        'SrsDeckList.syncNow',
        () => openSrsSyncNow(ref.read(srsAppRuntimeProvider)?.syncNow),
      ),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_history_import'),
      icon: FushiIcons.history,
      label: t.srs_history_import,
      onPressed: () => srsRunLogged(
        'SrsDeckList.historyImport',
        () => openSrsMinedHistoryImport(context, ref),
      ),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_export_apkg'),
      icon: FushiIcons.upload,
      label: t.srs_export_apkg,
      onPressed: () =>
          srsRunLogged('SrsDeckList.export', () => openSrsExport(context, ref)),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_note_types'),
      icon: FushiIcons.ankiCard,
      label: t.srs_note_types_title,
      onPressed: () => srsRunLogged('SrsDeckList.noteTypes', _openNoteTypes),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_backups'),
      icon: FushiIcons.backup,
      label: t.srs_backup_title,
      onPressed: () => srsRunLogged(
        'SrsDeckList.backups',
        () => _push<void>((_) => const SrsBackupsPage()),
      ),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_day_boundary'),
      icon: FushiIcons.schedule,
      label: t.srs_day_boundary_title,
      onPressed: () => srsRunLogged('SrsDeckList.day', _showDayBoundary),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final AsyncValue<SrsDeckListData?> data = ref.watch(srsDeckListProvider);
    final int conflicts = data.valueOrNull?.conflictCount ?? 0;
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.nav_srs,
      header: apple ? null : _buildTopBar(context, conflicts),
      actions: apple ? _buildAppleActions(conflicts) : const <Widget>[],
      body: Builder(
        builder: (BuildContext context) => AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: KeyedSubtree(
            key: ValueKey<String>(
              data.isLoading && !data.hasValue
                  ? 'loading'
                  : data.hasError
                  ? 'error'
                  : 'list',
            ),
            child: _buildBody(context, data),
          ),
        ),
      ),
    );
  }

  List<FushiToolbarItem> _primaryItems(int conflicts) => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_add_note'),
      icon: FushiIcons.add,
      label: t.srs_note_add,
      onPressed: () => srsRunLogged('SrsDeckList.addNote', _addNote),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_browse'),
      icon: FushiIcons.search,
      label: t.srs_browse_title,
      onPressed: () => srsRunLogged('SrsDeckList.browse', _openBrowse),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_conflicts'),
      icon: conflicts > 0 ? FushiIcons.syncProblem : FushiIcons.cloudSync,
      label: conflicts > 0
          ? t.srs_conflicts_title_count(n: conflicts)
          : t.srs_conflicts_title,
      // 有冲突时以选中态底色充当角标，一眼可见。
      selected: conflicts > 0,
      onPressed: () => srsRunLogged('SrsDeckList.conflicts', _openConflicts),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_new_deck'),
      icon: FushiIcons.libraryAdd,
      label: t.srs_deck_new,
      onPressed: () => srsRunLogged('SrsDeckList.newDeck', _createDeck),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_import'),
      icon: FushiIcons.importFile,
      label: t.srs_import,
      onPressed: () =>
          srsRunLogged('SrsDeckList.import', () => openSrsImport(context, ref)),
    ),
  ];

  Widget _buildTopBar(BuildContext context, int conflicts) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final bool canPop = ModalRoute.of(context)?.isFirst == false;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.nav_srs,
        leading: <FushiToolbarItem>[
          if (canPop && navigator != null)
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_primaryItems(conflicts)],
        overflow: _secondaryItems(),
      ),
    );
  }

  List<Widget> _buildAppleActions(int conflicts) => <Widget>[
    for (final FushiToolbarItem item in _primaryItems(conflicts))
      FushiIconButton(
        key: item.key,
        icon: item.icon,
        tooltip: item.label,
        badge:
            item.key == const ValueKey<String>('srs_conflicts') &&
            conflicts > 0,
        onTap: item.onPressed,
      ),
    for (final FushiToolbarItem item in _secondaryItems())
      FushiIconButton(
        key: item.key,
        icon: item.icon,
        tooltip: item.label,
        onTap: item.onPressed,
      ),
  ];

  Widget _buildBody(BuildContext context, AsyncValue<SrsDeckListData?> data) {
    if (data.hasError && !data.hasValue) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: '${data.error}',
            action: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('srs-load-retry'),
              onPressed: () => ref.invalidate(srsStoreProvider),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.retry),
            ),
          ),
        ),
      );
    }
    final SrsDeckListData? list = data.valueOrNull;
    if (list == null) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    return _DeckList(
      data: list,
      onOpen: (SrsDeckSummary d) =>
          srsRunLogged('SrsDeckList.review', () => _openReview(d)),
      onAction: _onDeckAction,
      onAddFirst: () => srsRunLogged('SrsDeckList.addFirst', _addNote),
      onSetCollapsed: _setCollapsed,
    );
  }
}

class _DeckList extends StatefulWidget {
  const _DeckList({
    required this.data,
    required this.onOpen,
    required this.onAction,
    required this.onAddFirst,
    required this.onSetCollapsed,
  });

  final SrsDeckListData data;
  final void Function(SrsDeckSummary deck) onOpen;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;
  final VoidCallback onAddFirst;

  /// 收起 / 展开一个牌组（写进牌组本身，随同步）。
  final Future<void> Function(SrsDeckSummary deck, bool collapsed)
  onSetCollapsed;

  @override
  State<_DeckList> createState() => _DeckListState();
}

class _DeckListState extends State<_DeckList> {
  /// 本机刚点过、数据还没重读回来的折叠状态：先按它动画，不等写库往返。
  final Map<String, bool> _pending = <String, bool>{};

  @override
  void didUpdateWidget(_DeckList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.data, widget.data)) return;
    // 重读回来的数据已经反映了这次修改：撤掉本地覆盖。
    for (final SrsDeckSummary d in widget.data.decks) {
      if (_pending[d.deck.id] == d.deck.collapsed) _pending.remove(d.deck.id);
    }
  }

  bool _collapsed(SrsDeckSummary d) => _pending[d.deck.id] ?? d.deck.collapsed;

  void _setCollapsed(SrsDeckSummary d, bool collapsed) {
    if (_collapsed(d) == collapsed) return;
    setState(() => _pending[d.deck.id] = collapsed);
    srsRunLogged(
      'SrsDeckList.collapse',
      () => widget.onSetCollapsed(d, collapsed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsDeckSummary> decks = widget.data.decks;
    final Map<String, SrsDeckSummary> byId = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in decks) d.deck.id: d,
    };
    final Set<String> parents = <String>{
      for (final SrsDeckSummary d in decks)
        if (d.parentId != null) d.parentId!,
    };
    // 任一祖先收起 → 本行隐藏（Anki：收起时隐藏全部后代）。
    bool hidden(SrsDeckSummary d) {
      String? p = d.parentId;
      int guard = 0;
      while (p != null && guard++ < 64) {
        final SrsDeckSummary? parent = byId[p];
        if (parent == null) return false;
        if (_collapsed(parent)) return true;
        p = parent.parentId;
      }
      return false;
    }

    final List<bool> visible = <bool>[
      for (final SrsDeckSummary d in decks) !hidden(d),
    ];
    final int visibleCount = visible.where((bool v) => v).length;
    final List<Widget> items = <Widget>[
      if (!widget.data.store.canSchedule)
        FushiCard(
          key: const ValueKey<String>('srs-engine-missing'),
          tone: FushiCardTone.error,
          child: Row(
            spacing: tokens.spacing.gap * 1.5,
            children: <Widget>[
              const FushiIcon(FushiIcons.warning),
              Expanded(child: Text(t.srs_engine_unavailable)),
            ],
          ),
        ),
      if (widget.data.totalCards == 0)
        FushiCard(
          key: const ValueKey<String>('srs-empty'),
          tone: FushiCardTone.primary,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              Text(
                t.srs_empty_title,
                style: context.fushiType.titleMediumEmphasized,
              ),
              Text(t.srs_empty_body),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FushiFilledButton.icon(
                  key: const ValueKey<String>('srs-add-first'),
                  onPressed: widget.onAddFirst,
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(t.srs_empty_action),
                ),
              ),
            ],
          ),
        ),
    ];
    final int firstDeckItem = items.length;
    int shown = 0;
    for (int i = 0; i < decks.length; i++) {
      final SrsDeckSummary d = decks[i];
      // 分段卡的圆角按「可见行」里的位置算；隐藏行收成 0 高，位置无所谓。
      final int index = visible[i] ? shown++ : shown;
      items.add(
        _DeckReveal(
          key: ValueKey<String>('srs-deck-${d.deck.id}'),
          visible: visible[i],
          child: _DeckRow(
            deck: d,
            index: index,
            count: visibleCount,
            isDefault: d.deck.id == widget.data.store.defaultDeckId,
            hasTree: parents.isNotEmpty,
            hasChildren: parents.contains(d.deck.id),
            collapsed: _collapsed(d),
            onSetCollapsed: (bool c) => _setCollapsed(d, c),
            onOpen: widget.onOpen,
            onAction: widget.onAction,
          ),
        ),
      );
    }
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            // 正文滚到浮动页头底下：顶部让出「状态栏 + 页头」。
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: items.length,
        // 牌组行是一组分段卡（行间 2px，由 FushiGroupedListItem 自己画），横幅与
        // 牌组之间才留卡片间距。
        separatorBuilder: (BuildContext context, int index) => SizedBox(
          height: index >= firstDeckItem ? 0 : tokens.spacing.gap * 1.5,
        ),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

/// 子牌组随父牌组收起 / 展开：尺寸过渡 + 淡入淡出；收起后不进焦点遍历、不吃点击、不读屏。
class _DeckReveal extends StatefulWidget {
  const _DeckReveal({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_DeckReveal> createState() => _DeckRevealState();
}

class _DeckRevealState extends State<_DeckReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: FushiMotion.enter,
    reverseCurve: FushiMotion.exit,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = fushiMotionDuration(context, FushiMotion.medium);
    _controller.reverseDuration = fushiMotionDuration(
      context,
      FushiMotion.longReverse,
    );
  }

  @override
  void didUpdateWidget(_DeckReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      unawaited(_controller.forward());
    } else {
      unawaited(_controller.reverse());
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool hidden = !widget.visible;
    return ExcludeFocus(
      excluding: hidden,
      child: IgnorePointer(
        ignoring: hidden,
        child: ExcludeSemantics(
          excluding: hidden,
          child: SizeTransition(
            sizeFactor: _curve,
            axisAlignment: -1,
            child: FadeTransition(opacity: _curve, child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _DeckRow extends StatelessWidget {
  const _DeckRow({
    required this.deck,
    required this.index,
    required this.count,
    required this.isDefault,
    required this.hasTree,
    required this.hasChildren,
    required this.collapsed,
    required this.onSetCollapsed,
    required this.onOpen,
    required this.onAction,
  });

  final SrsDeckSummary deck;
  final int index;
  final int count;
  final bool isDefault;

  /// 列表里有任何父子层级：所有行都留出箭头位，同层的图标对齐。
  final bool hasTree;
  final bool hasChildren;
  final bool collapsed;
  final ValueChanged<bool> onSetCollapsed;
  final void Function(SrsDeckSummary deck) onOpen;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;

  /// ← 收起、→ 展开：只在有子牌组且状态会变时返回目标值；否则 null，照常交给方向焦点移动。
  bool? _collapseTargetFor({required bool left}) {
    if (!hasChildren) return null;
    if (left && !collapsed) return true;
    if (!left && collapsed) return false;
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // 菜单键 / Shift+F10：窄屏没有「⋯」按钮时键盘也能打开牌组菜单。
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.contextMenu ||
            (event.logicalKey == LogicalKeyboardKey.f10 &&
                HardwareKeyboard.instance.isShiftPressed))) {
      final BuildContext? rowContext = node.context;
      if (rowContext != null) unawaited(_showMenuFor(rowContext));
      return KeyEventResult.handled;
    }
    final bool left = event.logicalKey == LogicalKeyboardKey.arrowLeft;
    final bool right = event.logicalKey == LogicalKeyboardKey.arrowRight;
    if (!left && !right) return KeyEventResult.ignored;
    final bool? target = _collapseTargetFor(left: left);
    if (target == null) return KeyEventResult.ignored;
    onSetCollapsed(target);
    return KeyEventResult.handled;
  }

  /// 行宽低于此值按窄屏（手机竖屏）排：宽屏排法的行首（缩进 + 48 箭头 + 40 图标）
  /// 与行尾（三计数 + ⋮）合计 ~280，标题被挤到只剩一两个字甚至 0 宽（真机实拍：
  /// 三级子牌组名完全不显示，一屏只放得下 8 行）。窄屏排法对齐 AnkiDroid 牌组列表
  /// 的密度：
  /// - 行高收到 48（单行名），无装饰图标、缩进封顶；
  /// - 三计数收成紧凑的一小块（窄数字列、小间距）；
  /// - 不画行尾「⋯」：长按 / 右键 / 菜单键弹出同一份牌组菜单（AnkiDroid 同款）；
  /// - 牌组名可折两行，永远优先拿宽度。
  static const double compactBelow = 480;

  /// 行首：层级细竖线（[SrsDeckIndentGuides]）+ 展开 / 收起箭头。有子牌组时整块都是
  /// 展开 / 收起的命中区（用户 2026-10-16：只有箭头那 48 方框能折叠，旁边的留白一点
  /// 就开始复习，太容易误触）；没有子牌组的行首照旧跟随整行打开牌组。
  ///
  /// 行首不放牌组图标：窄屏上图标 + 每层一整格缩进会把名字挤没（三级以下只剩数字），
  /// 层级改由细竖线表示，名字拿到尽量多的宽度。没有层级也没有箭头时行首为空。
  Widget? _leading({required _LeadingProbe probe}) {
    if (deck.depth == 0 && !hasTree) return null;
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (deck.depth > 0)
          SrsDeckIndentGuides(
            key: ValueKey<String>('srs-deck-indent-${deck.deck.id}'),
            depth: deck.depth,
            active: deck.reviewCount + deck.learnCount > 0,
          ),
        if (hasTree)
          _CollapseToggle(
            deckId: deck.deck.id,
            visible: hasChildren,
            collapsed: collapsed,
            onPressed: () => onSetCollapsed(!collapsed),
          ),
      ],
    );
    if (!hasChildren) return row;
    return Builder(
      key: ValueKey<String>('srs-deck-leading-toggle-${deck.deck.id}'),
      builder: (BuildContext leadingContext) {
        probe.leading = leadingContext;
        return row;
      },
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) =>
        _buildRow(context, compact: constraints.maxWidth < compactBelow),
  );

  List<PopupMenuEntry<_DeckAction>> _menuItems() =>
      <PopupMenuEntry<_DeckAction>>[
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.addChild,
          child: Text(t.srs_deck_new_child),
        ),
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.rename,
          child: Text(t.srs_deck_rename),
        ),
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.settings,
          child: Text(t.srs_deck_settings),
        ),
        if (!isDefault)
          PopupMenuItem<_DeckAction>(
            value: _DeckAction.delete,
            child: Text(t.srs_deck_delete),
          ),
      ];

  /// 窄屏没有行尾「⋯」：长按 / 右键 / 菜单键在行的位置弹出同一份菜单。
  Future<void> _showMenuFor(BuildContext rowContext, {Offset? at}) async {
    final RenderBox? box = rowContext.findRenderObject() as RenderBox?;
    final RenderBox? overlay =
        Navigator.of(rowContext).overlay?.context.findRenderObject()
            as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final Rect rowRect =
        box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final Offset anchor = at ?? rowRect.centerRight;
    final _DeckAction? picked = await showFushiMenu<_DeckAction>(
      context: rowContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, rowRect.top, 0, rowRect.height),
        Offset.zero & overlay.size,
      ),
      semanticLabel: t.srs_deck_menu,
      items: _menuItems(),
    );
    if (picked != null) onAction(deck, picked);
  }

  Widget _buildRow(BuildContext context, {required bool compact}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? note = srsNewBudgetNote(deck.newBudget);
    final _LeadingProbe probe = _LeadingProbe();
    // 有子牌组时，从行的最左缘到行首块（缩进 + 箭头 + 图标）的右缘、整行高度都是
    // 展开 / 收起（用户 2026-10-17：箭头左边的行内留白一点就开始复习，仍太容易误触）。
    // 按下点落在这片区域就折叠，否则打开牌组；键盘 Enter 没有按下点，照常打开。
    void onRowTap() {
      if (hasChildren && probe.downInLeading()) {
        onSetCollapsed(!collapsed);
      } else {
        onOpen(deck);
      }
    }

    return Actions(
      // 桌面手柄轮询路径先向焦点处派发 GamepadButtonIntent：D-pad ←/→ 同键盘。
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: _DeckCollapseGamepadAction(this),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Builder(
          builder: (BuildContext rowContext) => Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (PointerDownEvent e) => probe.down = e.position,
            child: FushiPressScale(
              child: FushiGroupedListItem(
                index: index,
                count: count,
                onTap: onRowTap,
                onLongPress: compact
                    ? () => unawaited(_showMenuFor(rowContext))
                    : null,
                onSecondaryTap: () => unawaited(_showMenuFor(rowContext)),
                child: FushiListItem(
                  // 窄屏紧凑；手机横屏（又宽又矮）也紧凑，一屏多放一两行。
                  density: compact
                      ? FushiListDensity.compact
                      : srsListDensityOf(context),
                  // 窄屏：上下不再额外留白，行高由 48 见方的折叠箭头 / 单行名撑起。
                  padding: compact
                      ? EdgeInsets.symmetric(
                          horizontal: tokens.spacing.rowHorizontal - 4,
                          vertical: tokens.spacing.gap / 4,
                        )
                      : null,
                  minHeight: compact ? kMinInteractiveDimension : null,
                  leading: _leading(probe: probe),
                  // 窄屏放宽到两行：列表高度自由，长牌组名换行而不是只剩省略号。
                  titleMaxLines: compact ? 2 : 1,
                  // 窄屏不包完整路径的提示气泡：触屏上长按会先被气泡吃掉，弹不出
                  // 牌组菜单；名字本身可折两行完整显示，层级由缩进表达。
                  title: compact
                      ? Text(deck.deck.name)
                      : FushiTooltip(
                          message: deck.fullName,
                          child: Text(deck.deck.name),
                        ),
                  subtitle: note == null ? null : Text(note),
                  trailing: compact
                      ? SrsCountTriple(
                          dense: true,
                          tight: true,
                          newCount: deck.newCount,
                          learnCount: deck.learnCount,
                          reviewCount: deck.reviewCount,
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: tokens.spacing.gap / 2,
                          children: <Widget>[
                            SrsCountTriple(
                              newCount: deck.newCount,
                              learnCount: deck.learnCount,
                              reviewCount: deck.reviewCount,
                            ),
                            FushiPopupMenuButton<_DeckAction>(
                              tooltip: t.srs_deck_menu,
                              icon: const FushiIcon(FushiIcons.more),
                              onSelected: (_DeckAction a) => onAction(deck, a),
                              itemBuilder: (BuildContext context) =>
                                  _menuItems(),
                            ),
                          ],
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

/// 牌组行一次构建内共享的命中探针：记下按下点（全局坐标）与行首块的 context，点按
/// 时判断按下点是否在「行左缘 → 行首块右缘」这片折叠区里。
class _LeadingProbe {
  Offset? down;
  BuildContext? leading;

  bool downInLeading() {
    final Offset? p = down;
    final RenderObject? box = leading?.findRenderObject();
    if (p == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return false;
    }
    final double right = box.localToGlobal(Offset(box.size.width, 0)).dx;
    return p.dx <= right;
  }
}

/// D-pad ←/→ 收起 / 展开；状态不会变时 disabled，[Actions.maybeInvoke] 继续往上找，
/// 最终落回通用方向焦点移动。
class _DeckCollapseGamepadAction extends Action<GamepadButtonIntent> {
  _DeckCollapseGamepadAction(this._row);

  final _DeckRow _row;

  bool? _target(GamepadButtonIntent intent) => switch (intent.button) {
    GamepadButton.dpadLeft => _row._collapseTargetFor(left: true),
    GamepadButton.dpadRight => _row._collapseTargetFor(left: false),
    _ => null,
  };

  @override
  bool isEnabled(GamepadButtonIntent intent) => _target(intent) != null;

  @override
  Object? invoke(GamepadButtonIntent intent) {
    _row.onSetCollapsed(_target(intent)!);
    return true;
  }
}

/// 行首的展开 / 收起箭头：命中区 48 见方，展开时转 90°（指向下）。没有子牌组的行只占位，保持对齐。
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.deckId,
    required this.visible,
    required this.collapsed,
    required this.onPressed,
  });

  static const double _extent = 48;

  final String deckId;
  final bool visible;
  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.square(dimension: _extent);
    final String label = collapsed ? t.srs_deck_expand : t.srs_deck_collapse;
    return Semantics(
      expanded: !collapsed,
      child: GestureDetector(
        // 箭头之外、48 方框之内的点按也算（Apple 图标钮自身命中区只有 36 / 44）。
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: _extent,
          child: Center(
            child: AnimatedRotation(
              turns: collapsed ? 0 : 0.25,
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: FushiIconButton(
                key: ValueKey<String>('srs-deck-toggle-$deckId'),
                icon: FushiIcons.chevronRight,
                tooltip: label,
                isWideTapArea: true,
                onTap: onPressed,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 子牌组的层级指示：每深一层一条细竖线（取代原来的「图标 + 每层一整格缩进」）。
///
/// 每层只占 [step] 宽，四级子牌组也只让出约 30 逻辑像素，名字照样看得见；最深那条
/// 在牌组有学习 / 到期卡时用主色（接替原来图标的着色信号）。
@visibleForTesting
class SrsDeckIndentGuides extends StatelessWidget {
  const SrsDeckIndentGuides({
    super.key,
    required this.depth,
    required this.active,
  });

  /// 每层的水平步长。
  static const double step = 10;

  /// 竖线粗细。
  static const double stroke = 2;

  /// 竖线高度（单行列表行内容区 40 里留上下余量）。
  static const double height = 28;

  final int depth;
  final bool active;

  /// 总宽：前 depth-1 层各占一步，最后一层只占线宽（后面 FushiListItem 自带行首间距）。
  static double widthFor(int depth) =>
      depth <= 0 ? 0 : (depth - 1) * step + stroke;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: widthFor(depth),
      height: height,
      child: Stack(
        children: <Widget>[
          for (int level = 0; level < depth; level++)
            PositionedDirectional(
              start: level * step,
              top: 0,
              bottom: 0,
              width: stroke,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: level == depth - 1 && active
                      ? scheme.primary
                      : scheme.outlineVariant,
                  borderRadius: const BorderRadius.all(
                    Radius.circular(stroke / 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
