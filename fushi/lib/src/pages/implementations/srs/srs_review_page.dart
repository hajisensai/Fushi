/// 复习页：问题面 →「显示答案」→ 四个评分（带间隔预览）→ 下一张，直到当天做完。
///
/// - 键盘（只在本页焦点作用域里生效）：空格 / Enter = 显示答案，翻面后 = 「良好」；
///   1–4 = 四个评分；Ctrl+Z = 撤销；手柄 A 同 Enter。全局的裸空格中和
///   （`global_navigation.dart` 的 `_neutralizeBareSpace`）挂在根上，本页的
///   [Focus.onKeyEvent] 更近、先消费，所以空格只在复习页有「翻面 / 良好」的含义。
/// - WebView 卡面持有键盘焦点时，按键经键盘桥（[srsReviewKeyBridgeScript]）交回本页
///   同一个处理入口；焦点回收走 [PageFocusOwnership]（不裸调 requestFocus）。
/// - 撤销栈是会话级：撤评分调 [SrsDbStore.undo]（别的设备已复习过这张卡时返回
///   false，提示后丢掉这一步）；撤暂停 / 埋卡 / 旗标 / 移牌组 / 编辑 = 再写一次
///   改回原值。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 单次作答记入日志的最长用时（与 Anki「最长作答秒数」默认 60 秒同口径）：走神、
/// 切出去之类的长停顿不该把复习用时统计撑爆。
const int kSrsMaxAnswerDurationMs = 60000;

/// 撤销栈的一步。[logId] 非 null = 撤一条评分 / 重置日志；否则执行 [revert] 改回原值。
class _UndoStep {
  const _UndoStep({required this.cardId, this.logId, this.revert});

  final String cardId;
  final String? logId;
  final Future<void> Function(SrsDbStore store)? revert;
}

/// 卡片菜单动作。
enum _CardAction { edit, suspend, bury, flag, move, reset, deleteNote }

class SrsReviewPage extends ConsumerStatefulWidget {
  const SrsReviewPage({
    super.key,
    required this.deckId,
    required this.deckName,
  });

  final String deckId;
  final String deckName;

  @override
  ConsumerState<SrsReviewPage> createState() => _SrsReviewPageState();
}

