/// 复习页：问题面 →「显示答案」→ 四个评分（带间隔预览）→ 下一张，直到当天做完。
///
/// - 键盘（只在本页焦点作用域里生效）：空格 / Enter = 显示答案，翻面后 = 「良好」；
///   1–4 = 四个评分；Ctrl+Z = 撤销；手柄 A 同 Enter。全局的裸空格中和
///   （`global_navigation.dart` 的 `_neutralizeBareSpace`）挂在根上，本页的
///   [Focus.onKeyEvent] 更近、先消费，所以空格只在复习页有「翻面 / 良好」的含义。
/// - WebView 卡面持有键盘焦点时，按键经键盘桥（[srsReviewKeyBridgeScript]）交回本页
///   同一个处理入口；焦点回收走 [PageFocusOwnership]（不裸调 requestFocus）。
/// - 卡面音频：当前卡所在牌组（取参数继承的 own 祖先，[SrsDeckTree.paramsOwner]）开着
///   「自动播放音频」时，出题 / 翻面自动按顺序播卡上的音频；「重播音频」随时手动再播（规则见
///   srs_card_autoplay.dart，对齐 Anki 按预设的 autoplay / replayq）。
/// - 撤销栈是会话级：撤评分调 [SrsDbStore.undo]（别的设备已复习过这张卡时返回
///   false，提示后丢掉这一步）；撤暂停 / 埋卡 / 旗标 / 移牌组 / 编辑 = 再写一次
///   改回原值。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_anki/fushi_anki_core.dart' show CardSourceLink;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_appearance_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 单次作答记入日志的最长用时（与 Anki「最长作答秒数」默认 60 秒同口径）：走神、
/// 切出去之类的长停顿不该把复习用时统计撑爆。
const int kSrsMaxAnswerDurationMs = 60000;

/// 评分按钮上的间隔文案：按界面语言给单位（文案照 Anki 答题按钮：英文 m / h / d /
/// mo / y，中文 分钟 / 小时 / 天 / 个月 / 年），不再让「1m」与「11.1mo」混着读。
String srsIntervalLabel(({String amount, SrsIntervalUnit unit}) p) =>
    switch (p.unit) {
      SrsIntervalUnit.minutes => t.srs_interval_minutes(n: p.amount),
      SrsIntervalUnit.hours => t.srs_interval_hours(n: p.amount),
      SrsIntervalUnit.days => t.srs_interval_days(n: p.amount),
      SrsIntervalUnit.months => t.srs_interval_months(n: p.amount),
      SrsIntervalUnit.years => t.srs_interval_years(n: p.amount),
    };

/// 撤销栈的一步。[logId] 非 null = 撤一条评分 / 重置日志；否则执行 [revert] 改回原值。
class _UndoStep {
  const _UndoStep({required this.cardId, this.logId, this.revert});

  final String cardId;
  final String? logId;
  final Future<void> Function(SrsDbStore store)? revert;
}

/// 预取好的下一张（数据层：详情 + 渲染结果）。
class _PrefetchedCard {
  const _PrefetchedCard({
    required this.detail,
    required this.rendered,
    required this.audioOwner,
  });

  final SrsCardDetail detail;
  final SrsRenderedCard? rendered;

  /// 这张卡的音频设置所在牌组（own 祖先）。
  final SrsDeckView? audioOwner;
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

/// 卡面缩放：每档 10%，范围 60%–200%。
const double _kZoomStep = 0.1;
const double _kZoomMin = 0.6;
const double _kZoomMax = 2.0;

class _SrsReviewPageState extends ConsumerState<SrsReviewPage> {
  /// 卡面缩放（Ctrl / ⌘ + 滚轮、Ctrl + 加减号 / 0）：原生区按倍率放大文字，WebView
  /// 走页面 `zoom`（随主题样式原地更新，不重放卡片）。持久化为偏好，下次打开沿用。
  void _setZoom(double value) {
    final double z =
        (value.clamp(_kZoomMin, _kZoomMax) * 20).roundToDouble() / 20;
    if ((z - ref.read(srsReviewZoomProvider)).abs() < 0.001) return;
    unawaited(ref.read(appProvider).setSrsReviewZoom(z));
  }

