/// 复习模块主页：牌组列表（底栏 / 侧栏「复习」tab，见 `HomeTab.srs`）。
///
/// 每行：牌组名（子牌组前面按层级画细竖线）+ 新卡 / 学习 / 到期三色计数；新卡被自动
/// 缩减时多一行小字。点行进复习；行内菜单：浏览此牌组的卡片（带 `deck:"全名"` 打开
/// 浏览页）/ 新建子牌组 / 改名 / 牌组设置 / 删除（默认
/// 牌组不可删；空着又没有子牌组时不显示，见 [srsVisibleDecks]）。
/// 顶栏动作默认平铺、放不下才按优先级收进「⋯」（MD3 = [FushiFloatingTopBar] 的
/// 自适应溢出；Apple = 导航栏动作，由 [FushiPageHeader] 自己收）。
library;

import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/apkg/srs_import_report.dart';
import 'package:fushi_engine/srs/srs_browse.dart' show srsDeckQuery;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_anki_migration_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_history_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_legacy_lapis_migration_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_types_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/pages/implementations/srs/srs_import_tasks_bar.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_starter_packs_dialog.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tree.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';

/// 行内菜单动作。
enum _DeckAction {
  browse,
  addChild,
  rename,
  move,
  moveUp,
  moveDown,
  settings,
  delete,
}

enum _ImportSource { anki, file, starter, minedHistory }

/// [purge]：连卡片一起删并彻底清除（v2 `Purge` 操作，各设备一起清内容、不可恢复；见 srs_purge.dart）。
enum _DeckDeleteMode { moveCards, deleteCards, purge }

/// [deckId] 的同级（含自己），按列表顺序（列表是先序、同级已按 [SrsDeckView.compareSiblings] 排好）。
List<SrsDeckSummary> _siblingsOf(
  List<SrsDeckSummary> decks,
  SrsDeckSummary deck,
) => <SrsDeckSummary>[
  for (final SrsDeckSummary d in decks)
    if (d.parentId == deck.parentId) d,
];

/// [rootId] 及其全部子孙牌组的 id（「移动到…」排除目标、拖放判据共用）。
@visibleForTesting
Set<String> srsDeckSubtreeIds(List<SrsDeckSummary> decks, String rootId) {
  final Map<String?, List<String>> children = <String?, List<String>>{};
  for (final SrsDeckSummary d in decks) {
    (children[d.parentId] ??= <String>[]).add(d.deck.id);
  }
  final Set<String> out = <String>{rootId};
  final List<String> stack = <String>[rootId];
  while (stack.isNotEmpty) {
    for (final String c in children[stack.removeLast()] ?? const <String>[]) {
      if (out.add(c)) stack.add(c);
    }
  }
  return out;
}

class SrsDeckListPage extends ConsumerStatefulWidget {
  const SrsDeckListPage({super.key});

  @override
  ConsumerState<SrsDeckListPage> createState() => _SrsDeckListPageState();
}