class _SrsReviewPageState extends ConsumerState<SrsReviewPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'srs-review');
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    // 本页之上压着对话框 / 菜单 / 编辑页时不抢焦点。
    canOwn: (FocusReclaimCause cause) =>
        mounted && (ModalRoute.of(context)?.isCurrent ?? false),
  );

  SrsDbStore? _store;
  bool _loading = true;
  bool _busy = false;
  bool _finished = false;
  Object? _error;

  SrsCardDetail? _detail;
  SrsRenderedCard? _rendered;
  SrsAnswerPreview? _preview;
  SrsDayContext? _day;
  bool _showingAnswer = false;
  final Stopwatch _answerClock = Stopwatch();

  int _newCount = 0;
  int _learnCount = 0;
  int _reviewCount = 0;
  int _reviewedThisSession = 0;

  final List<_UndoStep> _undo = <_UndoStep>[];

  @override
  void initState() {
    super.initState();
    // 正在复习：自动优化让路（在跑的那一轮立即取消，见 srs_optimization_scheduler.dart）。
    srsActiveReviewSessions.value++;
    unawaited(_start());
  }

  @override
  void dispose() {
    srsActiveReviewSessions.value--;
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (!mounted) return;
    if (store == null) {
      setState(() {
        _loading = false;
        _error = t.srs_engine_unavailable;
      });
      return;
    }
    _store = store;
    await _loadNext();
  }

  Future<void> _refreshCounts() async {
    final SrsDbStore store = _store!;
    final SrsDeckSummary? sum = (await store.deckSummaries())
        .where((SrsDeckSummary s) => s.deck.id == widget.deckId)
        .firstOrNull;
    _newCount = sum?.newCount ?? 0;
    _learnCount = sum?.learnCount ?? 0;
    _reviewCount = sum?.reviewCount ?? 0;
  }

  /// 取下一张（或 [cardId] 指定的那张，撤销后回到被撤的卡）并显示问题面。
  Future<void> _loadNext({String? cardId}) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    try {
      final String? id = cardId ?? await store.nextCard(widget.deckId);
      await _refreshCounts();
      if (id == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _finished = true;
          _detail = null;
          _rendered = null;
          _preview = null;
        });
        return;
      }
      final SrsCardDetail? detail = await store.cardDetail(id);
      final SrsRenderedCard? rendered = await store.renderCard(id);
      final SrsDayContext day = await store.dayContext();
      final SrsAnswerPreview? preview = store.canSchedule
          ? await store.preview(id)
          : null;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _finished = false;
        _error = null;
        _detail = detail;
        _rendered = rendered;
        _preview = preview;
        _day = day;
        _showingAnswer = false;
      });
      _answerClock
        ..reset()
        ..start();
      _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsReviewPage.loadNext', e, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  /// 本页里的写操作统一入口：串行、出错留痕、写完通知其它页重读。
  Future<void> _guarded(String where, Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
      if (mounted) bumpSrsRevision(ref);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsReviewPage.$where', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showAnswer() {
    if (_detail == null || _showingAnswer) return;
    setState(() => _showingAnswer = true);
  }

  void _rate(int rating) {
    final SrsCardDetail? detail = _detail;
    final SrsDbStore? store = _store;
    if (detail == null || store == null || !_showingAnswer) return;
    if (!store.canSchedule) return;
    unawaited(
      _guarded('answer', () async {
        _answerClock.stop();
        // 不把显示问题面时算的预览传进去：预览的时刻是出题那一刻，日志的发生时刻
        // 必须是现在（学习步长按分钟算，差几十秒就差一档）。
        final SrsReviewLog log = await store.answer(
          detail.card.id,
          rating,
          durationMs: math.min(
            _answerClock.elapsedMilliseconds,
            kSrsMaxAnswerDurationMs,
          ),
        );
        _undo.add(_UndoStep(cardId: detail.card.id, logId: log.id));
        _reviewedThisSession++;
        await _loadNext();
      }),
    );
  }

  void _undoLast() {
    final SrsDbStore? store = _store;
    if (store == null || _undo.isEmpty) return;
    unawaited(
      _guarded('undo', () async {
        final _UndoStep step = _undo.removeLast();
        if (step.logId != null) {
          final bool ok = await store.undo(step.cardId, step.logId!);
          if (!ok) {
            FushiToast.show(
              msg: t.srs_review_undo_blocked,
              severity: ToastSeverity.warning,
            );
            return;
          }
          if (_reviewedThisSession > 0) _reviewedThisSession--;
        } else {
          await step.revert!(store);
        }
        await _loadNext(cardId: step.cardId);
      }),
    );
  }

  // ------------------------------------------------------------------ 卡片菜单

  Future<void> _onCardAction(_CardAction action) async {
    final SrsCardDetail? detail = _detail;
    final SrsDbStore? store = _store;
    if (detail == null || store == null) return;
    final SrsCardCacheRow card = detail.card;
    switch (action) {
      case _CardAction.edit:
        await _editNote(detail);
      case _CardAction.suspend:
        await _guarded('suspend', () async {
          await store.setSuspended(card.id, true);
          _undo.add(
            _UndoStep(
              cardId: card.id,
              revert: (SrsDbStore s) => s.setSuspended(card.id, false),
            ),
          );
          await _loadNext();
        });
      case _CardAction.bury:
        await _guarded('bury', () async {
          final SrsDayContext day = await store.dayContext();
          final int today = day.dayIndexOf(store.now().$1);
          final int? before = card.buriedUntilDay;
          await store.buryUntil(card.id, today + 1);
          _undo.add(
            _UndoStep(
              cardId: card.id,
              revert: (SrsDbStore s) => s.buryUntil(card.id, before),
            ),
          );
          await _loadNext();
        });
      case _CardAction.flag:
        final int? flag = await _focusOwnership.guardOverlay(
          () => showFushiChoiceDialog<int>(
            context: context,
            title: t.srs_card_flag,
            icon: FushiIcons.flag,
            selected: card.flag,
            options: <FushiChoiceOption<int>>[
              for (int f = 0; f <= 7; f++)
                FushiChoiceOption<int>(value: f, label: srsFlagLabel(f)),
            ],
          ),
        );
        if (flag == null || flag == card.flag || !mounted) return;
        await _guarded('flag', () async {
          final int before = card.flag;
          await store.setFlag(card.id, flag);
          _undo.add(
            _UndoStep(
              cardId: card.id,
              revert: (SrsDbStore s) => s.setFlag(card.id, before),
            ),
          );
          await _reloadCurrent();
        });
      case _CardAction.move:
        final List<SrsDeckSummary> decks = await store.deckSummaries();
        if (!mounted) return;
        final String? target = await _focusOwnership.guardOverlay(
          () => pickSrsDeck(
            context,
            decks: decks,
            selected: card.deckId,
            title: t.srs_card_move,
          ),
        );
        if (target == null || target == card.deckId || !mounted) return;
        await _guarded('move', () async {
          final String before = card.deckId;
          await store.moveCard(card.id, target);
          _undo.add(
            _UndoStep(
              cardId: card.id,
              revert: (SrsDbStore s) => s.moveCard(card.id, before),
            ),
          );
          await _loadNext();
        });
      case _CardAction.reset:
        final bool ok = await _focusOwnership.guardOverlay(
          () => showFushiConfirmDialog(
            context: context,
            title: t.srs_card_reset,
            message: t.srs_card_reset_confirm,
            confirmLabel: t.srs_card_reset,
            cancelLabel: t.cancel,
            icon: FushiIcons.restart,
            destructive: true,
          ),
        );
        if (!ok || !mounted) return;
        await _guarded('reset', () async {
          await store.resetCard(card.id);
          // 重置也是一条日志：撤销 = 撤这条日志。
          final String? logId = (await store.cardRow(card.id))?.lastLogId;
          if (logId != null) {
            _undo.add(_UndoStep(cardId: card.id, logId: logId));
          }
          await _loadNext();
        });
      case _CardAction.deleteNote:
        final bool ok = await _focusOwnership.guardOverlay(
          () => showFushiConfirmDialog(
            context: context,
            title: t.srs_note_delete,
            message: t.srs_note_delete_confirm,
            confirmLabel: t.srs_note_delete,
            cancelLabel: t.cancel,
            icon: FushiIcons.delete,
            destructive: true,
          ),
        );
        if (!ok || !mounted) return;
        await _guarded('deleteNote', () async {
          await store.deleteNote(detail.note.id);
          _undo.add(
            _UndoStep(
              cardId: card.id,
              revert: (SrsDbStore s) => s.restoreNote(detail.note.id),
            ),
          );
          await _loadNext();
        });
    }
  }

  /// 编辑笔记；有改动时压一步「改回原值」进撤销栈。
  Future<void> _editNote(SrsCardDetail detail) async {
    final Map<String, String> before = <String, String>{
      for (final SrsFieldDef f in detail.noteType.fields)
        f.id: detail.note.field(f.id),
    };
    final List<String> tagsBefore = List<String>.of(detail.note.tags);
    await _focusOwnership.guardOverlay(
      () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => SrsNoteEditorPage(noteId: detail.note.id),
        ),
      ),
    );
    if (!mounted) return;
    final SrsDbStore store = _store!;
    final SrsNoteView? after = await store.note(detail.note.id);
    if (after == null) return;
    final bool changed =
        before.entries.any(
          (MapEntry<String, String> e) => after.field(e.key) != e.value,
        ) ||
        after.tags.join('\u0000') != tagsBefore.join('\u0000');
    if (changed) {
      _undo.add(
        _UndoStep(
          cardId: detail.card.id,
          revert: (SrsDbStore s) => s.updateNote(
            detail.note.id,
            fieldsById: before,
            tags: tagsBefore,
          ),
        ),
      );
    }
    bumpSrsRevision(ref);
    await _reloadCurrent();
  }

  /// 原地刷新当前这张（编辑 / 改旗标后），保持正反面状态。
  Future<void> _reloadCurrent() async {
    final SrsCardDetail? detail = _detail;
    final SrsDbStore? store = _store;
    if (detail == null || store == null) return;
    final SrsCardCacheRow? row = await store.cardRow(detail.card.id);
    // 改完变成空卡 / 被删：直接下一张。
    if (row == null || row.hidden) {
      await _loadNext();
      return;
    }
    final bool showing = _showingAnswer;
    final SrsCardDetail? fresh = await store.cardDetail(detail.card.id);
    final SrsRenderedCard? rendered = await store.renderCard(detail.card.id);
    if (!mounted) return;
    setState(() {
      _detail = fresh;
      _rendered = rendered;
      _showingAnswer = showing;
    });
  }

  // ------------------------------------------------------------------ 键盘

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _undoLast();
      return KeyEventResult.handled;
    }
    if (ctrl ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _primary();
      return KeyEventResult.handled;
    }
    final int? rating = _ratingOfKey(key);
    if (rating != null && _showingAnswer) {
      _rate(rating);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _ratingOfKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      return 1;
    }
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      return 2;
    }
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      return 3;
    }
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
      return 4;
    }
    return null;
  }

  /// 空格 / Enter / 手柄 A：问题面 → 显示答案；答案面 →「良好」。
  void _primary() {
    if (_showingAnswer) {
      _rate(3);
    } else {
      _showAnswer();
    }
  }

  /// WebView 持焦时经键盘桥回传的 token。
  void _onBridgeKey(String token) {
    switch (token) {
      case 'Space' || 'Enter' || 'NumpadEnter':
        _primary();
      case 'Ctrl+KeyZ' || 'Meta+KeyZ':
        _undoLast();
      default:
        final String digit = token.substring(token.length - 1);
        final int? rating = int.tryParse(digit);
        if (rating != null && rating >= 1 && rating <= 4 && _showingAnswer) {
          _rate(rating);
        }
    }
  }

  // ------------------------------------------------------------------ 界面

  String get _countsText =>
      '${t.srs_count_new} $_newCount · ${t.srs_count_learn} $_learnCount · '
      '${t.srs_count_review} $_reviewCount';

  bool get _pendingDecision => _detail?.note.hasPendingDecision ?? false;

  void _openPendingNote() {
    final SrsCardDetail? detail = _detail;
    if (detail == null) return;
    unawaited(_editNote(detail));
  }

  List<FushiToolbarItem> _actionItems() => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_review_undo'),
      icon: FushiIcons.undo,
      label: t.undo,
      tooltip: '${t.undo} (Ctrl+Z)',
      onPressed: _undo.isEmpty || _busy ? null : _undoLast,
    ),
    if (_pendingDecision)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_pending'),
        icon: FushiIcons.warning,
        label: t.srs_review_pending_decision,
        selected: true,
        onPressed: _openPendingNote,
      ),
    if (_detail != null)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_edit'),
        icon: FushiIcons.edit,
        label: t.srs_note_edit,
        onPressed: () => unawaited(_onCardAction(_CardAction.edit)),
      ),
  ];

  List<FushiToolbarItem> _menuItems() => _detail == null
      ? const <FushiToolbarItem>[]
      : <FushiToolbarItem>[
          FushiToolbarItem(
            icon: FushiIcons.pause,
            label: t.srs_card_suspend,
            onPressed: () => unawaited(_onCardAction(_CardAction.suspend)),
          ),
          FushiToolbarItem(
            icon: FushiIcons.schedule,
            label: t.srs_card_bury,
            onPressed: () => unawaited(_onCardAction(_CardAction.bury)),
          ),
          FushiToolbarItem(
            icon: FushiIcons.flag,
            label: t.srs_card_flag,
            onPressed: () => unawaited(_onCardAction(_CardAction.flag)),
          ),
          FushiToolbarItem(
            icon: FushiIcons.moveFile,
            label: t.srs_card_move,
            onPressed: () => unawaited(_onCardAction(_CardAction.move)),
          ),
          FushiToolbarItem(
            icon: FushiIcons.restart,
            label: t.srs_card_reset,
            onPressed: () => unawaited(_onCardAction(_CardAction.reset)),
          ),
          FushiToolbarItem(
            icon: FushiIcons.delete,
            label: t.srs_note_delete,
            onPressed: () => unawaited(_onCardAction(_CardAction.deleteNote)),
          ),
        ];

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
        title: widget.deckName,
        subtitle: _finished ? '' : _countsText,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              key: const ValueKey<String>('srs_review_back'),
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_actionItems()],
        overflow: _menuItems(),
      ),
    );
  }

  List<Widget> _buildAppleActions() => <Widget>[
    for (final FushiToolbarItem item in <FushiToolbarItem>[
      ..._actionItems(),
      ..._menuItems(),
    ])
      FushiIconButton(
        key: item.key,
        icon: item.icon,
        tooltip: item.tooltip ?? item.label,
        enabled: item.onPressed != null,
        selected: item.selected,
        onTap: item.onPressed,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: widget.deckName,
        header: apple ? null : _buildTopBar(context),
        actions: apple ? _buildAppleActions() : const <Widget>[],
        headerBottom: apple && !_finished
            ? SrsCountTriple(
                newCount: _newCount,
                learnCount: _learnCount,
                reviewCount: _reviewCount,
                dense: true,
              )
            : null,
        body: Builder(
          builder: (BuildContext context) => Padding(
            // 正文从浮动页头底下开始：卡面是 WebView（不能滚到页头下面），整体让位。
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              child: KeyedSubtree(
                key: ValueKey<String>(
                  _loading
                      ? 'loading'
                      : _error != null
                      ? 'error'
                      : _finished
                      ? 'finished'
                      : 'review',
                ),
                child: _buildBody(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const FushiLoadingView();
    final Object? error = _error;
    if (error != null) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: t.error_load_failed,
          detail: '$error',
        ),
      );
    }
    if (_finished) return _buildFinished(context);
    final SrsDbStore store = _store!;
    if (!store.canSchedule) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.warning,
          tone: FushiPlaceholderTone.error,
          message: t.srs_engine_unavailable,
        ),
      );
    }
    return _buildCard(context);
  }

  Widget _buildFinished(BuildContext context) {
    final NavigatorState navigator = Navigator.of(context);
    return FushiEntranceScope(
      child: Center(
        child: FushiStaggeredEntrance(
          index: 0,
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('srs-review-finished'),
            icon: FushiIcons.success,
            message: t.srs_review_done,
            detail: t.srs_review_done_detail(n: _reviewedThisSession),
            action: Wrap(
              spacing: FushiDesignTokens.of(context).spacing.gap,
              children: <Widget>[
                if (_undo.isNotEmpty)
                  FushiOutlinedButton.icon(
                    onPressed: _busy ? null : _undoLast,
                    icon: const FushiIcon(FushiIcons.undo),
                    label: Text(t.undo),
                  ),
                if (navigator.canPop())
                  FushiFilledButton.tonalIcon(
                    onPressed: () => unawaited(navigator.maybePop()),
                    icon: const FushiIcon(FushiIcons.back),
                    label: Text(t.srs_review_back_to_decks),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardDetail detail = _detail!;
    final SrsRenderedCard? rendered = _rendered;
    final SrsCardFaceBuilder faceBuilder = ref.watch(
      srsCardFaceBuilderProvider,
    );
    final String language = ref.read(appProvider).defaultContentLanguage;
    final SrsCardFace face = SrsCardFace(
      cardId: detail.card.id,
      showingAnswer: _showingAnswer,
      bodyHtml: rendered == null
          ? ''
          : _showingAnswer
          ? rendered.answer
          : rendered.question,
      css: rendered?.css ?? '',
      languageCode: language.isEmpty ? null : language,
      onBridgeKey: _onBridgeKey,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: FushiCard(
              key: const ValueKey<String>('srs-card-surface'),
              padding: EdgeInsets.zero,
              pressScale: false,
              child: faceBuilder(context, face),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap * 1.5,
              tokens.spacing.page,
              tokens.spacing.gap * 1.5,
            ),
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              child: _showingAnswer
                  ? _buildRatingRow(context)
                  : SizedBox(
                      key: const ValueKey<String>('srs-show-answer-row'),
                      width: double.infinity,
                      child: FushiFilledButton(
                        key: const ValueKey<String>('srs-show-answer'),
                        onPressed: _busy ? null : _showAnswer,
                        child: Text(t.srs_review_show_answer),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRatingRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsAnswerPreview? preview = _preview;
    final SrsDayContext? day = _day;
    String interval(int rating) {
      if (preview == null || day == null) return '';
      return srsFormatInterval(
        preview.plan[rating],
        nowMs: preview.nowMs,
        today: day.dayIndexOf(preview.nowMs),
      );
    }

    Widget button(int rating, String label, FushiCardTone tone) => Expanded(
      child: FushiCard(
        key: ValueKey<String>('srs-rate-$rating'),
        tone: tone,
        padding: EdgeInsets.symmetric(
          vertical: tokens.spacing.gap * 1.5,
          horizontal: tokens.spacing.gap,
        ),
        onTap: _busy ? null : () => _rate(rating),
        child: FushiTooltip(
          message: '$label ($rating)',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                interval(rating),
                style: context.fushiType.labelMedium,
                maxLines: 1,
              ),
              Text(
                label,
                style: context.fushiType.labelLargeEmphasized,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );

    return Row(
      key: const ValueKey<String>('srs-rating-row'),
      spacing: tokens.spacing.gap,
      children: <Widget>[
        button(1, t.srs_rating_again, FushiCardTone.error),
        button(2, t.srs_rating_hard, FushiCardTone.neutral),
        button(3, t.srs_rating_good, FushiCardTone.primary),
        button(4, t.srs_rating_easy, FushiCardTone.tertiary),
      ],
    );
  }
}