  void _zoomBy(double delta) =>
      _setZoom(ref.read(srsReviewZoomProvider) + delta);

  /// 滚轮一格放大 / 缩小一档（向上 = 放大，与浏览器一致）。
  void _zoomWheel(double deltaY) {
    if (deltaY == 0) return;
    _zoomBy(deltaY < 0 ? _kZoomStep : -_kZoomStep);
  }

  final FocusNode _focusNode = FocusNode(debugLabel: 'srs-review');
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    // 本页之上压着对话框 / 菜单 / 编辑页时不抢焦点。
    canOwn: (FocusReclaimCause cause) =>
        mounted && (ModalRoute.of(context)?.isCurrent ?? false),
  );

  /// 卡面查词（点词 / 悬停 → 查词弹窗，弹窗里继续嵌套查）。弹窗开着时空格 / Enter /
  /// 数字键不翻面、不评分（[SrsCardLookupController.guardKey]）。
  final SrsCardLookupController _lookup = SrsCardLookupController();

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

  /// 卡面音频的自动播放 / 重播序列（换卡、翻面、离开本页都会打断）。
  late final SrsCardAudioSequencer _audio = SrsCardAudioSequencer(
    ref.read(srsCardAudioOutputProvider),
  );

  /// 当前卡的音频设置来自哪个牌组（卡所在牌组的 own 祖先）；随换卡 / 改设置重读。
  SrsDeckView? _audioOwner;

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
    _lookup.dispose();
    srsRunLogged('SrsReviewPage.stopAudio', _audio.cancel);
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

  Future<SrsDeckSummary?> _deckSummary() async =>
      (await _store!.deckSummaries())
          .where((SrsDeckSummary s) => s.deck.id == widget.deckId)
          .firstOrNull;

  void _applyCounts(SrsDeckSummary? sum) {
    _newCount = sum?.newCount ?? 0;
    _learnCount = sum?.learnCount ?? 0;
    _reviewCount = sum?.reviewCount ?? 0;
  }

  Future<void> _refreshCounts() async => _applyCounts(await _deckSummary());

  /// 显示当前卡时在后台取好的「下一张」候选（只在评分后消费，见 [_loadNext]）。
  Future<_PrefetchedCard?>? _prefetch;

  /// 每显示一张卡 +1：后台补算（计数 / 预览）只落到它出发时的那张卡上。
  int _shownGeneration = 0;

  /// 后台预取「当前这张之外的下一张」并渲染好（数据层）。排程不变：真正的下一张
  /// 仍由评分后的 [SrsDbStore.nextCard] 决定，预取只是它的猜测，不一致就丢。
  void _startPrefetch(String currentCardId) {
    final SrsDbStore? store = _store;
    if (store == null) {
      _prefetch = null;
      return;
    }
    _prefetch = () async {
      try {
        final String? id = await store.nextCard(
          widget.deckId,
          exclude: <String>{currentCardId},
        );
        if (id == null) return null;
        final SrsCardDetail? detail = await store.cardDetail(id);
        if (detail == null) return null;
        final SrsRenderedCard? rendered = await store.renderCard(id);
        return _PrefetchedCard(
          detail: detail,
          rendered: rendered,
          audioOwner: await _audioOwnerOf(store, detail),
        );
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsReviewPage.prefetch', e, stack);
        return null;
      }
    }();
  }

  /// 预取的卡还能不能直接用：必须正是排程选出的 [id]，且卡片行没被改过
  /// （同步 / 别处写入改了它就按常规路径重取）。
  Future<_PrefetchedCard?> _takePrefetch(
    Future<_PrefetchedCard?>? pending,
    String id,
  ) async {
    if (pending == null) return null;
    final _PrefetchedCard? hit = await pending;
    if (hit == null || hit.detail.card.id != id) return null;
    final SrsCardCacheRow? row = await _store!.cardRow(id);
    return row == hit.detail.card ? hit : null;
  }

