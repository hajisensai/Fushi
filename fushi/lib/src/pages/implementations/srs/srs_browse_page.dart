/// 复习卡片浏览（对齐 Anki 浏览器的常用能力，手机与桌面通用）：
///
/// - 搜索：Anki 搜索语法（字段限定 `字段:内容`、通配 `*` `_`、`字段:re:`、`deck:` `note:` `tag:`
///   `card:` `is:` `flag:` `prop:` `added:` `edited:` 等，见 [srsBrowseSearchHelpRows]），
///   或者不记语法：「搜索范围」选一个字段 + 关键字。
/// - 排序：排序字段 / 指定字段 / 到期 / 新建 / 修改 / 间隔 / 难度 / 复习次数 / 遗忘次数 / 牌组 /
///   笔记类型，升降序可切；卡片模式（一行一张卡）与笔记模式（一行一条笔记）可切。
/// - 预览：宽屏列表 + 预览分栏；窄屏点一行进预览页，左右切换上一张 / 下一张。
/// - 批量：长按 / 「选择」进入多选，桌面 Ctrl / Shift 点选；暂停、搁置、旗标、改牌组、加删标签、
///   重置为新卡、设置到期日、删除笔记（确认），以及外部提供的「更改笔记类型」。每个批量操作一个
///   事件批次落库（可同步），并进本页的撤销栈（Ctrl+Z / 撤销按钮）。
///
/// 键盘（本页焦点作用域；文本框持焦时一概不拦）：↑ / ↓ 移动当前行（Shift 扩选），
/// Enter = 预览（宽屏翻面），Ctrl+A 全选，Esc 取消选择，Delete 删除所选，Ctrl+Z 撤销，
/// Ctrl+F 搜索。裸空格不在列表上用——确认一律 Enter（`global_navigation.dart` 的裸空格中和）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_dialogs.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「更改笔记类型」的入口（由别的模块提供）：传入要改的笔记 ID。
typedef SrsChangeNoteTypeFlow =
    Future<void> Function(BuildContext context, List<String> noteIds);

/// 宽屏分栏（列表 + 预览）的最小宽度。
const double kSrsBrowseSplitMinWidth = 840;

/// 本页撤销栈的一步（会话级，不同步——与复习页同一约定）。
class _UndoEntry {
  const _UndoEntry(this.revert);
  final SrsBatchRevert revert;
}

class SrsBrowsePage extends ConsumerStatefulWidget {
  const SrsBrowsePage({
    super.key,
    this.initialQuery,
    this.initialCardId,
    this.onChangeNoteType,
    this.onMigrateToFushiCard,
  });

  /// 打开时带上的查询（AnkiConnect guiBrowse）。
  final String? initialQuery;

  /// 打开时定位到的卡片（复习页顶栏「浏览」：像 Anki 一样直接落在正在复习的这张卡上，
  /// 预览 / 编辑就在旁边）。不在当前查询结果里时按默认落到第一行。
  final String? initialCardId;

  /// 批量菜单的「更改笔记类型」；null = 不显示这一项。
  final SrsChangeNoteTypeFlow? onChangeNoteType;

  /// 批量菜单的「迁移到 Fushi 卡片」（只对 Lapis 笔记）；null = 不显示这一项。
  final SrsChangeNoteTypeFlow? onMigrateToFushiCard;

  @override
  ConsumerState<SrsBrowsePage> createState() => _SrsBrowsePageState();
}

