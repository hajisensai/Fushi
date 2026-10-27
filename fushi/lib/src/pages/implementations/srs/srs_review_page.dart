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
import 'dart:ui' show FlutterView, ViewFocusDirection, ViewFocusState;

import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerDownEvent,
        PointerScrollEvent,
        PointerSignalEvent,
        kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_anki/fushi_anki_core.dart' show CardSourceLink;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/anki/card_source_origin.dart'
    show cardSourceKindIcon, cardSourceLinkOfFields;
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
import 'package:fushi/src/pages/implementations/srs/srs_review_layout_sheet.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_card_media.dart' show srsMediaNameFromUrl;
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
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

  /// 集成测试探针：打开首张卡的各阶段（null = 不记）。
  @visibleForTesting
  static void Function(String phase)? debugPhase;

  /// 把 OS 键盘焦点交回 Flutter 视图（测试覆写以观察调用）。
  ///
  /// 生产实现 = `PlatformDispatcher.requestViewFocusChange`，引擎据此 `SetFocus(FlutterView)`。
  @visibleForTesting
  static void Function(FlutterView view) requestNativeViewFocus =
      _requestNativeViewFocus;

  static void _requestNativeViewFocus(FlutterView view) =>
      WidgetsBinding.instance.platformDispatcher.requestViewFocusChange(
        viewId: view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.undefined,
      );

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

  /// 悬浮顶栏（[srsReviewChromeFloatingProvider]，默认开）当前是否被唤出。默认收起；
  /// 点卡面空白 / 右键在唤出与收起间切换，不自动收起（与小说、漫画阅读器同一口径：
  /// 点击是唯一的开关）。固定页头时不用它。
  bool _chromeShown = false;

  SrsCardDetail? _detail;
  SrsRenderedCard? _rendered;
  SrsAnswerPreview? _preview;
  SrsDayContext? _day;
  bool _showingAnswer = false;
  final Stopwatch _answerClock = Stopwatch();

  int _newCount = 0;
  int _learnCount = 0;
  int _reviewCount = 0;

  /// 牌组当前的全名（随计数一起现读；复习中在牌组设置里改了名立即换标题）。
  String? _deckTitle;

  String get _title => _deckTitle ?? widget.deckName;
  int _reviewedThisSession = 0;

  final List<_UndoStep> _undo = <_UndoStep>[];

  /// 卡面音频的自动播放 / 重播序列（换卡、翻面、离开本页都会打断）。
  ///
  /// 在 [initState] 里建好：以前是惰性初始化，首张卡还没出来就离开本页时它第一次被读是在
  /// [dispose] 里，`ref.read` 在卸载中抛错，`super.dispose()` 被跳过、State 永远 mounted。
  late final SrsCardAudioSequencer _audio;

  /// 当前卡的音频设置来自哪个牌组（卡所在牌组的 own 祖先）；随换卡 / 改设置重读。
  SrsDeckView? _audioOwner;

  /// 按 [cause] 收回键盘焦点，并把 **OS** 焦点一并拉回 Flutter 视图（#8）。
  ///
  /// 卡面 / 释义 / 查词弹窗都是原生 WebView2：指针点进去后 OS 焦点留在 WebView2，而
  /// Flutter 这边的焦点仍认为在本页（WebView 平台视图自带的 Flutter 焦点节点就在本页
  /// 子树里，`custom_platform_view.dart` 按下即 requestFocus）。这时 [PageFocusOwnership.reclaim]
  /// 的 `requestFocus` 只在 Flutter 内部挪节点，视图焦点状态没变、引擎不会 `SetFocus`，
  /// 按键继续发给那个 WebView2。卡面可见时页内键盘桥还能把空格交回来；可一旦那个
  /// WebView2 已经不在屏上——评分换卡后原生卡面的释义 WebView 进了正面的 Offstage
  /// 预热位、查词弹窗关掉后停进热槽——它的文档收不到可见交互，空格就此失灵，直到用户点
  /// 一下窗口（激活窗口时宿主把焦点交回 FlutterView）。所以换卡 / 弹窗关掉这两个点，
  /// 在判据放行后显式请求视图焦点；主窗不在前台时不请求（[DesktopForegroundGuard]，
  /// 免得把主窗抬到别的程序之上，BUG-1619）。
  ///
  /// 2026-10-23 Windows 实测（`integration_test/srs_review_os_focus_itest.dart`，读
  /// `GetGUIThreadInfo.hwndFocus`）：卡面 / 释义 WebView 走 composition 宿主，指针经插件
  /// `SendMouseInput` 转发，点进去后 OS 焦点**仍在 FLUTTERVIEW**，上面那条「OS 焦点留在
  /// WebView2」的链在当前宿主下不成立；评分换卡后 Flutter 焦点由 [PageFocusOwnership]
  /// 收回本页，真投递的空格照常翻面（去掉下面的视图焦点请求同样通过）。请求保留为窗口
  /// 宿主模式（`--fushi-windowed-hosting`，WebView2 是真子窗口）下的防护，代价是一次
  /// 空操作的 SetFocus。
  void _reclaim(FocusReclaimCause cause) {
    if (!_focusOwnership.reclaim(cause)) return;
    if (!DesktopForegroundGuard.isMainWindowForeground()) return;
    final FlutterView? view = View.maybeOf(context);
    if (view != null) SrsReviewPage.requestNativeViewFocus(view);
  }

  /// 下一帧结束后 [_reclaim]（换卡后卡面先 build 完）。`addPostFrameCallback` 本身不排帧，
  /// 树静止时要 [WidgetsBinding.ensureVisualUpdate] 把帧要出来（BUG-1168）。
  void _reclaimAfterFrame(FocusReclaimCause cause) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reclaim(cause);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 当前卡上引用了、但媒体库里没有的文件（换卡后异步探一次）：不给它们出重播键，自动
  /// 播放也跳过（#15）。
  Set<String> _missingMedia = const <String>{};

  @override
  void initState() {
    super.initState();
    _audio = SrsCardAudioSequencer(ref.read(srsCardAudioOutputProvider));
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
    SrsReviewPage.debugPhase?.call('store');
    await _loadNext();
  }

  Future<SrsDeckSummary?> _deckSummary() => _store!.deckSummary(widget.deckId);

  void _applyCounts(SrsDeckSummary? sum) {
    _newCount = sum?.newCount ?? 0;
    _learnCount = sum?.learnCount ?? 0;
    _reviewCount = sum?.reviewCount ?? 0;
    _deckTitle = sum?.fullName;
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
        SrsReviewPage.debugPhase?.call('prefetch:begin');
        final String? id = await store.nextCard(
          widget.deckId,
          exclude: <String>{currentCardId},
        );
        SrsReviewPage.debugPhase?.call('prefetch:nextCard');
        if (id == null) return null;
        final SrsCardDetail? detail = await store.cardDetail(id);
        SrsReviewPage.debugPhase?.call('prefetch:detail');
        if (detail == null) return null;
        final SrsRenderedCard? rendered = await store.renderCard(
          id,
          detail: detail,
        );
        SrsReviewPage.debugPhase?.call('prefetch:render');
        // 卡面预处理（媒体改写、抽样式、样式哈希）趁出题间隙算好，换卡时全命中。
        if (rendered != null) {
          srsWarmCardFace(
            css: rendered.css,
            bodies: <String>[
              rendered.question,
              rendered.answer,
              ?rendered.fushiCardDefinitions,
            ],
          );
          SrsReviewPage.debugPhase?.call('prefetch:warm');
        }
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
      SrsReviewPage.debugPhase?.call('nextCard');
      await _refreshCounts();
      SrsReviewPage.debugPhase?.call('counts');
      final SrsCardDetail? detail = await store.cardDetail(id);
      final SrsRenderedCard? rendered = detail == null
          ? null
          : await store.renderCard(id, detail: detail);
      SrsReviewPage.debugPhase?.call('render');
      if (detail == null) {
        // 排程选中的卡读不到（例如刚被同步删掉）：报错，不把 null 当「还在读」——
        // 加载指示只认 detail == null，静默转圈且「显示答案」永远禁用。
        throw StateError('SrsReviewPage: scheduled card $id has no detail');
      }
      final SrsDeckView? audioOwner = await _audioOwnerOf(store, detail);
      if (!mounted) return;
      // 问题面只要卡片内容：间隔预览（只在翻面后的评分键上）与日界在卡面上屏后补齐，
      // 与预取命中同一条路径（[_completeShown]），不挡首张卡。
      _show(detail, rendered, preview: null, day: _day, audioOwner: audioOwner);
      unawaited(_completeShown(id, _shownGeneration));
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
    SrsReviewPage.debugPhase?.call('show');
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
      _missingMedia = const <String>{};
    });
    unawaited(_probeMedia(_shownGeneration));
    _answerClock
      ..reset()
      ..start();
    _autoplayAudio();
    _reclaimAfterFrame(FocusReclaimCause.contentReady);
    if (detail != null) _startPrefetch(detail.card.id);
  }

  /// 预取命中后补齐计数与间隔预览（只落到仍在显示的那张卡上）。
  Future<void> _completeShown(String cardId, int generation) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    try {
      final SrsDeckSummary? sum = await _deckSummary();
      SrsReviewPage.debugPhase?.call('deckSummary');
      final SrsDayContext day = await store.dayContext();
      final SrsAnswerPreview? preview = store.canSchedule
          ? await store.preview(cardId)
          : null;
      SrsReviewPage.debugPhase?.call('preview');
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

  /// 本页里的写操作统一入口：串行、出错留痕、写完通知互联推送。
  ///
  /// 只发 [bumpSrsLocalWrite]，不发 [bumpSrsRevision]：本页压在牌组列表 / 首页之上，叫醒它们
  /// 就是每评一张卡整库重算一遍计数、把看不见的列表整页重建两三次，正撞在下一张卡上屏的那几帧
  /// （实测 Windows debug：每次评分 1.5 s 内重建约 9500 个 element，其中约 7000 个是被盖住的
  /// 牌组列表）。三个入口在本页返回时各发一次 [bumpSrsRevision]。
  Future<void> _guarded(String where, Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
      if (mounted) bumpSrsLocalWrite(ref);
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

  /// 一张卡两面的媒体清单（问题面、答案面，按卡面从上到下的顺序，保留重复以便按次数
  /// 扣掉 `{{FrontSide}}` 带过来的）。
  ///
  /// 原生 Fushi 卡面按字段取它**实际画出来**的发音键与片段（[srsFushiCardMedia]）——不再扫
  /// 整面答案 HTML：释义区里词典自带的音频、模板复制的多份容器都不是卡面上的按钮（#15）。
  /// 整面 WebView 卡面按 Anki 的 `[sound:]` 标记。
  ({List<String> question, List<String> answer}) _mediaOf(
    SrsRenderedCard rendered,
  ) {
    if (rendered.fushiCardDefinitions != null) {
      final SrsFushiCardMedia media = srsFushiCardMedia(
        rendered.fields,
        audioCardFront:
            srsFushiFrontKind(rendered.fields) == SrsFushiFrontKind.audio,
      );
      return (question: media.front, answer: media.back);
    }
    return (
      question: srsCardSoundNames(rendered.question),
      answer: srsCardSoundNames(rendered.answer),
    );
  }

  /// 去掉媒体库里没有的文件。
  List<String> _present(List<String> names) => <String>[
    for (final String n in names)
      if (!_missingMedia.contains(n)) n,
  ];

  /// 换卡 / 重载后探一次这张卡引用的媒体在不在库里（经播放出口解析，与真正开播同一判据）。
  Future<void> _probeMedia(int generation) async {
    final SrsRenderedCard? rendered = _rendered;
    if (rendered == null) return;
    final ({List<String> question, List<String> answer}) m = _mediaOf(rendered);
    final SrsCardAudioOutput output = ref.read(srsCardAudioOutputProvider);
    final Set<String> missing = <String>{};
    try {
      for (final String name in <String>{...m.question, ...m.answer}) {
        if (await output.resolve(name) == null) missing.add(name);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsReviewPage.probeMedia', e, stack);
      return;
    }
    if (!mounted || generation != _shownGeneration) return;
    if (missing.length == _missingMedia.length &&
        missing.containsAll(_missingMedia)) {
      return;
    }
    setState(() => _missingMedia = missing);
  }

  /// 卡面上的发音键 / 底栏逐段键：交给同一个序列（新的一段打断上一段，同一时刻只出一路
  /// 声音，#10）。
  void _playNames(List<String> names) =>
      srsRunLogged('SrsReviewPage.play', () => _audio.play(names));

  /// 当前这一面的音频要不要自动播：开关关着时只打断上一张卡还在播的序列。
  void _autoplayAudio() {
    final SrsRenderedCard? rendered = _rendered;
    if (rendered == null || !_autoplayEnabled) {
      srsRunLogged('SrsReviewPage.stopAudio', _audio.cancel);
      return;
    }
    final ({List<String> question, List<String> answer}) m = _mediaOf(rendered);
    final List<String> names = _present(
      srsAutoplayOf(
        question: m.question,
        answer: m.answer,
        answerSide: _showingAnswer,
      ),
    );
    srsRunLogged('SrsReviewPage.autoplay', () => _audio.play(names));
  }

  /// 手动「重播音频」该播的那几段（这一面没有音频时为空）。
  List<String> _replayNames({
    required bool includeQuestion,
    bool answerSide = false,
  }) {
    final SrsRenderedCard? rendered = _rendered;
    if (rendered == null) return const <String>[];
    final ({List<String> question, List<String> answer}) m = _mediaOf(rendered);
    return _present(
      srsReplayOf(
        question: m.question,
        answer: m.answer,
        answerSide: answerSide || _showingAnswer,
        includeQuestion: includeQuestion,
      ),
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
        SrsReviewPage.debugPhase?.call('answer:begin');
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
        SrsReviewPage.debugPhase?.call('answer:done');
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

  /// 原地刷新当前这张（编辑 / 浏览 / 牌组设置回来后），保持正反面状态。
  ///
  /// 除了卡面内容与音频设置，间隔预览、顶栏计数与标题也现读（BUG-3547）：它们是本页
  /// 在出题时算好缓存的，牌组设置改了学习步长 / 记忆率 / 最大间隔 / 每日上限 / 名字，
  /// 浏览里改了期，都会让缓存值过期——原先只刷卡面，评分按钮上的间隔仍是旧设置算的。
  Future<void> _reloadCurrent() async {
    final SrsCardDetail? detail = _detail;
    final SrsDbStore? store = _store;
    if (detail == null || store == null) return;
    // 刷新途中已换了卡（评分 / 撤销）：旧卡的结果不能盖回去。
    final int generation = _shownGeneration;
    final String id = detail.card.id;
    final SrsCardCacheRow? row = await store.cardRow(id);
    if (!mounted || generation != _shownGeneration) return;
    // 改完变成空卡 / 被删：直接下一张。
    if (row == null || row.hidden) {
      await _loadNext();
      return;
    }
    final SrsCardDetail? fresh = await store.cardDetail(id);
    final SrsRenderedCard? rendered = fresh == null
        ? null
        : await store.renderCard(id, detail: fresh);
    final SrsDeckView? audioOwner = await _audioOwnerOf(store, fresh);
    final SrsDeckSummary? sum = await _deckSummary();
    final SrsDayContext day = await store.dayContext();
    final SrsAnswerPreview? preview = store.canSchedule
        ? await store.preview(id)
        : null;
    if (!mounted || generation != _shownGeneration) return;
    setState(() {
      _detail = fresh;
      _rendered = rendered;
      _audioOwner = audioOwner;
      _applyCounts(sum);
      _day = day;
      _preview = preview;
    });
    unawaited(_probeMedia(generation));
    // 编辑可能改了同一笔记的兄弟卡、设置可能改了下一张的音频设置：预取作废重来。
    _startPrefetch(id);
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
    if (key == LogicalKeyboardKey.keyR) {
      // 重播音频（对齐 Anki 的 R）。
      _replayAudio();
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
      case 'KeyR':
        _replayAudio();
      default:
        final String digit = token.substring(token.length - 1);
        final int? rating = int.tryParse(digit);
        if (rating != null && rating >= 1 && rating <= 4 && _showingAnswer) {
          _rate(rating);
        }
    }
  }

  /// 当前卡笔记里的出处链接（制卡时写进来源字段的 `fushi://source`）。顶栏「回到
  /// 出处」按它显示——不依赖卡面模板是否把来源字段渲染出来。
  CardSourceLink? get _currentSourceLink {
    final SrsCardDetail? detail = _detail;
    return detail == null
        ? null
        : cardSourceLinkOfFields(detail.note.fields.values);
  }

  /// 卡面里点了 Fushi 来源链接 / 顶栏「回到出处」：跳回书 / 漫画 / 视频 / 游戏 /
  /// 音乐的对应位置。
  void _openSource(CardSourceLink link) {
    _lookup.closeAll();
    srsRunLogged(
      'SrsReview.openSource',
      () => openCardSource(ref: ref, link: link),
    );
  }

  /// WebView 卡面里点了图片（[SrsCardFace.onImageTap]）：页内地址换回媒体名，用原生卡
  /// 那个可缩放的全屏查看；关掉后焦点回复习页（WebView 拿走过 OS 焦点）。
  void _viewCardImage(String src) {
    final Uri? url = src.startsWith('data:') ? null : Uri.tryParse(src);
    final String? name = url == null ? src : srsMediaNameFromUrl(url);
    if (name == null) return;
    srsRunLogged('SrsReview.viewCardImage', () async {
      final Widget? picture = srsCardImageWidget(
        name,
        await ref.read(srsMediaStoreProvider.future),
        fit: BoxFit.contain,
      );
      if (picture == null || !mounted) return;
      _lookup.closeAll();
      await showSrsCardImageViewer(context, picture);
      if (mounted) _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
    });
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

  /// 复习中高频的几项（撤销 / 待决 / 重播 / 编辑），优先级最高、最后才收进「⋯」；其余卡片
  /// 操作与设置在 [_menuItems]，优先级最低、宽度不够时先收。撤销在没有可撤销的评分时不占位
  /// （Ctrl+Z 照常）。
  List<FushiToolbarItem> _actionItems() => <FushiToolbarItem>[
    if (_undo.isNotEmpty)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_undo'),
        icon: FushiIcons.undo,
        label: t.undo,
        tooltip: '${t.undo} (Ctrl+Z)',
        onPressed: _busy ? null : _undoLast,
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
    if (_currentSourceLink case final CardSourceLink source)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_open_source'),
        icon: cardSourceKindIcon(source.kind),
        label: t.card_source_open,
        onPressed: () => _openSource(source),
      ),
    if (_detail != null)
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_edit'),
        icon: FushiIcons.edit,
        label: t.srs_note_edit,
        onPressed: () => unawaited(_onCardAction(_CardAction.edit)),
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
      // 模板编辑器（正面 / 背面 / 样式源码）用代码图标，不与卡面外观的调色板混成一样。
      icon: FushiIcons.code,
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

  /// 低优先级的卡片操作与设置，按优先级从高到低排（宽度不够时从**末尾**起先收进「⋯」）：
  /// 复习中常用的标记 / 埋卡 / 暂停在前，浏览与设置居中，低频又带破坏性的移牌组 / 重置 /
  /// 删除最后、最先收起。显示类开关（只留重来 / 良好、卡面跟随设计系统、间隔、剩余数）
  /// 不再各占一颗顶栏按钮，统一在「复习选项」面板里（[showSrsReviewLayoutSheet]）。
  List<FushiToolbarItem> _menuItems() {
    final SrsCardDetail? detail = _detail;
    if (detail == null) return const <FushiToolbarItem>[];
    final bool fushiCard =
        detail.noteType.builtinKey == kSrsBuiltinFushiCardKey;
    return <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_flag'),
        icon: FushiIcons.flag,
        label: t.srs_card_flag,
        onPressed: () => unawaited(_onCardAction(_CardAction.flag)),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_bury'),
        icon: FushiIcons.schedule,
        label: t.srs_card_bury,
        onPressed: () => unawaited(_onCardAction(_CardAction.bury)),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_suspend'),
        icon: FushiIcons.pause,
        label: t.srs_card_suspend,
        onPressed: () => unawaited(_onCardAction(_CardAction.suspend)),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_browse'),
        icon: FushiIcons.search,
        label: t.srs_browse_title,
        onPressed: () => srsRunLogged('SrsReview.browse', _openBrowse),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_layout'),
        icon: FushiIcons.dashboardCustomize,
        label: t.srs_review_layout_title,
        onPressed: () => srsRunLogged(
          'SrsReview.layout',
          () => _focusOwnership.guardOverlay(
            () => showSrsReviewLayoutSheet(context, showDesignSkin: !fushiCard),
          ),
        ),
      ),
      ..._audioSettingItems(),
      ?_appearanceItem,
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_move'),
        icon: FushiIcons.moveFile,
        label: t.srs_card_move,
        onPressed: () => unawaited(_onCardAction(_CardAction.move)),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_reset'),
        icon: FushiIcons.restart,
        label: t.srs_card_reset,
        onPressed: () => unawaited(_onCardAction(_CardAction.reset)),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs_review_delete'),
        icon: FushiIcons.delete,
        label: t.srs_note_delete,
        onPressed: () => unawaited(_onCardAction(_CardAction.deleteNote)),
      ),
    ];
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
    await _applyDeckSettingsChange();
  }

  /// 牌组设置页回来后，当前会话立即按新设置走（BUG-3547）。
  ///
  /// 排程层没有跨调用的配置快照：`SrsDbStore.nextCard` / `answer` / `preview` 每次都现读
  /// 牌组树，所以「下一张选谁」（每日上限、学习卡优先）与「评分后的间隔」（学习步长、
  /// 记忆率、最大间隔）在下一次调用时自然用新值，**没有预排好的队列需要重建**。
  /// 过期的只有本页自己缓存的东西：
  /// - 预取的下一张：它连同出发时读到的音频设置一起缓存（[_PrefetchedCard.audioOwner]），
  ///   在这里**同步**作废——设置页一关就按评分键时不会再拿旧快照显示下一张、按旧开关
  ///   自动播放；[_reloadCurrent] 随后按新设置重新预取。
  /// - 当前这张的间隔预览、计数、标题、音频开关：[_reloadCurrent] 现读。
  ///
  /// 当前这张卡本身不换：用户正在看它（可能已翻到答案面），与 Anki 一样让它答完；
  /// 调低了每日上限时，答完这张后的选卡按新上限走。
  Future<void> _applyDeckSettingsChange() async {
    _prefetch = null;
    final bool wasAutoplay = _autoplayEnabled;
    await _reloadCurrent();
    // 刚打开自动播放：当前这一面立刻按新设置播；刚关掉：停掉正在自动播的
    // （卡面页内的片段由卡面闸门随 [SrsCardFace.autoplayMedia] 重放 / 停下）。
    if (mounted && wasAutoplay != _autoplayEnabled) _autoplayAudio();
  }

  /// 悬浮态下没有卡面可点（读失败 / 复习完 / 排程不可用）：顶栏常驻，不然连返回键都
  /// 唤不出来。
  bool get _chromeForced =>
      _error != null ||
      _finished ||
      (!_loading && !(_store?.canSchedule ?? false));

  void _toggleChrome() {
    if (!mounted || !ref.read(srsReviewChromeFloatingProvider)) return;
    setState(() => _chromeShown = !_chromeShown);
  }

  /// 卡面空白处被点（WebView 卡面经页内取词脚本、原生卡面经 [SrsBlankTapRegion] 回报）。
  /// 查词弹窗开着时这一下是关弹窗，不切换顶栏。
  void _onCardTapEmpty() {
    if (_lookup.isOpen) return;
    _toggleChrome();
  }

  /// 鼠标右键（卡面已关掉 WebView 自带右键菜单，复习页上右键别无他用）：切换悬浮顶栏。
  void _onPagePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        (event.buttons & kSecondaryMouseButton) == 0 ||
        _lookup.isOpen) {
      return;
    }
    _toggleChrome();
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
        title: _title,
        subtitle: _finished || !ref.watch(srsReviewShowCountsProvider)
            ? ''
            : _countsText,
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
        // 默认平铺、宽度不够才按优先级收进「⋯」（自适应溢出，CLAUDE.md 工具栏规则）。
        overflow: _menuItems(),
      ),
    );
  }

  /// Apple：全部平铺成图标，放不下时由页头按优先级收进「⋯」（[FushiPageScaffold] 的
  /// 自适应收纳，同级越靠后越先收：[_menuItems] 先收，高频项最后收）。
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
    // 悬浮顶栏：页头不占布局（空页头），两套设计系统都改由正文上层的悬浮胶囊栏
    // （[_buildTopBar]）承载，默认收起、点空白 / 右键唤出。
    final bool floating = ref.watch(srsReviewChromeFloatingProvider);
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: _title,
        header: floating
            ? const SizedBox.shrink()
            : (apple ? null : _buildTopBar(context)),
        actions: apple && !floating ? _buildAppleActions() : const <Widget>[],
        headerBottom:
            apple &&
                !floating &&
                !_finished &&
                ref.watch(srsReviewShowCountsProvider)
            ? SrsCountTriple(
                newCount: _newCount,
                learnCount: _learnCount,
                reviewCount: _reviewCount,
                dense: true,
              )
            : null,
        body: Builder(
          builder: (BuildContext context) => _withFloatingChrome(
            context,
            floating: floating,
            child: Padding(
              // 正文从浮动页头底下开始：整面 WebView 的卡面滚不到页头下面，整体让位。
              // 原生 Fushi 卡面例外：铺到页头底下、把让位高度当滚动内边距（见
              // [SrsFushiCardView.topInset]），往下翻页头收起后不留一条空带。
              padding: EdgeInsets.only(
                top: _cardScrollsUnderHeader
                    ? 0
                    : MediaQuery.paddingOf(context).top,
              ),
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                child: KeyedSubtree(
                  // 读首张卡期间与出卡后同一棵子树（'review'）：卡面平台视图在读库的同时
                  // 就开始创建，不在数据到了之后才冷建（见 [_buildBody]）。
                  key: ValueKey<String>(
                    _error != null
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
      ),
    );
  }

  /// 悬浮态：正文之上压一条悬浮顶栏（与小说、漫画阅读器同款弹簧滑入 / 淡出），右键
  /// 切换显隐。固定页头时原样返回 [child]。
  Widget _withFloatingChrome(
    BuildContext context, {
    required bool floating,
    required Widget child,
  }) {
    if (!floating) return child;
    return Listener(
      onPointerDown: _onPagePointerDown,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FushiChromeReveal(
              key: const ValueKey<String>('srs-review-floating-chrome'),
              visible: _chromeShown || _chromeForced,
              child: SafeArea(bottom: false, child: _buildTopBar(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前显示的是原生 Fushi 卡面（Flutter 滚动，能滚到浮动页头底下）。
  bool get _cardScrollsUnderHeader =>
      !_loading &&
      _error == null &&
      !_finished &&
      (_store?.canSchedule ?? false) &&
      _detail != null &&
      _rendered?.fushiCardDefinitions != null;

  Widget _buildBody(BuildContext context) {
    // 首张卡还在读：先把卡面（WebView 外壳）建起来、上面压加载指示。WebView 冷建 +
    // 外壳加载与读库并行，数据一到只在同一个平台视图里换内容（BUG-3579 实测这段在
    // 数据之后串行要 0.8~1.3 s）。
    if (_loading) return _buildCard(context);
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

  /// 上一次建好的卡面 widget 与建它用的输入（[_cardFace]）。
  ({Object inputs, Widget face})? _faceCache;

  /// 卡面 widget：输入没变时原样返回上一次的**同一个实例**，框架据此跳过整棵卡面子树的重建。
  ///
  /// 本页的 setState 大多与卡面无关（忙碌态开 / 关、计数与间隔预览补齐、媒体探测），以前每次都
  /// 新建 [SrsCardFace] → 原生 Fushi 卡面 / 释义 WebView 整棵重建；换一张卡要重建三四遍，与下一张
  /// 卡的进场动画抢同几帧。卡面自己订阅的主题 / 外观 / provider 变了，照样由它自己重建。
  Widget _cardFace(
    BuildContext context, {
    required SrsCardDetail? detail,
    required SrsRenderedCard? rendered,
    required SrsCardFaceBuilder faceBuilder,
    required String language,
    required double zoom,
    required String hostCss,
    required MediaQueryData media,
  }) {
    final Object inputs = (
      detail?.card.id,
      detail?.noteType.builtinKey,
      rendered,
      _showingAnswer,
      faceBuilder,
      language,
      zoom,
      hostCss,
      _autoplayEnabled,
      media,
    );
    final ({Object inputs, Widget face})? hit = _faceCache;
    if (hit != null && hit.inputs == inputs) return hit.face;
    final SrsCardFace face = SrsCardFace(
      cardId: detail?.card.id ?? '',
      showingAnswer: _showingAnswer,
      bodyHtml: rendered == null
          ? ''
          : _showingAnswer
          ? rendered.answer
          : rendered.question,
      css: rendered?.css ?? '',
      languageCode: language.isEmpty ? null : language,
      onBridgeKey: _onBridgeKey,
      fushiCard: detail?.noteType.builtinKey == kSrsBuiltinFushiCardKey,
      pageZoom: zoom == 1 ? null : zoom,
      onZoomWheel: _zoomWheel,
      onSourceLink: _openSource,
      // 「卡面图片大小」随主题原地下发（不重放卡片）；Fushi 卡片的原生图片读同一设置。
      hostCss: hostCss,
      onImageTap: _viewCardImage,
      // 卡面页内自己出声的媒体（视频制卡的同步片段等）同样服从牌组的自动播放开关
      // （BUG-3546）；`[sound:]` 由 [_autoplayAudio] 按同一开关处理。
      autoplayMedia: _autoplayEnabled,
      onPlayAudio: _playNames,
      onTapEmpty: _onCardTapEmpty,
    );
    // 内置 Fushi 卡片（模板未改）走原生 + 释义 WebView 的混合渲染；其余整面 WebView。
    final Widget built = rendered?.fushiCardDefinitions != null
        ? MediaQuery(
            // 原生区跟随卡面缩放：在系统字号倍率上再乘缩放倍率。
            data: media.copyWith(
              textScaler: TextScaler.linear(media.textScaler.scale(1) * zoom),
            ),
            child: SrsFushiCardView(
              key: const ValueKey<String>('srs-fushi-card-view'),
              face: face,
              fields: rendered!.fields,
              definitionsHtml: rendered.fushiCardDefinitions!,
              topInset: media.padding.top,
            ),
          )
        : faceBuilder(context, face);
    _faceCache = (inputs: inputs, face: built);
    return built;
  }

  Widget _buildCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // null = 首张卡还在读（[_buildBody]）：空卡面先建平台视图，上面压加载指示。
    final SrsCardDetail? detail = _detail;
    final SrsRenderedCard? rendered = _rendered;
    final SrsCardFaceBuilder faceBuilder = ref.watch(
      srsCardFaceBuilderProvider,
    );
    final String language = ref.read(appProvider).defaultContentLanguage;
    final double zoom = ref.watch(srsReviewZoomProvider);
    final String hostCss = srsReviewImageSizeCss(
      ref.watch(srsReviewImageSizeProvider),
    );
    final MediaQueryData media = MediaQuery.of(context);
    final Widget cardFace = _cardFace(
      context,
      detail: detail,
      rendered: rendered,
      faceBuilder: faceBuilder,
      language: language,
      zoom: zoom,
      hostCss: hostCss,
      media: media,
    );
    return SrsCardLookupHost(
      controller: _lookup,
      // 弹窗整栈关掉：焦点回复习页（WebView / 弹窗拿走过 OS 焦点）。
      onClosed: () => _reclaim(FocusReclaimCause.overlayClosed),
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
                  // 结构恒定（卡面在 Stack 第一格）：读首张卡时建起的卡面平台视图出卡后
                  // 原地复用，加载指示只是压在上面的第二格。
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: <Widget>[
                      cardFace,
                      IgnorePointer(
                        child: AnimatedSwitcher(
                          duration: fushiMotionDuration(
                            context,
                            FushiMotion.medium,
                          ),
                          switchInCurve: FushiMotion.enter,
                          switchOutCurve: FushiMotion.exit,
                          child: detail == null
                              ? const FushiLoadingView(
                                  key: ValueKey<String>('srs-card-loading'),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
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
              child: _withBottomReplay(
                context,
                AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: _showingAnswer
                      ? _buildRatingRow(context)
                      : _buildShowAnswer(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 底栏按钮的设计系统高度：MD3 = M3E 中号按钮（56），Apple = 50（大于 HIG 44 的 iOS
  /// 大按钮档）；两者都 ≥ 48dp 命中区。
  static const double _kBarButtonHeightApple = 50;

  /// 「显示答案」的最小宽度（底部重播键再多也不把它挤得更窄）。
  static const double _kShowAnswerMinWidth = 220;

  /// 「显示答案」：设计系统主按钮（MD3 = M3E 中号胶囊 + 按压变形，Apple = 强调色胶囊），
  /// 不再通栏铺满——居中、宽度封顶，与评分按钮同高，翻面时两者原地交替。
  Widget _buildShowAnswer(BuildContext context) {
    final bool apple = isGlassDesign(context);
    // 首张卡还在读时（卡面已先建着）不可按。
    final bool enabled = !_busy && _detail != null;
    return Center(
      key: const ValueKey<String>('srs-show-answer-row'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: _kShowAnswerMinWidth,
          maxWidth: 420,
        ),
        child: FushiPressScale(
          enabled: enabled,
          // 快捷键提示与评分按钮同一写法（空格 / Enter / 手柄 A 都翻面，见 _onKey）。
          child: FushiTooltip(
            message: '${t.srs_review_show_answer} (Space)',
            child: SizedBox(
              width: double.infinity,
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('srs-show-answer'),
                onPressed: enabled ? _showAnswer : null,
                size: FushiButtonSize.m,
                style: apple
                    ? const ButtonStyle(
                        minimumSize: WidgetStatePropertyAll<Size>(
                          Size(_kBarButtonHeightApple, _kBarButtonHeightApple),
                        ),
                      )
                    : null,
                icon: const FushiIcon(FushiIcons.visibility),
                label: Text(t.srs_review_show_answer),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部重播键的边长：≥ 48dp 命中区，比「显示答案」/ 评分按钮（56 / 50）小一号——它是
  /// 辅助操作，单独一行放在评分按钮上方，不和评分按钮并排抢同一高度（#17）。
  static const double _kReplayButtonExtent = 48;

  /// 底栏重播键（⋯「复习选项」里选左 / 右，默认不放）：单独一行、放在「显示答案」/ 评分
  /// 按钮**上方**，靠选定那一侧（#17：以前与评分按钮并排同高，挤在同一行里很怪）。
  ///
  /// **每段音频一个键**（只想听例句就只点例句那颗；R 仍是整面重播）。键位按两面全部音频定
  /// （问题面在前，与卡面从上到下的顺序一致），翻面前后同一位置、同样多——正面还没有的那段
  /// 先不可点；「重播含问题音频」只管整面重播（R），逐段键在哪一面都能点问题面那段。
  /// 媒体库里没有的文件不出键（#15）；一行放不下逐段键、只有一段时退回一颗整面重播键；
  /// 这张卡完全没有音频时整行收起。
  Widget _withBottomReplay(BuildContext context, Widget row) {
    final SrsReviewReplayButton side = ref.watch(srsReviewReplayButtonProvider);
    if (side == SrsReviewReplayButton.off || _detail == null) return row;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    const double extent = _kReplayButtonExtent;
    final List<String> slots = _replayNames(
      includeQuestion: true,
      answerSide: true,
    );
    final Set<String> playable = _replayNames(includeQuestion: true).toSet();
    final bool canReplayFace = _replayNames(
      includeQuestion: _replayIncludesQuestion,
    ).isNotEmpty;

    Widget replayButton(int i, {required bool split}) {
      final String? name = split ? slots[i] : null;
      final VoidCallback? onPressed = _busy
          ? null
          : !split
          ? (canReplayFace ? _replayAudio : null)
          : playable.contains(name)
          ? () => _playNames(<String>[name!])
          : null;
      final String label = split
          ? '${t.srs_review_replay_audio} ${i + 1}/${slots.length}'
          : t.srs_review_replay_audio;
      return FushiPressScale(
        enabled: onPressed != null,
        child: FushiTooltip(
          message: split ? label : '$label (R)',
          child: SizedBox.square(
            dimension: extent,
            child: FushiFilledButton.tonal(
              key: ValueKey<String>('srs-bottom-replay-$i'),
              onPressed: onPressed,
              size: FushiButtonSize.m,
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll<Size>(Size(extent, extent)),
                maximumSize: WidgetStatePropertyAll<Size>(
                  Size(double.infinity, extent),
                ),
                padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                  EdgeInsets.zero,
                ),
              ),
              // 多段时图标旁标序号（与卡面上从上到下的顺序一致）。
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: <Widget>[
                  FushiIcon(FushiIcons.volumeUp, semanticLabel: label),
                  if (split) ExcludeSemantics(child: Text('${i + 1}')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final bool start = side == SrsReviewReplayButton.start;
    final Widget replay = slots.isEmpty
        ? const SizedBox(width: double.infinity)
        : LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double unit = extent + tokens.spacing.gap;
              // 逐段键只在一行放得下时用，否则退回一颗整面重播键。
              final bool split =
                  slots.length > 1 &&
                  slots.length * unit - tokens.spacing.gap <= c.maxWidth;
              final int count = split ? slots.length : 1;
              return Align(
                alignment: start
                    ? AlignmentDirectional.centerStart
                    : AlignmentDirectional.centerEnd,
                child: Row(
                  key: const ValueKey<String>('srs-bottom-replay-row'),
                  mainAxisSize: MainAxisSize.min,
                  spacing: tokens.spacing.gap,
                  children: <Widget>[
                    for (int i = 0; i < count; i++)
                      replayButton(i, split: split),
                  ],
                ),
              );
            },
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 换到没有音频的卡时整行平滑收起，有音频时展开（不让评分按钮上下跳）。
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.enter,
          alignment: Alignment.bottomCenter,
          child: slots.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                  child: replay,
                ),
        ),
        row,
      ],
    );
  }

  Widget _buildRatingRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsAnswerPreview? preview = _preview;
    final SrsDayContext? day = _day;
    String interval(int rating) {
      if (preview == null || day == null) return '';
      final SrsScheduleResult next = preview.plan[rating];
      // RWKV 正在排队（RWKV-Instant）：进复习队列的卡在估计回忆率降到目标时出现，不看到期日，
      // FSRS-7 算的天数不是它真正回来的时间，不显示。学习 / 重学步仍按步长计时，照常显示；
      // RWKV 没准备好时（rwkvUnavailable）真按存下的到期日排队，也照常显示。
      if (preview.algorithm == SrsAlgorithm.rwkv &&
          next.queue == SrsQueue.review) {
        return '';
      }
      return srsIntervalLabel(
        srsIntervalParts(
          next,
          nowMs: preview.nowMs,
          today: day.dayIndexOf(preview.nowMs),
        ),
      );
    }

    // 评分按钮的下次间隔可在 ⋯「复习选项」里关掉；关掉或调度器给不出间隔（预览缺失）
    // 时按钮只剩评价词一行。
    final bool showIntervals = ref.watch(srsReviewShowIntervalsProvider);
    Widget button(int rating, String label, SrsRatingTone tone) => Expanded(
      child: SrsRatingButton(
        key: ValueKey<String>('srs-rate-$rating'),
        tone: tone,
        interval: showIntervals ? interval(rating) : '',
        label: label,
        tooltip: '$label ($rating)',
        onPressed: _busy ? null : () => _rate(rating),
      ),
    );

    // 只留「重来 / 良好」时两颗各占半行（对齐 AnkiDroid：不留空位）；key 随模式变，
    // 外层 AnimatedSwitcher 借此在两种布局间淡入淡出。
    final bool twoButtons = ref.watch(srsReviewHideHardEasyProvider);
    final Key key = ValueKey<String>(
      twoButtons ? 'srs-rating-row-two' : 'srs-rating-row',
    );
    final List<Widget> buttons = <Widget>[
      button(1, t.srs_rating_again, SrsRatingTone.again),
      if (!twoButtons) button(2, t.srs_rating_hard, SrsRatingTone.hard),
      button(3, t.srs_rating_good, SrsRatingTone.good),
      if (!twoButtons) button(4, t.srs_rating_easy, SrsRatingTone.easy),
    ];
    // RWKV 牌组这张卡没拿到 RWKV 间隔（模型没下载 / 正在回放历史 / 出错），按 FSRS-7 排：说一声。
    if (preview?.rwkvUnavailable ?? false) {
      return Column(
        key: key,
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            t.srs_review_rwkv_unavailable,
            key: const ValueKey<String>('srs-review-rwkv-unavailable'),
            style: context.fushiType.bodySmall,
            textAlign: TextAlign.center,
          ),
          Row(spacing: tokens.spacing.gap, children: buttons),
        ],
      );
    }
    return Row(key: key, spacing: tokens.spacing.gap, children: buttons);
  }
}

/// 评分按钮的语义色调。
enum SrsRatingTone { again, hard, good, easy }

/// 评分按钮配色：MD3 = M3E 色调按钮（重来 errorContainer、困难 surfaceContainerHighest、
/// 良好 primary 实心、简单 tertiaryContainer）；Apple = 系统实色胶囊（良好 = 强调色底，
/// 其余 = 语义色 16% 底 + 语义色字，同 iOS `.bordered` 着色）。
@visibleForTesting
({Color background, Color foreground}) srsRatingColors(
  SrsRatingTone tone,
  ColorScheme cs, {
  required bool apple,
}) {
  if (apple) {
    final Color accent = switch (tone) {
      SrsRatingTone.again => cs.error,
      SrsRatingTone.hard => cs.onSurfaceVariant,
      SrsRatingTone.good => cs.primary,
      SrsRatingTone.easy => cs.tertiary,
    };
    return tone == SrsRatingTone.good
        ? (background: cs.primary, foreground: cs.onPrimary)
        : (background: accent.withValues(alpha: 0.16), foreground: accent);
  }
  return switch (tone) {
    SrsRatingTone.again => (
      background: cs.errorContainer,
      foreground: cs.onErrorContainer,
    ),
    SrsRatingTone.hard => (
      background: cs.surfaceContainerHighest,
      foreground: cs.onSurface,
    ),
    SrsRatingTone.good => (background: cs.primary, foreground: cs.onPrimary),
    SrsRatingTone.easy => (
      background: cs.tertiaryContainer,
      foreground: cs.onTertiaryContainer,
    ),
  };
}

/// 一颗评分按钮：上行间隔预览、下行评分名。MD3 = M3E 中号色调按钮（56 高，按压变形）；
/// Apple = 实色胶囊（[FushiPlainButton] 底，按下变淡）。两套都包 [FushiPressScale]，
/// 命中区 ≥ 48dp，内容随系统字号增高不截断。
class SrsRatingButton extends StatelessWidget {
  const SrsRatingButton({
    super.key,
    required this.tone,
    required this.interval,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final SrsRatingTone tone;
  final String interval;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ({Color background, Color foreground}) c = srsRatingColors(
      tone,
      scheme,
      apple: apple,
    );
    // MD3 禁用态（M3 规范：容器 onSurface 12%、内容 onSurface 38%）：评分色只给可点的按钮，
    // 否则禁用的按钮看起来和可点的一模一样。内容文字自带颜色，不读按钮的 foregroundColor，
    // 所以这里按同一判据给文字也换成禁用色。
    final bool enabled = onPressed != null;
    final Color disabledBackground = scheme.onSurface.withValues(alpha: 0.12);
    final Color disabledForeground = scheme.onSurface.withValues(alpha: 0.38);
    Widget content(Color fg) => Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (interval.isNotEmpty)
          Text(
            interval,
            style: context.fushiType.labelMedium.copyWith(
              color: fg.withValues(alpha: 0.8),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        Text(
          label,
          style: context.fushiType.labelLargeEmphasized.copyWith(color: fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final Widget button = apple
        ? FushiPlainButton(
            onPressed: onPressed,
            semanticLabel: tooltip,
            borderRadius: BorderRadius.circular(
              _SrsReviewPageState._kBarButtonHeightApple / 2,
            ),
            fill: c.background,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: _SrsReviewPageState._kBarButtonHeightApple,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Center(child: content(c.foreground)),
              ),
            ),
          )
        : FushiFilledButton(
            onPressed: onPressed,
            size: FushiButtonSize.m,
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith<Color>(
                (Set<WidgetState> states) =>
                    states.contains(WidgetState.disabled)
                    ? disabledBackground
                    : c.background,
              ),
              foregroundColor: WidgetStateProperty.resolveWith<Color>(
                (Set<WidgetState> states) =>
                    states.contains(WidgetState.disabled)
                    ? disabledForeground
                    : c.foreground,
              ),
              // 两行内容：高度至少 56，系统字号放大时随内容长高（不截断）。
              maximumSize: const WidgetStatePropertyAll<Size>(
                Size(double.infinity, double.infinity),
              ),
              padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
            ),
            child: content(enabled ? c.foreground : disabledForeground),
          );
    return FushiPressScale(
      enabled: onPressed != null,
      child: FushiTooltip(message: tooltip, child: button),
    );
  }
}