  /// 取下一张（或 [cardId] 指定的那张，撤销后回到被撤的卡）并显示问题面。
  ///
  /// [usePrefetch]：评分后的常规前进。排程选出的下一张正是预取的那张时直接显示
  /// 预取好的内容，计数 / 间隔预览随后在后台补齐（预览只在翻面后才看得到）。
  Future<void> _loadNext({String? cardId, bool usePrefetch = false}) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    final Future<_PrefetchedCard?>? pending = usePrefetch ? _prefetch : null;
    _prefetch = null;
    try {
      final String? id = cardId ?? await store.nextCard(widget.deckId);
      if (id == null) {
        await _refreshCounts();
        if (!mounted) return;
        setState(() {
          _loading = false;
          _finished = true;
          _detail = null;
          _rendered = null;
          _preview = null;
        });
        srsRunLogged('SrsReviewPage.stopAudio', _audio.cancel);
        return;
      }
      final _PrefetchedCard? hit = await _takePrefetch(pending, id);
      if (hit != null) {
        if (!mounted) return;
        _show(
          hit.detail,
          hit.rendered,
          preview: null,
          day: _day,
          audioOwner: hit.audioOwner,
        );
        unawaited(_completeShown(id, _shownGeneration));
        return;
      }
      await _refreshCounts();
      final SrsCardDetail? detail = await store.cardDetail(id);
      final SrsRenderedCard? rendered = await store.renderCard(id);
      final SrsDeckView? audioOwner = await _audioOwnerOf(store, detail);
      final SrsDayContext day = await store.dayContext();
      final SrsAnswerPreview? preview = store.canSchedule
          ? await store.preview(id)
          : null;
      if (!mounted) return;
      _show(
        detail,
        rendered,
        preview: preview,
        day: day,
        audioOwner: audioOwner,
      );
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

  /// 显示一张卡的问题面，并开始预取它之后的那张。
  void _show(
    SrsCardDetail? detail,
    SrsRenderedCard? rendered, {
    required SrsAnswerPreview? preview,
    required SrsDayContext? day,
    required SrsDeckView? audioOwner,
  }) {
    _shownGeneration++;
    // 换卡：上一张卡上查的词弹窗收起。
    _lookup.closeAll();
    setState(() {
      _loading = false;
      _finished = false;
      _error = null;
      _detail = detail;
      _rendered = rendered;
      _preview = preview;
      _day = day;
      _audioOwner = audioOwner;
      _showingAnswer = false;
    });
    _answerClock
      ..reset()
      ..start();
    _autoplayAudio();
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    if (detail != null) _startPrefetch(detail.card.id);
  }

  /// 预取命中后补齐计数与间隔预览（只落到仍在显示的那张卡上）。
  Future<void> _completeShown(String cardId, int generation) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    try {
      final SrsDeckSummary? sum = await _deckSummary();
      final SrsDayContext day = await store.dayContext();
      final SrsAnswerPreview? preview = store.canSchedule
          ? await store.preview(cardId)
          : null;
      if (!mounted || generation != _shownGeneration) return;
      setState(() {
        _applyCounts(sum);
        _day = day;
        _preview = preview;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsReviewPage.completeShown', e, stack);
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
    _autoplayAudio();
  }

  // ------------------------------------------------------------------ 卡面音频

  /// 卡的音频设置所在牌组：卡所在牌组的 own 祖先（与算法 / 记忆率同一条继承）。
  Future<SrsDeckView?> _audioOwnerOf(
    SrsDbStore store,
    SrsCardDetail? detail,
  ) async {
    if (detail == null) return null;
    final SrsDeckTree tree = await store.deckTree();
    final String deckId = tree[detail.card.deckId] != null
        ? detail.card.deckId
        : store.defaultDeckId;
    return tree[deckId] == null ? null : tree.paramsOwner(deckId);
  }

  /// 牌组没读到时按缺省（开），与 [SrsDeckView] 的缺省一致。
  bool get _autoplayEnabled => _audioOwner?.autoplayAudio ?? true;
  bool get _replayIncludesQuestion => _audioOwner?.replayQuestionAudio ?? true;

  /// 当前这一面的音频要不要自动播：开关关着时只打断上一张卡还在播的序列。
  void _autoplayAudio() {
    final SrsRenderedCard? rendered = _rendered;
    if (rendered == null || !_autoplayEnabled) {
      srsRunLogged('SrsReviewPage.stopAudio', _audio.cancel);
      return;
    }
    final List<String> names = srsAutoplaySounds(
      questionHtml: rendered.question,
      answerHtml: rendered.answer,
      answerSide: _showingAnswer,
    );
    srsRunLogged('SrsReviewPage.autoplay', () => _audio.play(names));
  }

  /// 手动「重播音频」该播的那几段（这一面没有音频时为空）。
  List<String> _replayNames({required bool includeQuestion}) {
    final SrsRenderedCard? rendered = _rendered;
    if (rendered == null) return const <String>[];
    return srsReplaySounds(
      questionHtml: rendered.question,
      answerHtml: rendered.answer,
      answerSide: _showingAnswer,
      includeQuestion: includeQuestion,
    );
  }

  void _replayAudio() {
    final List<String> names = _replayNames(
      includeQuestion: _replayIncludesQuestion,
    );
    srsRunLogged('SrsReviewPage.replay', () => _audio.play(names));
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
        await _loadNext(usePrefetch: true);
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
    final SrsDeckView? audioOwner = await _audioOwnerOf(store, fresh);
    if (!mounted) return;
    setState(() {
      _detail = fresh;
      _rendered = rendered;
      _audioOwner = audioOwner;
      _showingAnswer = showing;
    });
    // 编辑可能改了同一笔记的兄弟卡：预取作废重来。
    _startPrefetch(detail.card.id);
  }

  // ------------------------------------------------------------------ 键盘

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 查词弹窗开着：Esc 关一层，翻面 / 评分键吞掉。
    final KeyEventResult? lookup = _lookup.guardKey(event);
    if (lookup != null) return lookup;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _undoLast();
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd)) {
      _zoomBy(_kZoomStep);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      _zoomBy(-_kZoomStep);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (key == LogicalKeyboardKey.digit0 ||
            key == LogicalKeyboardKey.numpad0)) {
      _setZoom(1);
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
    if (_lookup.guardBridgeToken(token)) return;
    switch (token) {
      case 'Space' || 'Enter' || 'NumpadEnter':
        _primary();
      case 'Ctrl+KeyZ' || 'Meta+KeyZ':
        _undoLast();
      case 'Ctrl+Equal' || 'Ctrl+NumpadAdd' || 'Meta+Equal':
        _zoomBy(_kZoomStep);
      case 'Ctrl+Minus' || 'Ctrl+NumpadSubtract' || 'Meta+Minus':
        _zoomBy(-_kZoomStep);
      case 'Ctrl+Digit0' || 'Meta+Digit0':
        _setZoom(1);
      default:
        final String digit = token.substring(token.length - 1);
        final int? rating = int.tryParse(digit);
        if (rating != null && rating >= 1 && rating <= 4 && _showingAnswer) {
          _rate(rating);
        }
    }
  }

  /// 卡面里点了 Fushi 来源链接：跳回书 / 漫画 / 视频的对应位置。
  void _openSource(CardSourceLink link) {
    _lookup.closeAll();
    srsRunLogged(
      'SrsReview.openSource',
      () => openCardSource(ref: ref, link: link),
    );
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
    if (_detail != null &&
        _replayNames(includeQuestion: _replayIncludesQuestion).isNotEmpty)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_replay_audio'),
        icon: FushiIcons.replay,
        label: t.srs_review_replay_audio,
        onPressed: _replayAudio,
      ),
    if (_detail != null)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_edit'),
        icon: FushiIcons.edit,
        label: t.srs_note_edit,
        onPressed: () => unawaited(_onCardAction(_CardAction.edit)),
      ),
    if (_detail != null)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_browse'),
        icon: FushiIcons.search,
        label: t.srs_browse_title,
        onPressed: () => srsRunLogged('SrsReview.browse', _openBrowse),
      ),
  ];

  /// 像 Anki 一样从复习跳到浏览、直接落在正在复习的这张卡上（旁边就是预览与编辑）；
  /// 回来后按库里最新内容重载这张卡（浏览里可能改了它、挂起了它或删了它）。
  Future<void> _openBrowse() async {
    final SrsCardDetail? detail = _detail;
    if (detail == null) return;
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => SrsBrowsePage(
          initialCardId: detail.card.id,
          onChangeNoteType: showSrsChangeNoteTypeFlow,
          onMigrateToFushiCard: srsMigrateNotesToFushiCard,
        ),
      ),
    );
    if (mounted) await _reloadCurrent();
  }

  /// 卡面样式入口，按当前这张卡的笔记类型分流：Fushi 卡片 → 可视化外观页；其它类型 →
  /// 这张卡所用模板的编辑器（正面 / 背面 / 样式 + 预览，即 Anki 式的渲染规则自定义）。
  FushiToolbarItem? get _appearanceItem {
    final SrsCardDetail? detail = _detail;
    if (detail == null) return null;
    if (detail.noteType.builtinKey == kSrsBuiltinFushiCardKey) {
      return FushiToolbarItem(
        key: const ValueKey<String>('srs_review_appearance'),
        icon: FushiIcons.appearance,
        label: t.srs_card_appearance_title,
        onPressed: () => srsRunLogged(
          'SrsReview.appearance',
          () => openSrsCardAppearancePage(context),
        ),
      );
    }
    final SrsTemplateDef? tpl = detail.template;
    if (tpl == null) return null;
    return FushiToolbarItem(
      key: const ValueKey<String>('srs_review_edit_template'),
      icon: FushiIcons.appearance,
      label: t.srs_card_edit_template(name: detail.noteType.name),
      onPressed: () => srsRunLogged('SrsReview.editTemplate', () async {
        await Navigator.of(context).push<void>(
          adaptivePageRoute<void>(
            context: context,
            builder: (_) => SrsTemplateEditorPage(
              noteTypeId: detail.noteType.id,
              templateId: tpl.id,
            ),
          ),
        );
        if (mounted) bumpSrsRevision(ref);
      }),
    );
  }

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
          ?_appearanceItem,
          _hideHardEasyItem,
          ..._audioSettingItems(),
        ];

  /// 评分栏只留「重来 / 良好」的开关（对齐 AnkiDroid 的 hideHardAndEasy；键盘 2/4
  /// 照样有效）。勾选态 = 已隐藏；点了立即生效、写进按 profile 的偏好。
  FushiToolbarItem get _hideHardEasyItem {
    final bool hidden = ref.watch(srsReviewHideHardEasyProvider);
    return FushiToolbarItem(
      key: const ValueKey<String>('srs_review_hide_hard_easy'),
      icon: FushiIcons.visibilityOff,
      label: t.srs_review_hide_hard_easy,
      selected: hidden,
      onPressed: () => srsRunLogged(
        'SrsReview.hideHardEasy',
        () => ref.read(appProvider).setSrsReviewHideHardEasy(!hidden),
      ),
    );
  }

  /// 「牌组设置」：打开当前卡的音频 / 排程设置所在的牌组（own 祖先）。音频两项是
  /// 按牌组的（Anki 按预设），在这里改；回来后按新设置重读当前卡。
  List<FushiToolbarItem> _audioSettingItems() {
    final SrsDeckView? owner = _audioOwner;
    if (owner == null) return const <FushiToolbarItem>[];
    return <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_deck_settings'),
        icon: FushiIcons.settingsGear,
        label: t.srs_deck_settings,
        onPressed: () => srsRunLogged(
          'SrsReview.deckSettings',
          () => _openDeckSettings(owner.id),
        ),
      ),
    ];
  }

  Future<void> _openDeckSettings(String deckId) async {
    await _focusOwnership.guardOverlay(
      () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => SrsDeckSettingsPage(deckId: deckId),
        ),
      ),
    );
    if (!mounted) return;
    final bool wasAutoplay = _autoplayEnabled;
    await _reloadCurrent();
    // 刚打开自动播放：当前这一面立刻按新设置播；刚关掉：停掉正在自动播的。
    if (mounted && wasAutoplay != _autoplayEnabled) _autoplayAudio();
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
    final double zoom = ref.watch(srsReviewZoomProvider);
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
      fushiCard: detail.noteType.builtinKey == kSrsBuiltinFushiCardKey,
      pageZoom: zoom == 1 ? null : zoom,
      onZoomWheel: _zoomWheel,
      onSourceLink: _openSource,
    );
    final MediaQueryData media = MediaQuery.of(context);
    return SrsCardLookupHost(
      controller: _lookup,
      // 弹窗整栈关掉：焦点回复习页（WebView / 弹窗拿走过 OS 焦点）。
      onClosed: () => _focusOwnership.reclaim(FocusReclaimCause.overlayClosed),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              // Ctrl / ⌘ + 滚轮落在原生区（WebView 上的由页面脚本截下转来）：缩放卡面，
              // 并认领这次滚轮，外层不再滚动。
              child: Listener(
                onPointerSignal: (PointerSignalEvent event) {
                  if (event is! PointerScrollEvent) return;
                  final HardwareKeyboard kb = HardwareKeyboard.instance;
                  if (!kb.isControlPressed && !kb.isMetaPressed) return;
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (PointerSignalEvent e) =>
                        _zoomWheel((e as PointerScrollEvent).scrollDelta.dy),
                  );
                },
                child: FushiCard(
                  key: const ValueKey<String>('srs-card-surface'),
                  padding: EdgeInsets.zero,
                  pressScale: false,
                  // 内置 Fushi 卡片（模板未改）走原生 + 释义 WebView 的混合渲染；其余整面 WebView。
                  child: rendered?.fushiCardDefinitions != null
                      ? MediaQuery(
                          // 原生区跟随卡面缩放：在系统字号倍率上再乘缩放倍率。
                          data: media.copyWith(
                            textScaler: TextScaler.linear(
                              media.textScaler.scale(1) * zoom,
                            ),
                          ),
                          child: SrsFushiCardView(
                            key: const ValueKey<String>('srs-fushi-card-view'),
                            face: face,
                            fields: rendered!.fields,
                            definitionsHtml: rendered.fushiCardDefinitions!,
                          ),
                        )
                      : faceBuilder(context, face),
                ),
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
      ),
    );
  }

  Widget _buildRatingRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsAnswerPreview? preview = _preview;
    final SrsDayContext? day = _day;
    String interval(int rating) {
      if (preview == null || day == null) return '';
      return srsIntervalLabel(
        srsIntervalParts(
          preview.plan[rating],
          nowMs: preview.nowMs,
          today: day.dayIndexOf(preview.nowMs),
        ),
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

    // 只留「重来 / 良好」时两颗各占半行（对齐 AnkiDroid：不留空位）；key 随模式变，
    // 外层 AnimatedSwitcher 借此在两种布局间淡入淡出。
    final bool twoButtons = ref.watch(srsReviewHideHardEasyProvider);
    return Row(
      key: ValueKey<String>(
        twoButtons ? 'srs-rating-row-two' : 'srs-rating-row',
      ),
      spacing: tokens.spacing.gap,
      children: <Widget>[
        button(1, t.srs_rating_again, FushiCardTone.error),
        if (!twoButtons) button(2, t.srs_rating_hard, FushiCardTone.neutral),
        button(3, t.srs_rating_good, FushiCardTone.primary),
        if (!twoButtons) button(4, t.srs_rating_easy, FushiCardTone.tertiary),
      ],
    );
  }
}