class _SrsDeckListPageState extends ConsumerState<SrsDeckListPage> {
  /// 首次 v2 同步的确认每次启动最多主动问一次（「稍后」之后点「立即同步」还会再问）。
  static bool _askedFirstSync = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_askedFirstSync || !mounted) return;
      _askedFirstSync = true;
      srsRunLogged(
        'SrsDeckList.firstSync',
        () => _confirmFirstSync(sync: true),
      );
    });
  }

  /// 问一次首次同步；刚确认就顺手跑一轮。
  Future<bool> _confirmFirstSync({required bool sync}) async {
    final AppModel app = ref.read(appProvider);
    if (app.srsSync2MergeConfirmed) return true;
    final SrsDbStore? store = await readSrsStore(ref);
    if (!mounted) return false;
    final bool ok = await ensureSrsFirstSyncConfirmed(context, app, store);
    if (ok && sync) {
      final SrsAppRuntime? runtime = ref.read(srsAppRuntimeProvider);
      if (runtime != null) await runtime.syncNow();
    }
    return ok;
  }

  /// Anki 一键迁移完成后：迁进来的笔记里有旧 Lapis（或此前迁移漏掉的字段）时，
  /// 顺手问一句要不要迁到 Fushi 卡片。[context] 是迁移页的。
  Future<void> _offerLegacyLapisMigration(
    BuildContext context,
    SrsImportReport report,
  ) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !context.mounted) return;
    final ({int migratable, int backfill}) pending = await store
        .legacyLapisPendingCounts();
    final int n = pending.migratable + pending.backfill;
    if (n == 0 || !context.mounted) return;
    final bool go = await showFushiConfirmDialog(
      context: context,
      title: t.srs_lapis_migration_title,
      message: t.srs_lapis_migration_entry_summary(n: n),
      confirmLabel: t.srs_lapis_migration_migrate,
    );
    if (go && context.mounted) await openSrsLegacyLapisMigrationPage(context);
  }

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

  /// [query] 非 null：带着初始查询打开（牌组菜单「浏览此牌组的卡片」= `deck:"全名"`）。
  Future<void> _openBrowse({String? query}) => _push<void>(
    (_) => SrsBrowsePage(
      initialQuery: query,
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

  /// 删牌组时卡片的去向二选一（Anki 的删除牌组是连卡片一起删；以前这里只能移走卡片）。
  Future<void> _delete(SrsDeckSummary deck) async {
    final SrsDbStore? before = await readSrsStore(ref);
    if (before == null || !mounted) return;
    final _DeckDeleteMode? mode = await showFushiChoiceDialog<_DeckDeleteMode>(
      context: context,
      title: t.srs_deck_delete,
      message: t.srs_deck_delete_prompt(name: deck.fullName),
      icon: FushiIcons.delete,
      options: <FushiChoiceOption<_DeckDeleteMode>>[
        FushiChoiceOption<_DeckDeleteMode>(
          value: _DeckDeleteMode.moveCards,
          label: t.srs_deck_delete_move_cards,
          subtitle: t.srs_deck_delete_move_cards_hint,
          icon: FushiIcons.moveFile,
        ),
        FushiChoiceOption<_DeckDeleteMode>(
          value: _DeckDeleteMode.deleteCards,
          label: t.srs_deck_delete_with_cards,
          subtitle: t.srs_deck_delete_with_cards_hint,
          icon: FushiIcons.deleteSweep,
        ),
        // 同步 v2：彻底清除是一条 Purge 操作，各设备收到后一起清（设计 §10.2），任何时候都能选。
        FushiChoiceOption<_DeckDeleteMode>(
          value: _DeckDeleteMode.purge,
          label: t.srs_deck_delete_purge,
          subtitle: t.srs_deck_delete_purge_hint,
          icon: FushiIcons.delete,
        ),
      ],
    );
    if (mode == null || !mounted) return;
    // 控制器先取出来：删除途中本页可能被销毁（复习 tab 不常驻），之后不能再碰 ref。
    final SrsDeckDeleteController deleter = ref.read(
      srsDeckDeleteControllerProvider,
    );
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final bool purge = mode == _DeckDeleteMode.purge;
    final Directory? mediaRoot = purge
        ? (await ref.read(srsMediaStoreProvider.future))?.root
        : null;
    // 删除按块进行（BUG-3543）：行里显示进度、不可点，界面其余部分照常可用。删除由 app 级
    // 控制器跑完并让列表重读，与本页在不在无关。
    await deleter.delete(
      store,
      deck.deck.id,
      deleteCards: mode != _DeckDeleteMode.moveCards,
      purgeNow: purge,
      mediaRoot: mediaRoot,
    );
  }

  /// 收起 / 展开子牌组：写进牌组本身（Anki deck collapsed），随同步到其它设备。
  ///
  /// 不发 [bumpSrsRevision]：收起 / 展开只是界面状态，列表这一行已经按本地覆盖画好了（见
  /// [_DeckListState._pending]），为它把全部牌组的计数重数一遍不值。返回写完时 store 的修订号，
  /// 列表据此判断之后重读回来的数据是否已包含这次写入；store 不可用时返回 null。
  Future<int?> _setCollapsed(SrsDeckSummary deck, bool collapsed) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return null;
    await store.setDeckCollapsed(deck.deck.id, collapsed);
    return store.revision;
  }

  void _onDeckAction(SrsDeckSummary deck, _DeckAction action) {
    switch (action) {
      case _DeckAction.browse:
        srsRunLogged(
          'SrsDeckList.browseDeck',
          () => _openBrowse(query: srsDeckQuery(deck.fullName)),
        );
      case _DeckAction.addChild:
        srsRunLogged(
          'SrsDeckList.addChild',
          () => _createDeck(parentId: deck.deck.id),
        );
      case _DeckAction.rename:
        srsRunLogged('SrsDeckList.rename', () => _rename(deck));
      case _DeckAction.move:
        srsRunLogged('SrsDeckList.move', () => _pickMoveTarget(deck));
      case _DeckAction.moveUp:
        srsRunLogged('SrsDeckList.moveUp', () => _shift(deck, -1));
      case _DeckAction.moveDown:
        srsRunLogged('SrsDeckList.moveDown', () => _shift(deck, 1));
      case _DeckAction.settings:
        srsRunLogged(
          'SrsDeckList.settings',
          () => _push<void>((_) => SrsDeckSettingsPage(deckId: deck.deck.id)),
        );
      case _DeckAction.delete:
        srsRunLogged('SrsDeckList.delete', () => _delete(deck));
    }
  }

  /// 「导入」：三种来源一个入口（以前「导入」「从 Anki 迁移」「从制卡历史导入」分散在
  /// 顶栏与 ⋯ 里，看不出区别）。
  Future<void> _openImport() async {
    final _ImportSource? source = await showFushiChoiceDialog<_ImportSource>(
      context: context,
      title: t.srs_import,
      icon: FushiIcons.importFile,
      options: <FushiChoiceOption<_ImportSource>>[
        FushiChoiceOption<_ImportSource>(
          value: _ImportSource.anki,
          label: t.srs_anki_migrate,
          subtitle: t.srs_anki_migrate_hint,
          icon: FushiIcons.moveFile,
        ),
        FushiChoiceOption<_ImportSource>(
          value: _ImportSource.file,
          label: t.srs_import_file,
          subtitle: t.srs_import_file_hint,
          icon: FushiIcons.importFile,
        ),
        FushiChoiceOption<_ImportSource>(
          value: _ImportSource.starter,
          label: t.srs_starter_title,
          subtitle: t.srs_starter_hint,
          icon: FushiIcons.cloudDownload,
        ),
        FushiChoiceOption<_ImportSource>(
          value: _ImportSource.minedHistory,
          label: t.srs_history_import,
          subtitle: t.srs_history_import_hint,
          icon: FushiIcons.history,
        ),
      ],
    );
    if (source == null || !mounted) return;
    switch (source) {
      case _ImportSource.anki:
        await _push<void>(
          (_) => SrsAnkiMigrationPage(onMigrated: _offerLegacyLapisMigration),
        );
      case _ImportSource.file:
        await openSrsImport(context, ref);
      case _ImportSource.starter:
        await openSrsStarterPacks(context, ref);
      case _ImportSource.minedHistory:
        await openSrsMinedHistoryImport(context, ref);
    }
  }

  Future<void> _syncNow() async {
    if (!await _confirmFirstSync(sync: false) || !mounted) return;
    await openSrsSyncNow(
      ref.read(srsAppRuntimeProvider)?.syncNow,
      onNoChannel: () async {
        if (!mounted) return;
        await showSrsSyncSetupDialog(
          context,
          ref.read(appProvider).moduleVisibility,
        );
      },
    );
  }

  /// 牌组拖放 / 「移动到… / 上移 / 下移」落地：拒绝时说明原因，成功后列表重读。
  Future<void> _placeDeck(
    SrsDeckSummary deck,
    String? parentId, {
    String? beforeId,
  }) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsDeckMoveResult result = await store.placeDeck(
      deck.deck.id,
      parentId: parentId,
      beforeId: beforeId,
    );
    switch (result) {
      case SrsDeckMoveResult.moved:
        if (mounted) bumpSrsRevision(ref);
      case SrsDeckMoveResult.unchanged || SrsDeckMoveResult.missing:
        break;
      case SrsDeckMoveResult.intoOwnSubtree:
        FushiToast.show(
          msg: t.srs_deck_move_into_own_subdeck,
          severity: ToastSeverity.warning,
        );
      case SrsDeckMoveResult.nameTaken:
        FushiToast.show(
          msg: t.srs_deck_move_name_taken,
          severity: ToastSeverity.warning,
        );
    }
  }

  /// 行菜单「移动到…」：键盘 / 手柄 / 窄屏触摸（长按已是菜单）也能挪牌组。
  /// 目标里不列它自己和它的子孙。
  Future<void> _pickMoveTarget(SrsDeckSummary deck) async {
    final SrsDeckListData? data = ref.read(srsDeckListProvider).valueOrNull;
    if (data == null) return;
    final Set<String> subtree = srsDeckSubtreeIds(data.decks, deck.deck.id);
    const String topLevel = '';
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.srs_deck_move,
      icon: FushiIcons.moveFile,
      selected: deck.parentId ?? topLevel,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: topLevel,
          label: t.srs_deck_move_top_level,
        ),
        for (final SrsDeckSummary d in data.decks)
          if (!subtree.contains(d.deck.id))
            FushiChoiceOption<String>(value: d.deck.id, label: d.fullName),
      ],
    );
    if (picked == null || !mounted) return;
    await _placeDeck(deck, picked == topLevel ? null : picked);
  }

  /// 「上移 / 下移」：在同级里挪一位（[delta] = -1 / +1）。
  Future<void> _shift(SrsDeckSummary deck, int delta) async {
    final SrsDeckListData? data = ref.read(srsDeckListProvider).valueOrNull;
    if (data == null) return;
    final List<SrsDeckSummary> level = _siblingsOf(data.decks, deck);
    final int i = level.indexWhere(
      (SrsDeckSummary d) => d.deck.id == deck.deck.id,
    );
    final int to = i + delta;
    if (i < 0 || to < 0 || to >= level.length) return;
    // 上移 = 排到前一个前面；下移 = 排到后一个的后面（即再后一个前面，没有就排最后）。
    final String? beforeId = delta < 0
        ? level[to].deck.id
        : (to + 1 < level.length ? level[to + 1].deck.id : null);
    await _placeDeck(deck, deck.parentId, beforeId: beforeId);
  }

  /// 低优先级动作（MD3 顶栏的 [FushiFloatingTopBar.overflow]：宽度够平铺、不够收进「⋯」；
  /// Apple 导航栏由 [FushiPageHeader] 自己收）。
  List<FushiToolbarItem> _secondaryItems() => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_sync_now'),
      icon: FushiIcons.sync,
      label: t.srs_sync_now,
      onPressed: () => srsRunLogged('SrsDeckList.syncNow', _syncNow),
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
      key: const ValueKey<String>('srs_timeline'),
      icon: FushiIcons.history,
      label: t.srs_timeline_title,
      onPressed: () => srsRunLogged(
        'SrsDeckList.history',
        () => _push<void>((_) => const SrsHistoryPage()),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final AsyncValue<SrsDeckListData?> data = ref.watch(srsDeckListProvider);
    final int conflicts = ref.watch(srsConflictCountProvider).valueOrNull ?? 0;
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
            // 后台导入任务增减（任务条在列表最前，见 [_DeckList.showImportTasks]）与删牌组
            // 开始 / 结束时重建。
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                ref.watch(srsImportControllerProvider),
                ref.watch(srsDeckDeleteControllerProvider),
              ]),
              builder: (BuildContext context, Widget? _) =>
                  _buildBody(context, data),
            ),
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
      onPressed: () => srsRunLogged('SrsDeckList.import', _openImport),
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
    final SrsDeckDeleteController deleter = ref.read(
      srsDeckDeleteControllerProvider,
    );
    // 删完、重读的列表里已经没有它之后才撤掉删除中状态（否则旧数据里的行会先「复原」一下
    // 再消失）。
    deleter.pruneDeleted(<String>[
      for (final SrsDeckSummary d in list.decks) d.deck.id,
    ]);
    return _DeckList(
      data: list,
      deleting: deleter.deleting,
      lapisPending: ref.watch(srsLegacyLapisPendingProvider).valueOrNull ?? 0,
      onMigrateLapis: () => srsRunLogged(
        'SrsDeckList.lapisMigration',
        () => openSrsLegacyLapisMigrationPage(context),
      ),
      onDismissLapisReminder: () => srsRunLogged(
        'SrsDeckList.lapisReminderDismiss',
        () => dismissSrsLapisMigrationReminder(ref),
      ),
      showImportTasks: ref.read(srsImportControllerProvider).tasks.isNotEmpty,
      onOpen: (SrsDeckSummary d) =>
          srsRunLogged('SrsDeckList.review', () => _openReview(d)),
      onAction: _onDeckAction,
      onAddFirst: () => srsRunLogged('SrsDeckList.addFirst', _addNote),
      onStarterPacks: () => srsRunLogged(
        'SrsDeckList.starterPacks',
        () => openSrsStarterPacks(context, ref),
      ),
      onSetCollapsed: _setCollapsed,
      onPlace: (SrsDeckSummary deck, String? parentId, String? beforeId) =>
          srsRunLogged(
            'SrsDeckList.drop',
            () => _placeDeck(deck, parentId, beforeId: beforeId),
          ),
    );
  }
}