class _SrsBrowsePageState extends ConsumerState<SrsBrowsePage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery ?? '',
  );
  final FocusNode _queryFocus = FocusNode(debugLabel: 'srs-browse-search');
  final FocusNode _focusNode = FocusNode(debugLabel: 'srs-browse');

  /// 预览卡面的查词弹窗（开着时 Enter / 方向键不翻面、不换卡）。
  final SrsCardLookupController _previewLookup = SrsCardLookupController();
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: (FocusReclaimCause cause) =>
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false) &&
        !_editingText,
  );
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  bool _loading = true;
  bool _canSchedule = true;
  SrsBrowseSnapshot? _snapshot;
  List<SrsBrowseItem> _items = const <SrsBrowseItem>[];
  String? _searchError;

  SrsBrowseMode _mode = SrsBrowseMode.cards;
  SrsBrowseSort _sort = const SrsBrowseSort();

  /// 「搜索范围」：null = 全部字段（搜索框按 Anki 语法解析）；否则是字段名，搜索框是关键字。
  String? _searchField;

  /// 当前行（预览目标 / 键盘位置）的 ID；见 [_idOf]。
  late String? _currentId = widget.initialCardId;
  final Set<String> _selected = <String>{};
  bool _selectMode = false;
  String? _anchorId;
  bool _showAnswer = false;
  int _revision = 0;
  bool _busy = false;
  final List<_UndoEntry> _undo = <_UndoEntry>[];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _queryFocus.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    _previewLookup.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据

  bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  bool get _selecting => _selectMode || _selected.isNotEmpty;

  String _idOf(SrsBrowseItem item) =>
      _mode == SrsBrowseMode.cards ? item.cardId : item.noteId;

  int get _currentIndex {
    final String? id = _currentId;
    if (id == null) return -1;
    return _items.indexWhere((SrsBrowseItem i) => _idOf(i) == id);
  }

  String get _effectiveQuery {
    final String? field = _searchField;
    return field == null
        ? _query.text
        : srsFieldContainsQuery(field, _query.text);
  }

  Future<void> _reload() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(store);
    if (!mounted) return;
    final bool first = _snapshot == null;
    setState(() {
      _snapshot = snap;
      _canSchedule = store.canSchedule;
      _loading = false;
      _applyQuery();
    });
    // 带着 initialCardId 打开：列表首次出现后把这一行滚进视口。
    if (first && widget.initialCardId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final int i = _currentIndex;
        if (i >= 0) _scrollToIndex(i);
      });
    }
  }

  /// 按当前查询 / 排序 / 模式重算列表（同步，调用方负责 setState）。
  void _applyQuery() {
    final SrsBrowseSnapshot? snap = _snapshot;
    if (snap == null) return;
    try {
      _items = snap.query(query: _effectiveQuery, sort: _sort, mode: _mode);
      _searchError = null;
    } on SrsSearchUnsupported catch (e) {
      _items = const <SrsBrowseItem>[];
      _searchError = e.reason;
    }
    final Set<String> ids = <String>{
      for (final SrsBrowseItem i in _items) _idOf(i),
    };
    _selected.retainWhere(ids.contains);
    if (_currentId != null && !ids.contains(_currentId)) _currentId = null;
    _currentId ??= _items.isEmpty ? null : _idOf(_items.first);
  }

  void _requery() => setState(_applyQuery);

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _requery();
    });
  }

  /// 批量操作的目标：有选中项用选中项，否则用当前行。
  List<SrsBrowseItem> get _targets {
    if (_selected.isNotEmpty) {
      return <SrsBrowseItem>[
        for (final SrsBrowseItem i in _items)
          if (_selected.contains(_idOf(i))) i,
      ];
    }
    final int i = _currentIndex;
    return i < 0 ? const <SrsBrowseItem>[] : <SrsBrowseItem>[_items[i]];
  }

  // ------------------------------------------------------------------ 选择

  void _setCurrent(int index, {bool extend = false}) {
    if (index < 0 || index >= _items.length) return;
    final String id = _idOf(_items[index]);
    setState(() {
      if (extend) {
        _selectRange(_anchorId ?? _currentId ?? id, id);
      } else {
        _anchorId = id;
      }
      if (_currentId != id) _showAnswer = false;
      _currentId = id;
    });
    _scrollToIndex(index);
  }

  void _selectRange(String fromId, String toId) {
    final int a = _items.indexWhere((SrsBrowseItem i) => _idOf(i) == fromId);
    final int b = _items.indexWhere((SrsBrowseItem i) => _idOf(i) == toId);
    if (a < 0 || b < 0) return;
    for (int i = math.min(a, b); i <= math.max(a, b); i++) {
      _selected.add(_idOf(_items[i]));
    }
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      _anchorId = id;
      _currentId = id;
    });
  }

  void _selectAll() {
    setState(() {
      _selectMode = true;
      _selected
        ..clear()
        ..addAll(_items.map(_idOf));
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  void _onRowTap(int index, {required bool wide}) {
    final String id = _idOf(_items[index]);
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed) {
      setState(() {
        _selectMode = true;
        _selectRange(_anchorId ?? _currentId ?? id, id);
        _currentId = id;
      });
      return;
    }
    if (kb.isControlPressed || kb.isMetaPressed || _selecting) {
      _toggle(id);
      return;
    }
    if (wide) {
      _setCurrent(index);
    } else {
      setState(() => _currentId = id);
      unawaited(_openPreviewPage(index));
    }
  }

  void _onRowLongPress(int index) {
    setState(() => _selectMode = true);
    _toggle(_idOf(_items[index]));
  }

  void _scrollToIndex(int index) {
    if (!_scroll.hasClients) return;
    // 行高不固定：先按估计行高把目标行滚进视口附近，再按真实几何对齐。
    const double estimate = 72;
    final ScrollPosition p = _scroll.position;
    final double target = (index * estimate).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    final double top = p.pixels;
    final double bottom = top + p.viewportDimension - estimate * 2;
    if (target < top || target > bottom) {
      _scroll.jumpTo(
        (target - p.viewportDimension / 3).clamp(
          p.minScrollExtent,
          p.maxScrollExtent,
        ),
      );
    }
  }

  // ------------------------------------------------------------------ 导航

  Future<void> _openPreviewPage(int index) async {
    await _focusOwnership.guardOverlay(
      () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => SrsBrowsePreviewPage(
            items: List<SrsBrowseItem>.of(_items),
            initialIndex: index,
          ),
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _editNote(String noteId) async {
    await _focusOwnership.guardOverlay(
      () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => SrsNoteEditorPage(noteId: noteId),
        ),
      ),
    );
    if (!mounted) return;
    bumpSrsRevision(ref);
    _revision++;
    await _reload();
  }

  void _onPreviewCommand(SrsPreviewCommand c) {
    switch (c) {
      case SrsPreviewCommand.flip:
        setState(() => _showAnswer = !_showAnswer);
      case SrsPreviewCommand.previous:
        _setCurrent(_currentIndex - 1);
      case SrsPreviewCommand.next:
        _setCurrent(_currentIndex + 1);
      case SrsPreviewCommand.undo:
        _undoLast();
      case SrsPreviewCommand.escape:
        if (_selecting) _clearSelection();
    }
  }

  // ------------------------------------------------------------------ 批量

  List<SrsBrowseBatchAction> get _batchActions => <SrsBrowseBatchAction>[
    SrsBrowseBatchAction.toggleSuspend,
    SrsBrowseBatchAction.toggleBury,
    SrsBrowseBatchAction.flag,
    SrsBrowseBatchAction.move,
    SrsBrowseBatchAction.addTags,
    SrsBrowseBatchAction.removeTags,
    if (_canSchedule) SrsBrowseBatchAction.reset,
    if (_canSchedule) SrsBrowseBatchAction.setDue,
    if (widget.onChangeNoteType != null) SrsBrowseBatchAction.changeNoteType,
    if (widget.onMigrateToFushiCard != null)
      SrsBrowseBatchAction.migrateToFushiCard,
    SrsBrowseBatchAction.delete,
  ];

  Future<void> _openBatchMenu() async {
    if (_targets.isEmpty) return;
    final SrsBrowseBatchAction? a = await _focusOwnership.guardOverlay(
      () => pickSrsBrowseBatchAction(
        context,
        actions: _batchActions,
        title: _selected.isEmpty
            ? t.srs_browse_batch_actions
            : t.srs_browse_selected_count(n: _selected.length),
      ),
    );
    if (a == null || !mounted) return;
    await _runBatch(a);
  }

  Future<void> _runBatch(SrsBrowseBatchAction action) async {
    final List<SrsBrowseItem> targets = _targets;
    if (targets.isEmpty || _busy) return;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    final List<SrsCardSearchSubject> cards = <SrsCardSearchSubject>[
      for (final SrsBrowseItem i in targets) ...i.cards,
    ];
    final List<String> cardIds = <String>[
      for (final SrsCardSearchSubject c in cards) c.card.id,
    ];
    final List<String> noteIds = <String>{
      for (final SrsBrowseItem i in targets) i.noteId,
    }.toList();

    Future<SrsBatchOutcome> Function()? run;
    String? doneMessage;
    switch (action) {
      case SrsBrowseBatchAction.toggleSuspend:
        final bool suspend = !cards.every((c) => c.isSuspended);
        run = () => srsBatchSetSuspended(store, cardIds, suspended: suspend);
        doneMessage = suspend
            ? t.srs_browse_suspended
            : t.srs_browse_unsuspended;
      case SrsBrowseBatchAction.toggleBury:
        final bool bury = !cards.every((c) => c.isBuried);
        run = () => srsBatchSetBuried(store, cardIds, buried: bury);
      case SrsBrowseBatchAction.flag:
        final Set<int> flags = <int>{for (final c in cards) c.flag};
        final int? flag = await _focusOwnership.guardOverlay(
          () => pickSrsFlag(
            context,
            selected: flags.length == 1 ? flags.single : null,
          ),
        );
        if (flag == null) return;
        run = () => srsBatchSetFlag(store, cardIds, flag);
      case SrsBrowseBatchAction.move:
        final List<SrsDeckSummary> decks = await store.deckSummaries();
        if (!mounted) return;
        final Set<String> current = <String>{
          for (final c in cards) c.card.deckId,
        };
        final String? deck = await _focusOwnership.guardOverlay(
          () => pickSrsDeck(
            context,
            decks: decks,
            selected: current.length == 1 ? current.single : null,
            title: t.srs_card_move,
          ),
        );
        if (deck == null) return;
        run = () => srsBatchMoveCards(store, cardIds, deck);
      case SrsBrowseBatchAction.addTags || SrsBrowseBatchAction.removeTags:
        final bool add = action == SrsBrowseBatchAction.addTags;
        final String? text = await _focusOwnership.guardOverlay(
          () => showFushiTextInputDialog(
            context: context,
            title: add ? t.srs_browse_tags_add : t.srs_browse_tags_remove,
            hintText: t.srs_note_tags_hint,
            icon: FushiIcons.tag,
          ),
        );
        if (text == null) return;
        final List<String> tags = srsParseTags(text);
        if (tags.isEmpty) return;
        run = () => srsBatchEditTags(
          store,
          noteIds,
          add: add ? tags : const <String>[],
          remove: add ? const <String>[] : tags,
        );
      case SrsBrowseBatchAction.reset:
        final bool ok = await _focusOwnership.guardOverlay(
          () => showFushiConfirmDialog(
            context: context,
            title: t.srs_card_reset,
            message: t.srs_browse_reset_confirm(n: cardIds.length),
            confirmLabel: t.srs_card_reset,
            cancelLabel: t.cancel,
            icon: FushiIcons.restart,
            destructive: true,
          ),
        );
        if (!ok) return;
        run = () => srsBatchResetCards(store, cardIds);
      case SrsBrowseBatchAction.setDue:
        final String? text = await _focusOwnership.guardOverlay(
          () => showFushiTextInputDialog(
            context: context,
            title: t.srs_browse_set_due,
            message: t.srs_browse_set_due_hint,
            hintText: '0, 3, 1-7',
            icon: FushiIcons.calendar,
            validator: (String v) =>
                v.trim().isEmpty || srsParseDueDays(v) != null
                ? null
                : t.srs_browse_set_due_invalid,
          ),
        );
        final (int, int)? range = text == null ? null : srsParseDueDays(text);
        if (range == null) return;
        run = () =>
            srsBatchSetDue(store, cardIds, from: range.$1, to: range.$2);
      case SrsBrowseBatchAction.delete:
        final bool ok = await _focusOwnership.guardOverlay(
          () => showFushiConfirmDialog(
            context: context,
            title: t.srs_browse_delete_notes,
            message: t.srs_browse_delete_confirm(n: noteIds.length),
            confirmLabel: t.srs_note_delete,
            cancelLabel: t.cancel,
            icon: FushiIcons.delete,
            destructive: true,
          ),
        );
        if (!ok) return;
        run = () => srsBatchDeleteNotes(store, noteIds);
      case SrsBrowseBatchAction.changeNoteType:
      case SrsBrowseBatchAction.migrateToFushiCard:
        final SrsChangeNoteTypeFlow? flow =
            action == SrsBrowseBatchAction.changeNoteType
            ? widget.onChangeNoteType
            : widget.onMigrateToFushiCard;
        if (flow == null) return;
        await _focusOwnership.guardOverlay(() => flow(context, noteIds));
        if (!mounted) return;
        bumpSrsRevision(ref);
        _revision++;
        await _reload();
        return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final SrsBatchOutcome out = await run();
      if (!mounted) return;
      if (out.changed == 0) {
        FushiToast.show(msg: t.srs_browse_nothing_changed);
      } else {
        if (out.revert != null) _undo.add(_UndoEntry(out.revert!));
        FushiToast.show(msg: doneMessage ?? t.srs_browse_done(n: out.changed));
      }
      bumpSrsRevision(ref);
      _revision++;
      await _reload();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.batch.${action.name}', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _undoLast() {
    if (_undo.isEmpty || _busy) return;
    srsRunLogged('SrsBrowse.undo', () async {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null || !mounted) return;
      final _UndoEntry entry = _undo.removeLast();
      setState(() => _busy = true);
      try {
        final int blocked = await entry.revert(store);
        FushiToast.show(
          msg: blocked > 0
              ? t.srs_browse_undo_partial(n: blocked)
              : t.srs_browse_undone,
          severity: blocked > 0 ? ToastSeverity.warning : ToastSeverity.neutral,
        );
        if (!mounted) return;
        bumpSrsRevision(ref);
        _revision++;
        await _reload();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  // ------------------------------------------------------------------ 键盘

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final KeyEventResult? lookup = _previewLookup.guardKey(event);
    if (lookup != null) return lookup;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    final bool ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      _queryFocus.requestFocus();
      return KeyEventResult.handled;
    }
    // 文本框持焦：方向键 / Enter / Ctrl+A / Ctrl+Z 都归文本编辑。
    if (_editingText) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent &&
        key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _undoLast();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyA) {
      _selectAll();
      return KeyEventResult.handled;
    }
    if (ctrl || kb.isAltPressed) return KeyEventResult.ignored;
    final bool wide =
        MediaQuery.sizeOf(context).width >= kSrsBrowseSplitMinWidth;
    switch (key) {
      case LogicalKeyboardKey.arrowDown:
        _setCurrent(math.max(0, _currentIndex + 1), extend: kb.isShiftPressed);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _setCurrent(math.max(0, _currentIndex - 1), extend: kb.isShiftPressed);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter ||
          LogicalKeyboardKey.numpadEnter ||
          LogicalKeyboardKey.gameButtonA:
        final int i = _currentIndex;
        if (i < 0) return KeyEventResult.ignored;
        if (wide) {
          setState(() => _showAnswer = !_showAnswer);
        } else {
          unawaited(_openPreviewPage(i));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (!_selecting) return KeyEventResult.ignored;
        _clearSelection();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
        if (_targets.isEmpty) return KeyEventResult.ignored;
        unawaited(_runBatch(SrsBrowseBatchAction.delete));
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ 界面

  String get _countText => _mode == SrsBrowseMode.cards
      ? t.srs_browse_count_cards(n: _items.length)
      : t.srs_browse_count(n: _items.length);

  List<FushiToolbarItem> _toolbarItems() => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_browse_undo'),
      icon: FushiIcons.undo,
      label: t.undo,
      tooltip: '${t.undo} (Ctrl+Z)',
      onPressed: _undo.isEmpty || _busy ? null : _undoLast,
    ),
    if (_selecting) ...<FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('srs_browse_select_all'),
        icon: FushiIcons.selectAll,
        label: t.srs_browse_select_all,
        tooltip: '${t.srs_browse_select_all} (Ctrl+A)',
        onPressed: _selectAll,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_browse_batch'),
        icon: FushiIcons.checklist,
        label: t.srs_browse_batch_actions,
        selected: true,
        onPressed: _selected.isEmpty || _busy
            ? null
            : () => srsRunLogged('SrsBrowse.batchMenu', _openBatchMenu),
      ),
    ] else
      FushiToolbarItem(
        key: const ValueKey<String>('srs_browse_select'),
        icon: FushiIcons.checklist,
        label: t.srs_browse_select,
        onPressed: () => setState(() => _selectMode = true),
      ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_browse_help'),
      icon: FushiIcons.help,
      label: t.srs_browse_search_help,
      onPressed: () => srsRunLogged(
        'SrsBrowse.help',
        () => _focusOwnership.guardOverlay(
          () => showSrsBrowseSearchHelp(context),
        ),
      ),
    ),
    FushiToolbarItem(
      icon: FushiIcons.refresh,
      label: t.refresh,
      onPressed: () => unawaited(_reload()),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final bool wide =
        MediaQuery.sizeOf(context).width >= kSrsBrowseSplitMinWidth;
    final Widget controls = _buildControls(context);
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: _selecting
            ? t.srs_browse_selected_count(n: _selected.length)
            : t.srs_browse_title,
        header: apple ? null : _buildTopBar(context),
        actions: apple
            ? <Widget>[
                for (final FushiToolbarItem item in _toolbarItems())
                  FushiIconButton(
                    key: item.key,
                    icon: item.icon,
                    tooltip: item.tooltip ?? item.label,
                    enabled: item.onPressed != null,
                    onTap: item.onPressed,
                  ),
              ]
            : const <Widget>[],
        headerBottom: apple ? controls : null,
        body: Builder(
          builder: (BuildContext context) {
            final Widget list = _buildList(context, apple ? null : controls);
            if (!wide) return list;
            return _buildSplit(context, list);
          },
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: _selecting
            ? t.srs_browse_selected_count(n: _selected.length)
            : t.srs_browse_title,
        subtitle: _countText,
        leading: <FushiToolbarItem>[
          if (_selecting)
            FushiToolbarItem(
              key: const ValueKey<String>('srs_browse_clear_selection'),
              icon: FushiIcons.close,
              label: t.srs_browse_select_none,
              onPressed: _clearSelection,
            )
          else if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_toolbarItems()],
      ),
    );
  }

  /// 搜索框 + 搜索范围 / 排序 / 方向 / 模式四个小按钮 + 搜索错误。
  Widget _buildControls(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? field = _searchField;
    final List<String> fieldNames = _snapshot?.fieldNames ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSearchField(
          key: const ValueKey<String>('srs-browse-search'),
          controller: _query,
          focusNode: _queryFocus,
          hintText: field == null
              ? t.srs_browse_search_syntax_hint
              : t.srs_browse_search_keyword_hint(field: field),
          onChanged: _onQueryChanged,
          onSubmitted: (_) => _requery(),
          onClear: _requery,
        ),
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiActionChip(
              key: const ValueKey<String>('srs-browse-field'),
              icon: FushiIcons.filterList,
              label: field ?? t.srs_browse_search_field_all,
              onPressed: () => srsRunLogged('SrsBrowse.field', () async {
                final String? picked = await _focusOwnership.guardOverlay(
                  () => pickSrsBrowseField(
                    context,
                    fieldNames: fieldNames,
                    selected: field,
                    title: t.srs_browse_search_field_label,
                  ),
                );
                if (picked == null || !mounted) return;
                setState(() {
                  _searchField = picked == kSrsBrowseAllFields ? null : picked;
                  _applyQuery();
                });
              }),
            ),
            FushiActionChip(
              key: const ValueKey<String>('srs-browse-sort'),
              icon: FushiIcons.sort,
              label: srsBrowseSortLabel(_sort),
              onPressed: () => srsRunLogged('SrsBrowse.sort', () async {
                final SrsBrowseSort? picked = await _focusOwnership
                    .guardOverlay(
                      () => pickSrsBrowseSort(
                        context,
                        current: _sort,
                        fieldNames: fieldNames,
                      ),
                    );
                if (picked == null || !mounted) return;
                setState(() {
                  _sort = picked;
                  _applyQuery();
                });
              }),
            ),
            FushiActionChip(
              key: const ValueKey<String>('srs-browse-direction'),
              icon: _sort.ascending ? FushiIcons.arrowUp : FushiIcons.arrowDown,
              label: _sort.ascending
                  ? t.srs_browse_sort_ascending
                  : t.srs_browse_sort_descending,
              onPressed: () => setState(() {
                _sort = _sort.copyWith(ascending: !_sort.ascending);
                _applyQuery();
              }),
            ),
            FushiActionChip(
              key: const ValueKey<String>('srs-browse-mode'),
              icon: _mode == SrsBrowseMode.cards
                  ? FushiIcons.ankiCard
                  : FushiIcons.viewAgenda,
              label: _mode == SrsBrowseMode.cards
                  ? t.srs_browse_mode_cards
                  : t.srs_browse_mode_notes,
              onPressed: () => setState(() {
                _mode = _mode == SrsBrowseMode.cards
                    ? SrsBrowseMode.notes
                    : SrsBrowseMode.cards;
                _selected.clear();
                _currentId = null;
                _applyQuery();
              }),
            ),
          ],
        ),
        if (_searchError != null)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap),
            child: Text(
              t.srs_browse_search_error(reason: _searchError!),
              key: const ValueKey<String>('srs-browse-search-error'),
              style: context.fushiType.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSplit(BuildContext context, Widget list) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int index = _currentIndex;
    final SrsBrowseItem? item = index < 0 ? null : _items[index];
    final EdgeInsets inset = MediaQuery.paddingOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(flex: 5, child: list),
        Expanded(
          flex: 6,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              tokens.spacing.gap + inset.top,
              tokens.spacing.page,
              tokens.spacing.section + inset.bottom,
            ),
            child: item == null
                ? Center(
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.ankiCard,
                      message: t.srs_browse_preview_empty,
                    ),
                  )
                : SrsBrowsePreview(
                    cardId: item.cardId,
                    revision: _revision,
                    showAnswer: _showAnswer,
                    position: '${index + 1} / ${_items.length}',
                    hasPrevious: index > 0,
                    hasNext: index < _items.length - 1,
                    onCommand: _onPreviewCommand,
                    onEdit: () => srsRunLogged(
                      'SrsBrowse.edit',
                      () => _editNote(item.noteId),
                    ),
                    lookup: _previewLookup,
                    onLookupClosed: () => _focusOwnership.reclaim(
                      FocusReclaimCause.overlayClosed,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, Widget? controls) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool wide =
        MediaQuery.sizeOf(context).width >= kSrsBrowseSplitMinWidth;
    final EdgeInsets padding = withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap + MediaQuery.paddingOf(context).top,
        tokens.spacing.page,
        tokens.spacing.section,
      ),
    );
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final int offset = controls == null ? 0 : 1;
    if (_items.isEmpty) {
      return ListView(
        padding: padding,
        children: <Widget>[
          if (controls != null) controls,
          SizedBox(height: tokens.spacing.section),
          FushiPlaceholderMessage(
            icon: FushiIcons.searchOff,
            message: t.srs_browse_empty,
          ),
        ],
      );
    }
    return FushiEntranceScope(
      replayKey: '${_query.text}|${_mode.name}',
      child: ListView.builder(
        controller: _scroll,
        padding: padding,
        itemCount: _items.length + offset,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (controls != null && i == 0) {
            return Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
              child: controls,
            );
          }
          final int index = i - offset;
          return _buildRow(context, index, wide: wide);
        }),
      ),
    );
  }

  Widget _buildRow(BuildContext context, int index, {required bool wide}) {
    final SrsBrowseItem item = _items[index];
    final SrsCardSearchSubject c = item.primary;
    final String id = _idOf(item);
    final bool selected = _selected.contains(id);
    final bool current = id == _currentId && (wide || _selecting);
    final bool cardsMode = _mode == SrsBrowseMode.cards;
    final String subtitleText = <String>[
      if (c.deckName.isNotEmpty) c.deckName,
      c.noteType.name,
      if (cardsMode) ...<String>[
        if (c.templateName.isNotEmpty) c.templateName,
      ] else
        t.srs_browse_count_cards(n: item.cards.length),
    ].join(' · ');
    // 卡片状态（新卡 / 已暂停 / 到期…）放在副标题行首的小标签里：拼在末尾时手机上
    // 牌组名 + 类型 + 模板就把一行占满，状态整个被省略号吃掉（截图巡检）。
    final Widget subtitle = cardsMode
        ? Row(
            children: <Widget>[
              FushiTag(
                key: ValueKey<String>('srs-browse-status-$id'),
                text: srsBrowseCardStatus(c),
                tone: srsBrowseCardStatusTone(c),
                dense: true,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  subtitleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          )
        : Text(subtitleText, maxLines: 1);
    final Color? flag = srsFlagColor(c.flag);
    final bool pending = c.note.hasPendingDecision;
    return FushiPressScale(
      child: FushiGroupedListItem(
        key: ValueKey<String>('srs-browse-row-$id'),
        index: index,
        count: _items.length,
        selected: current || selected,
        onTap: () => _onRowTap(index, wide: wide),
        onLongPress: () => _onRowLongPress(index),
        onSecondaryTap: () {
          if (!_selected.contains(id)) {
            setState(() {
              _selected
                ..clear()
                ..add(id);
              _currentId = id;
            });
          }
          srsRunLogged('SrsBrowse.contextMenu', _openBatchMenu);
        },
        child: FushiListItem(
          density: srsListDensityOf(context),
          selected: current || selected,
          leading: _selecting
              ? FushiCheckbox(
                  key: ValueKey<String>('srs-browse-check-$id'),
                  value: selected,
                  onChanged: (_) => _toggle(id),
                )
              : FushiListLeadingIcon(
                  pending ? FushiIcons.warning : FushiIcons.ankiCard,
                  tone: pending ? FushiCardTone.error : FushiCardTone.neutral,
                ),
          title: Text(c.sortText.isEmpty ? '—' : c.sortText),
          subtitle: subtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 卡片模式下「已暂停」已是行首状态标签，不再重复画图标占行尾宽度。
              if (c.isSuspended && !cardsMode)
                FushiIcon(
                  FushiIcons.pauseCircle,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              if (flag != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: FushiIcon(
                    FushiIcons.flag,
                    size: 18,
                    color: flag,
                    fill: 1,
                  ),
                ),
              if (!_selecting)
                FushiPopupMenuButton<int>(
                  tooltip: t.srs_deck_menu,
                  icon: const FushiIcon(FushiIcons.more),
                  onSelected: (int v) =>
                      srsRunLogged('SrsBrowse.rowMenu', () async {
                        switch (v) {
                          case 0:
                            await _editNote(item.noteId);
                          case 1:
                            if (wide) {
                              _setCurrent(index);
                            } else {
                              await _openPreviewPage(index);
                            }
                          case _:
                            setState(() {
                              _selectMode = true;
                              _selected.add(id);
                              _currentId = id;
                            });
                        }
                      }),
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
                    PopupMenuItem<int>(value: 0, child: Text(t.srs_note_edit)),
                    PopupMenuItem<int>(
                      value: 1,
                      child: Text(t.srs_browse_preview),
                    ),
                    PopupMenuItem<int>(
                      value: 2,
                      child: Text(t.srs_browse_select),
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
