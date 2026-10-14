/// 复习模块主页：牌组列表（底栏 / 侧栏「复习」tab，见 `HomeTab.srs`）。
///
/// 每行：牌组名按层级缩进 + 新卡 / 学习 / 到期三色计数；新卡被自动缩减时多一行
/// 小字。点行进复习；行内菜单：新建子牌组 / 改名 / 牌组设置 / 删除（默认牌组不可删）。
/// 顶栏动作默认平铺、放不下才按优先级收进「⋯」（MD3 = [FushiFloatingTopBar] 的
/// 自适应溢出；Apple = 导航栏动作，由 [FushiPageHeader] 自己收）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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

  Future<void> _openBrowse() => _push<void>((_) => const SrsBrowsePage());

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
        overflow: <FushiToolbarItem>[
          FushiToolbarItem(
            key: const ValueKey<String>('srs_day_boundary'),
            icon: FushiIcons.schedule,
            label: t.srs_day_boundary_title,
            onPressed: () => srsRunLogged('SrsDeckList.day', _showDayBoundary),
          ),
        ],
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
    FushiIconButton(
      key: const ValueKey<String>('srs_day_boundary'),
      icon: FushiIcons.schedule,
      tooltip: t.srs_day_boundary_title,
      onTap: () => srsRunLogged('SrsDeckList.day', _showDayBoundary),
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
    );
  }
}

class _DeckList extends StatelessWidget {
  const _DeckList({
    required this.data,
    required this.onOpen,
    required this.onAction,
    required this.onAddFirst,
  });

  final SrsDeckListData data;
  final void Function(SrsDeckSummary deck) onOpen;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;
  final VoidCallback onAddFirst;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsDeckSummary> decks = data.decks;
    final List<Widget> items = <Widget>[
      if (!data.store.canSchedule)
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
      if (data.totalCards == 0)
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
                  onPressed: onAddFirst,
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(t.srs_empty_action),
                ),
              ),
            ],
          ),
        ),
      for (int i = 0; i < decks.length; i++)
        _DeckRow(
          key: ValueKey<String>('srs-deck-${decks[i].deck.id}'),
          deck: decks[i],
          index: i,
          count: decks.length,
          isDefault: decks[i].deck.id == data.store.defaultDeckId,
          onOpen: onOpen,
          onAction: onAction,
        ),
    ];
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
          height: items[index] is _DeckRow && items[index + 1] is _DeckRow
              ? 0
              : tokens.spacing.gap * 1.5,
        ),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

class _DeckRow extends StatelessWidget {
  const _DeckRow({
    super.key,
    required this.deck,
    required this.index,
    required this.count,
    required this.isDefault,
    required this.onOpen,
    required this.onAction,
  });

  final SrsDeckSummary deck;
  final int index;
  final int count;
  final bool isDefault;
  final void Function(SrsDeckSummary deck) onOpen;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? note = srsNewBudgetNote(deck.newBudget);
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        onTap: () => onOpen(deck),
        child: FushiListItem(
          leading: Padding(
            // 层级缩进：子牌组每深一层右移一格。
            padding: EdgeInsetsDirectional.only(
              start: deck.depth * tokens.spacing.card,
            ),
            child: FushiListLeadingIcon(
              deck.depth == 0 ? FushiIcons.collection : FushiIcons.folder,
              tone: deck.reviewCount + deck.learnCount > 0
                  ? FushiCardTone.primary
                  : FushiCardTone.neutral,
            ),
          ),
          title: FushiTooltip(
            message: deck.fullName,
            child: Text(deck.deck.name),
          ),
          subtitle: note == null ? null : Text(note),
          trailing: Row(
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
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