class _DeckList extends StatefulWidget {
  const _DeckList({
    required this.data,
    required this.deleting,
    required this.onOpen,
    required this.onAction,
    required this.onAddFirst,
    required this.onStarterPacks,
    required this.onSetCollapsed,
    required this.showImportTasks,
    required this.lapisPending,
    required this.onMigrateLapis,
    required this.onDismissLapisReminder,
    required this.onPlace,
  });

  /// 拖放落地（见 [_DeckPlace]）。
  final _DeckPlace onPlace;

  final SrsDeckListData data;

  /// 正在删的牌组（及其进度）；子牌组随父牌组一起显示删除中。
  final Map<String, ValueListenable<double?>> deleting;

  /// 有后台导入任务（排队 / 运行中 / 结束未关）：列表最前显示任务条。
  final bool showImportTasks;

  /// 还能迁到 Fushi 卡片（或可补迁遗漏字段）的旧 Lapis 笔记数；> 0 时列表前显示迁移提醒
  /// （提醒被「不再提醒」关掉时为 0，见 [srsLegacyLapisPendingProvider]）。
  final int lapisPending;
  final VoidCallback onMigrateLapis;
  final VoidCallback onDismissLapisReminder;
  final void Function(SrsDeckSummary deck) onOpen;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;
  final VoidCallback onAddFirst;

  /// 空牌组卡片「入门卡组」：下载预置卡组（如 Kaishi 1.5k）。
  final VoidCallback onStarterPacks;

  /// 收起 / 展开一个牌组（写进牌组本身，随同步）。返回写完时 store 的修订号（null = 没写）。
  final Future<int?> Function(SrsDeckSummary deck, bool collapsed)
  onSetCollapsed;

  @override
  State<_DeckList> createState() => _DeckListState();
}

class _DeckListState extends State<_DeckList> {
  /// 本机点过、列表数据还没反映出来的折叠状态：先按它画，不等写库往返。收起 / 展开不触发列表
  /// 重读（见 `_SrsDeckListPageState._setCollapsed`），覆盖一直留到某次重读的数据确定包含了这次写入。
  final Map<String, bool> _pending = <String, bool>{};

  /// 每个牌组的折叠写入序号（连点时只认最后一次）。
  final Map<String, int> _toggleSeq = <String, int>{};

  /// 最后一次折叠写入完成时 store 的修订号：重读数据的修订号 ≥ 它就一定包含这次写入。
  final Map<String, int> _committedAt = <String, int>{};

  /// 正在拖的牌组（拖着子牌组时列表顶上出现「移到顶层」落点）。
  SrsDeckSummary? _dragging;

  void _setDragging(SrsDeckSummary? deck) {
    if (!mounted || identical(_dragging, deck)) return;
    setState(() => _dragging = deck);
  }

  @override
  void didUpdateWidget(_DeckList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.data, widget.data)) return;
    if (!identical(oldWidget.data.store, widget.data.store)) {
      // 换了 profile / 重开了库：旧覆盖对新库无意义。
      _pending.clear();
      _committedAt.clear();
      return;
    }
    // 重读回来的数据已经反映了这次修改：撤掉本地覆盖。值相同可直接撤；值不同但数据是在写入
    // 完成之后读的（别的设备同步来了新值），也撤——以数据为准。
    for (final SrsDeckSummary d in widget.data.decks) {
      final String id = d.deck.id;
      final bool? pending = _pending[id];
      if (pending == null) continue;
      final int? at = _committedAt[id];
      if (pending == d.deck.collapsed ||
          (at != null && widget.data.revision >= at)) {
        _pending.remove(id);
        _committedAt.remove(id);
      }
    }
  }

  bool _collapsed(SrsDeckSummary d) => _pending[d.deck.id] ?? d.deck.collapsed;

  void _setCollapsed(SrsDeckSummary d, bool collapsed) {
    if (_collapsed(d) == collapsed) return;
    final String id = d.deck.id;
    final int seq = (_toggleSeq[id] ?? 0) + 1;
    _toggleSeq[id] = seq;
    _committedAt.remove(id);
    setState(() => _pending[id] = collapsed);
    srsRunLogged('SrsDeckList.collapse', () async {
      final int? at;
      try {
        at = await widget.onSetCollapsed(d, collapsed);
      } catch (_) {
        // 没写进去：撤掉覆盖，回到数据里的状态（失败由 srsRunLogged 留痕）。
        if (mounted && _toggleSeq[id] == seq) {
          setState(() => _pending.remove(id));
        }
        rethrow;
      }
      if (!mounted || _toggleSeq[id] != seq) return;
      if (at == null) {
        setState(() => _pending.remove(id));
      } else {
        _committedAt[id] = at;
      }
    });
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
      // 同步进度（常规同步 / 复习同步；复习同步一轮可能跑十几分钟）：没在跑时零高度，
      // 与下一项的间距由它自己的 margin 只在可见时留（下面分隔符对它给 0）。
      SyncProgressBanner(
        key: const ValueKey<String>('srs-sync-progress'),
        margin: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
      ),
      // 后台导入任务（BUG-3549）：有任务时排在最前。
      if (widget.showImportTasks)
        const SrsImportTasksBar(key: ValueKey<String>('srs-import-tasks')),
      if (widget.lapisPending > 0)
        FushiCard(
          key: const ValueKey<String>('srs-lapis-migration-reminder'),
          tone: FushiCardTone.primary,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              Row(
                spacing: tokens.spacing.gap * 1.5,
                children: <Widget>[
                  const FushiIcon(FushiIcons.swap),
                  Expanded(
                    child: Text(
                      t.srs_lapis_migration_reminder_title,
                      style: context.fushiType.titleMediumEmphasized,
                    ),
                  ),
                ],
              ),
              Text(t.srs_lapis_migration_entry_summary(n: widget.lapisPending)),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  FushiPressScale(
                    child: FushiTextButton(
                      key: const ValueKey<String>(
                        'srs-lapis-migration-reminder-dismiss',
                      ),
                      onPressed: widget.onDismissLapisReminder,
                      child: Text(t.srs_lapis_migration_reminder_dismiss),
                    ),
                  ),
                  FushiPressScale(
                    child: FushiFilledButton.icon(
                      key: const ValueKey<String>(
                        'srs-lapis-migration-reminder-open',
                      ),
                      onPressed: widget.onMigrateLapis,
                      icon: const FushiIcon(FushiIcons.swap),
                      label: Text(t.srs_lapis_migration_migrate),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: <Widget>[
                    FushiPressScale(
                      child: FushiFilledButton.tonalIcon(
                        key: const ValueKey<String>('srs-starter-packs'),
                        onPressed: widget.onStarterPacks,
                        icon: const FushiIcon(FushiIcons.cloudDownload),
                        label: Text(t.srs_starter_title),
                      ),
                    ),
                    FushiPressScale(
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
            ],
          ),
        ),
    ];
    // 删除中的牌组连同它的子牌组一起显示删除中（子牌组随父牌组一并删除）。
    ValueListenable<double?>? deletingOf(SrsDeckSummary d) {
      String? id = d.deck.id;
      int guard = 0;
      while (id != null && guard++ < 64) {
        final ValueListenable<double?>? p = widget.deleting[id];
        if (p != null) return p;
        id = byId[id]?.parentId;
      }
      return null;
    }

    final int firstDeckItem = items.length;
    // 每个牌组的前 / 后一个同级（列表是先序，同级已排好）：拖到行下缘、上移 / 下移用。
    final Map<String, String> next = <String, String>{};
    final Set<String> hasPrev = <String>{};
    final Map<String?, String> lastOfLevel = <String?, String>{};
    for (final SrsDeckSummary d in decks) {
      final String? prev = lastOfLevel[d.parentId];
      if (prev != null) {
        next[prev] = d.deck.id;
        hasPrev.add(d.deck.id);
      }
      lastOfLevel[d.parentId] = d.deck.id;
    }
    int shown = 0;
    for (int i = 0; i < decks.length; i++) {
      final SrsDeckSummary d = decks[i];
      // 分段卡的圆角按「可见行」里的位置算；隐藏行收成 0 高，位置无所谓。
      final int index = visible[i] ? shown++ : shown;
      items.add(
        FushiTreeReveal(
          key: ValueKey<String>('srs-deck-${d.deck.id}'),
          visible: visible[i],
          child: _DeckDragShell(
            key: ValueKey<String>('srs-drag-${d.deck.id}'),
            deck: d,
            decks: decks,
            enabled: deletingOf(d) == null,
            onDragStarted: () => _setDragging(d),
            onDragEnded: () => _setDragging(null),
            onPlace: widget.onPlace,
            nextSiblingId: next[d.deck.id],
            child: _DeckRow(
              deck: d,
              deleting: deletingOf(d),
              index: index,
              count: visibleCount,
              isDefault: d.deck.id == widget.data.store.defaultDeckId,
              hasTree: parents.isNotEmpty,
              hasChildren: parents.contains(d.deck.id),
              collapsed: _collapsed(d),
              onSetCollapsed: (bool c) => _setCollapsed(d, c),
              onOpen: widget.onOpen,
              onAction: widget.onAction,
              canMoveUp: hasPrev.contains(d.deck.id),
              canMoveDown: next.containsKey(d.deck.id),
            ),
          ),
        ),
      );
    }
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    return Stack(
      children: <Widget>[
        FushiEntranceScope(
          child: ListView.separated(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                // 正文滚到浮动页头底下：顶部让出「状态栏 + 页头」。
                top,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            itemCount: items.length,
            // 牌组行是一组分段卡（行间 2px，由 FushiGroupedListItem 自己画），横幅与
            // 牌组之间才留卡片间距。
            separatorBuilder: (BuildContext context, int index) => SizedBox(
              height: index == 0 || index >= firstDeckItem
                  ? 0
                  : tokens.spacing.gap * 1.5,
            ),
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int index) => items[index],
            ),
          ),
        ),
        // 「移到顶层」落点浮在列表顶上（列表滚到哪都够得着），只在拖着子牌组时出现。
        PositionedDirectional(
          top: top,
          start: tokens.spacing.page,
          end: tokens.spacing.page,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: _dragging?.parentId == null
                ? const SizedBox.shrink()
                : _TopLevelDropZone(
                    key: const ValueKey<String>('srs-drop-top-level'),
                    onPlace: widget.onPlace,
                  ),
          ),
        ),
      ],
    );
  }
}

class _DeckRow extends StatelessWidget {
  const _DeckRow({
    required this.deck,
    required this.deleting,
    required this.index,
    required this.count,
    required this.isDefault,
    required this.hasTree,
    required this.hasChildren,
    required this.collapsed,
    required this.onSetCollapsed,
    required this.onOpen,
    required this.onAction,
    required this.canMoveUp,
    required this.canMoveDown,
  });

  final SrsDeckSummary deck;

  /// 同级里前 / 后还有牌组（菜单「上移 / 下移」）。
  final bool canMoveUp;
  final bool canMoveDown;

  /// 非 null = 正在删除（本牌组或祖先）：行变淡、不可点 / 不进焦点，副标题换成进度条。
  final ValueListenable<double?>? deleting;
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
  Widget build(BuildContext context) {
    final bool busy = deleting != null;
    return ExcludeFocus(
      excluding: busy,
      child: IgnorePointer(
        ignoring: busy,
        child: AnimatedOpacity(
          opacity: busy ? 0.6 : 1,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                _buildRow(
                  context,
                  compact: constraints.maxWidth < compactBelow,
                ),
          ),
        ),
      ),
    );
  }

  /// 删除中的副标题：「正在删除…」+ 进度条（总数未知时不定进度）。展开 / 收起带尺寸与淡入淡出。
  Widget? _subtitle(BuildContext context, String? note) {
    final ValueListenable<double?>? progress = deleting;
    final Widget? body = progress == null
        ? (note == null ? null : Text(note))
        : Column(
            key: ValueKey<String>('srs-deck-deleting-${deck.deck.id}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: FushiDesignTokens.of(context).spacing.gap / 2,
            children: <Widget>[
              Text(t.srs_deck_deleting),
              ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (BuildContext context, double? value, Widget? _) =>
                    FushiLinearProgressIndicator(
                      value: value,
                      semanticsLabel: t.srs_deck_deleting,
                    ),
              ),
            ],
          );
    if (body == null && note == null && progress == null) return null;
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        child: body ?? const SizedBox.shrink(),
      ),
    );
  }

  List<PopupMenuEntry<_DeckAction>> _menuItems() =>
      <PopupMenuEntry<_DeckAction>>[
        // 默认牌组同样可用：批量移动 / 删除错导的卡从这里进（反馈 SSfSHb5JNt）。
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.browse,
          child: Text(t.srs_deck_browse_cards),
        ),
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.addChild,
          child: Text(t.srs_deck_new_child),
        ),
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.rename,
          child: Text(t.srs_deck_rename),
        ),
        PopupMenuItem<_DeckAction>(
          value: _DeckAction.move,
          child: Text(t.srs_deck_move),
        ),
        if (canMoveUp)
          PopupMenuItem<_DeckAction>(
            value: _DeckAction.moveUp,
            child: Text(t.srs_deck_move_up),
          ),
        if (canMoveDown)
          PopupMenuItem<_DeckAction>(
            value: _DeckAction.moveDown,
            child: Text(t.srs_deck_move_down),
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
                  subtitle: _subtitle(context, note),
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

/// 只认 [devices] 的 [Draggable]：鼠标按下即可拖（桌面列表不靠拖动滚动），触摸走长按
/// 版（[_DeviceLongPressDraggable]），两者设备不重叠、互不抢手势；触摸的滑动照常滚列表。
class _DeviceDraggable<T extends Object> extends Draggable<T> {
  const _DeviceDraggable({
    required this.devices,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.onDragStarted,
    super.onDragEnd,
    super.onDraggableCanceled,
    super.dragAnchorStrategy,
  });

  final Set<PointerDeviceKind> devices;

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      ImmediateMultiDragGestureRecognizer(supportedDevices: devices)
        ..onStart = onStart;
}

class _DeviceLongPressDraggable<T extends Object>
    extends LongPressDraggable<T> {
  const _DeviceLongPressDraggable({
    required this.devices,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.onDragStarted,
    super.onDragEnd,
    super.onDraggableCanceled,
    super.dragAnchorStrategy,
  });

  final Set<PointerDeviceKind> devices;

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      DelayedMultiDragGestureRecognizer(delay: delay, supportedDevices: devices)
        ..onStart = (Offset position) {
          final Drag? result = onStart(position);
          if (result != null && hapticFeedbackOnStart) {
            unawaited(HapticFeedback.selectionClick());
          }
          return result;
        };
}

/// 拖放落地：把 dragged 放到 parentId 下（null = 顶层）、排在 beforeId 前（null = 末尾）。
typedef _DeckPlace =
    void Function(SrsDeckSummary dragged, String? parentId, String? beforeId);

/// 指针在行里的落点区：上 / 下缘 = 排到本行前 / 后（同级），中间 = 挪成本行的子牌组。
enum _DropZone { before, into, after }

/// 牌组行的拖放外壳（Anki 拖放 + 同级手动排序）：拖起本行；别的牌组拖到本行上——
/// 上缘四分之一 = 排到本行前面，下缘四分之一 = 排到本行后面（都与本行同级），中间 =
/// 挪成本行的子牌组。拖到自己 / 自己的子孙上不接（不高亮）。
///
/// 鼠标：按下拖动即开始。触摸：宽屏长按开始；窄屏长按已是牌组菜单，触摸挪牌组走菜单
/// 「移动到… / 上移 / 下移」。
class _DeckDragShell extends StatefulWidget {
  const _DeckDragShell({
    super.key,
    required this.deck,
    required this.decks,
    required this.nextSiblingId,
    required this.enabled,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onPlace,
    required this.child,
  });

  final SrsDeckSummary deck;
  final List<SrsDeckSummary> decks;

  /// 同级里排在本行后面的那个（「排到本行后面」= 排到它前面；null = 本行是同级最后）。
  final String? nextSiblingId;
  final bool enabled;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;
  final _DeckPlace onPlace;
  final Widget child;

  @override
  State<_DeckDragShell> createState() => _DeckDragShellState();
}

class _DeckDragShellState extends State<_DeckDragShell> {
  _DropZone? _zone;

  /// 被拖的牌组不能落到它自己或它的子孙上（任何区都不行）。
  bool _accepts(SrsDeckSummary dragged) =>
      widget.enabled &&
      !srsDeckSubtreeIds(
        widget.decks,
        dragged.deck.id,
      ).contains(widget.deck.deck.id);

  _DropZone _zoneAt(Offset global) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.height <= 0) {
      return _DropZone.into;
    }
    final double y = box.globalToLocal(global).dy / box.size.height;
    if (y < 0.25) return _DropZone.before;
    if (y > 0.75) return _DropZone.after;
    return _DropZone.into;
  }

  void _setZone(_DropZone? zone) {
    if (_zone == zone || !mounted) return;
    setState(() => _zone = zone);
  }

  void _place(SrsDeckSummary dragged, _DropZone zone) {
    final SrsDeckSummary row = widget.deck;
    switch (zone) {
      case _DropZone.into:
        widget.onPlace(dragged, row.deck.id, null);
      case _DropZone.before:
        widget.onPlace(dragged, row.parentId, row.deck.id);
      case _DropZone.after:
        // 排到下一个同级前面；下一个就是被拖的自己时，相当于原地不动。
        final String? next = widget.nextSiblingId == dragged.deck.id
            ? null
            : widget.nextSiblingId;
        widget.onPlace(dragged, row.parentId, next);
    }
  }

  Widget _feedback(BuildContext context, double width) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      elevation: 6,
      borderRadius: BorderRadius.circular(tokens.radii.group),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              FushiIcon(FushiIcons.folder, color: scheme.onSecondaryContainer),
              Expanded(
                child: Text(
                  widget.deck.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 落点指示：前 / 后 = 行上 / 下缘一条主色线（插入位置），中间 = 整行描边（成为子牌组）。
  Decoration _indicator(ColorScheme scheme, FushiDesignTokens tokens) {
    final BorderSide line = BorderSide(color: scheme.primary, width: 3);
    return switch (_zone) {
      null => const BoxDecoration(),
      _DropZone.before => BoxDecoration(border: Border(top: line)),
      _DropZone.after => BoxDecoration(border: Border(bottom: line)),
      _DropZone.into => BoxDecoration(
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(tokens.radii.group),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < _DeckRow.compactBelow;
        // 拖影挂在指针左上方一点（锚点是指针本身，见 [_pointerOf]）。
        final Widget feedback = FractionalTranslation(
          translation: const Offset(-0.1, -0.5),
          child: _feedback(
            context,
            constraints.maxWidth.isFinite
                ? constraints.maxWidth.clamp(0, 360).toDouble()
                : 360,
          ),
        );
        final Widget dimmed = Opacity(opacity: 0.4, child: widget.child);
        Widget row = widget.child;
        if (widget.enabled) {
          row = _DeviceDraggable<SrsDeckSummary>(
            devices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
            data: widget.deck,
            feedback: feedback,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            childWhenDragging: dimmed,
            onDragStarted: widget.onDragStarted,
            onDragEnd: (_) => widget.onDragEnded(),
            child: compact
                ? row
                : _DeviceLongPressDraggable<SrsDeckSummary>(
                    devices: const <PointerDeviceKind>{
                      PointerDeviceKind.touch,
                      PointerDeviceKind.stylus,
                    },
                    data: widget.deck,
                    feedback: feedback,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    childWhenDragging: dimmed,
                    onDragStarted: widget.onDragStarted,
                    onDragEnd: (_) => widget.onDragEnded(),
                    child: row,
                  ),
          );
        }
        return DragTarget<SrsDeckSummary>(
          onWillAcceptWithDetails: (DragTargetDetails<SrsDeckSummary> d) =>
              _accepts(d.data),
          onMove: (DragTargetDetails<SrsDeckSummary> d) {
            if (_accepts(d.data)) _setZone(_zoneAt(_pointerOf(d)));
          },
          onLeave: (_) => _setZone(null),
          onAcceptWithDetails: (DragTargetDetails<SrsDeckSummary> d) {
            final _DropZone zone = _zone ?? _zoneAt(_pointerOf(d));
            _setZone(null);
            _place(d.data, zone);
          },
          builder:
              (
                BuildContext context,
                List<SrsDeckSummary?> candidates,
                List<dynamic> _,
              ) => AnimatedContainer(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                foregroundDecoration: candidates.isEmpty
                    ? const BoxDecoration()
                    : _indicator(scheme, tokens),
                child: row,
              ),
        );
      },
    );
  }

  /// 拖起时用 [pointerDragAnchorStrategy]：[DragTargetDetails.offset] 就是指针位置
  /// （拖影的视觉偏移另由 [FractionalTranslation] 做，不影响这里）。
  Offset _pointerOf(DragTargetDetails<SrsDeckSummary> d) => d.offset;
}

/// 拖着子牌组时列表顶上出现的落点：放下 = 挪到顶层（末尾）。
class _TopLevelDropZone extends StatelessWidget {
  const _TopLevelDropZone({super.key, required this.onPlace});

  final _DeckPlace onPlace;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
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
              padding: EdgeInsets.all(tokens.spacing.gap * 1.5),
              decoration: BoxDecoration(
                color: hovering
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHigh,
                border: Border.all(
                  color: hovering ? scheme.primary : scheme.outlineVariant,
                  width: hovering ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(tokens.radii.group),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  const FushiIcon(FushiIcons.moveFile),
                  Flexible(child: Text(t.srs_deck_move_drop_top_level)),
                ],
              ),
            );
          },
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
            child: FushiTreeChevron(
              expanded: !collapsed,
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
