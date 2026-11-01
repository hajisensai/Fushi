/// 复习页：问题面 →「显示答案」→ 四个评分（带间隔预览）→ 下一张，直到当天做完。
///
/// - 键盘 / 手柄（只在本页焦点作用域里生效）按快捷键注册表的 [ShortcutScope.srsReview]
///   解析（设置 → 快捷键 →「SRS 复习」可改键，反馈 itlb0djDq6）。默认：空格 / Enter /
///   手柄 A = 显示答案，翻面后 = 「良好」；1–4 = 四个评分；R = 重播音频；Ctrl+Z = 撤销；
///   Ctrl+= / - / 0 = 卡面缩放。本页没解析中的键（Esc / Alt+← / 手柄 B）冒泡到根，由
///   universal 的「返回上一级」兜底。全局的裸空格中和（`global_navigation.dart` 的
///   `_neutralizeBareSpace`）挂在根上，本页的 [Focus.onKeyEvent] 更近、先消费，所以空格
///   只在复习页有「翻面 / 良好」的含义。
/// - WebView 卡面持有键盘焦点时，按键经键盘桥交回本页（键表按注册表当前绑定导出，
///   [srsReviewBridgeTokens]），与 Flutter 焦点路径同一个 `resolveKeyboard`；焦点回收走
///   [PageFocusOwnership]（不裸调 requestFocus）。
/// - 卡面音频：当前卡所在牌组（取参数继承的 own 祖先，[SrsDeckTree.paramsOwner]）开着
///   「自动播放音频」时，出题 / 翻面自动按顺序播卡上的音频；「重播音频」随时手动再播（规则见
///   srs_card_autoplay.dart，对齐 Anki 按预设的 autoplay / replayq）。
/// - 撤销栈是会话级：撤评分调 [SrsDbStore.undo]（别的设备已复习过这张卡时返回
///   false，提示后丢掉这一步）；撤暂停 / 埋卡 / 旗标 / 移牌组 / 编辑 = 再写一次
///   改回原值。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui'
    show FlutterView, ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerDownEvent,
        PointerScrollEvent,
        PointerSignalEvent,
        kSecondaryMouseButton;
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_anki/fushi_anki_core.dart' show CardSourceLink;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
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
import 'package:fushi/src/pages/implementations/srs/srs_review_gestures_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_layout_sheet.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart'
    show SrsCardAppearance, SrsCardColorSource, srsCardColorScheme;
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_card_media.dart' show srsMediaNameFromUrl;
import 'package:fushi/src/srs/srs_change_note_type.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
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

/// 复习页卡面键盘桥要交回 Dart 的 token（[InputBinding.bridgeToken]），按注册表**当前**
/// 绑定导出而不是写死：[ShortcutScope.srsReview] 的全部键盘绑定 + 「返回上一级」
/// （universal 的 globalBack，WebView 持焦时 Esc 也要能退出复习）+ `Escape`（查词弹窗
/// 关一层，用户把返回键改走了也照样要）。去重、保持顺序。
List<String> srsReviewBridgeTokens(FushiShortcutRegistry registry) {
  final List<String> tokens = <String>[];
  void add(String token) {
    if (!tokens.contains(token)) tokens.add(token);
  }

  for (final ShortcutAction action in <ShortcutAction>[
    ...ShortcutAction.actionsForScope(ShortcutScope.srsReview),
    ShortcutAction.globalBack,
  ]) {
    for (final InputBinding binding
        in registry.bindingsFor(action).keyboardBindings) {
      add(binding.bridgeToken);
    }
  }
  add('Escape');
  return tokens;
}

/// 卡面缩放：每档 10%，范围 60%–200%。
const double _kZoomStep = 0.1;
const double _kZoomMin = 0.6;
const double _kZoomMax = 2.0;

class _SrsReviewPageState extends ConsumerState<SrsReviewPage>
    with WidgetsBindingObserver {
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

  /// 队列空了是因为 RWKV 还没准备好（[SrsStudyState.rwkvPending]）：RWKV 牌组的复习卡不退回按 FSRS-7 的到期日
  /// 出，这里显示 RWKV 的准备 / 失败状态，就绪后自动重新排队（[_onRwkvStatus]）。
  bool _rwkvPending = false;
  SrsRwkvService? _rwkv;
  SrsRwkvStatus? _rwkvStatus;
  StreamSubscription<SrsRwkvStatus>? _rwkvSubscription;

  /// 悬浮顶栏（[srsReviewChromeFloatingProvider]，默认开）当前是否被唤出。默认收起；
  /// 点卡面空白 / 右键在唤出与收起间切换，不自动收起（与小说、漫画阅读器同一口径：
  /// 点击是唯一的开关）。固定页头时不用它。
  bool _chromeShown = false;

  /// 浮在卡面上的底栏（显示答案 / 评分 / 重播行，含底部安全区）的实测高度：整面
  /// WebView 卡面停在它上沿，原生卡面把它当底部滚动内边距（见 [_buildCard]）。
  double _bottomBarHeight = 0;

  /// 同一高度的可监听版本，交给原生卡面（身份不变，不进卡面缓存键，见 [_cardFace]）。
  final ValueNotifier<double> _bottomBarInset = ValueNotifier<double>(0);

  /// 卡面区域（单击分区按它横向三等分）。
  final GlobalKey _cardSurfaceKey = GlobalKey(debugLabel: 'srs-card-surface');

  /// 滑动途中的视觉反馈（卡面跟手位移 + 松手会执行的动作提示）；null = 没在滑。
  final ValueNotifier<SrsSwipeHint?> _swipeHint = ValueNotifier<SrsSwipeHint?>(
    null,
  );

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

  /// 本页焦点取证（OO3O-3ljda：macOS 上点过卡面后空格失灵）：Flutter 焦点离开 / 回到本页、
  /// 窗口视图焦点变化各记一条，封顶 [_kMaxFocusReports] 条免得刷满诊断日志。与卡面的
  /// `SrsWebCardFace.keyNotBridged`（页面收到了键却没交回）合起来能分清键落在了哪一层。
  int _focusReports = 0;
  static const int _kMaxFocusReports = 12;
  bool? _lastPageFocus;

  void _reportFocus(String what) {
    if (_focusReports >= _kMaxFocusReports) return;
    _focusReports++;
    ErrorLogService.instance.logDiagnostic(
      'SrsReviewPage.focus',
      '$what (primary=${FocusManager.instance.primaryFocus?.debugLabel})',
    );
  }

  void _onPageFocusChanged() {
    final bool has = _focusNode.hasFocus;
    if (_lastPageFocus == has) return;
    final bool first = _lastPageFocus == null;
    _lastPageFocus = has;
    if (first && has) return;
    _reportFocus(has ? 'page focus regained' : 'page focus lost');
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    _reportFocus('view ${event.viewId} ${event.state.name}');
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
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onPageFocusChanged);
    // 正在复习：自动优化让路（在跑的那一轮立即取消，见 srs_optimization_scheduler.dart）。
    srsActiveReviewSessions.value++;
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_rwkvSubscription?.cancel());
    srsActiveReviewSessions.value--;
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onPageFocusChanged);
    _lookup.dispose();
    srsRunLogged('SrsReviewPage.stopAudio', _audio.cancel);
    _focusNode.dispose();
    _bottomBarInset.dispose();
    _swipeHint.dispose();
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
    // 先把 RWKV 服务装配到 store 上（[SrsDbStore.rwkv]）再排第一次队：没装配的 store 会把 RWKV 牌组当成
    // 「宿主没有 RWKV」按到期日排。
    SrsRwkvService? rwkv;
    try {
      rwkv = await ref.read(srsRwkvServiceProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsReviewPage.rwkv', e, stack);
    }
    if (!mounted) return;
    _rwkv = rwkv;
    _rwkvStatus = rwkv?.status;
    _rwkvSubscription = rwkv?.statusChanges.listen(_onRwkvStatus);
    SrsReviewPage.debugPhase?.call('store');
    await _loadNext();
  }

  void _onRwkvStatus(SrsRwkvStatus status) {
    if (!mounted) return;
    setState(() => _rwkvStatus = status);
    // 等的就是它：就绪后重新排队，RWKV 牌组的复习卡按此刻的回忆率出。
    if (status.phase == SrsRwkvPhase.ready && _finished && _rwkvPending) {
      unawaited(_loadNext());
    }
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
  /// 仍由评分后的排队（[SrsDbStore.answerAndStudy]）决定，预取只是它的猜测，不一致就丢。
  ///
  /// [afterKnown]：排出当前这张的那次排队已经顺带排好了它之后的一张（[SrsStudyState.after]，可能为 null =
  /// 没有了），直接用，不再发一次排队。
  void _startPrefetch(
    String currentCardId, {
    bool afterKnown = false,
    String? after,
  }) {
    final SrsDbStore? store = _store;
    if (store == null) {
      _prefetch = null;
      return;
    }
    _prefetch = () async {
      try {
        SrsReviewPage.debugPhase?.call('prefetch:begin');
        final String? id = afterKnown
            ? after
            : await store.nextCard(
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
  /// 预取好的内容，间隔预览随后在后台补齐（预览只在翻面后才看得到）。
  ///
  /// [planned]：评分时已在同一次命令里排好的队（下一张 + 计数 + 再下一张）；没给且没指定 [cardId] 时
  /// 这里排一次（[SrsDbStore.studyState]，一次命令）。计数、下一张、预取的猜测都出自这一次排队。
  Future<void> _loadNext({
    String? cardId,
    bool usePrefetch = false,
    SrsStudyState? planned,
  }) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    final Future<_PrefetchedCard?>? pending = usePrefetch ? _prefetch : null;
    _prefetch = null;
    try {
      final SrsStudyState? plan =
          planned ??
          (cardId == null ? await store.studyState(widget.deckId) : null);
      final String? id = cardId ?? plan?.next;
      // 排队给的「再下一张」只对它排出的那张有效（指定了 [cardId] 时不是）。
      final bool afterKnown = cardId == null && plan != null;
      if (id == null) {
        if (plan != null) {
          _applyCounts(plan.summary);
        } else {
          await _refreshCounts();
        }
        if (!mounted) return;
        final bool rwkvPending = plan?.rwkvPending ?? false;
        setState(() {
          _loading = false;
          _finished = true;
          _rwkvPending = rwkvPending;
          // 状态以服务此刻的为准：等排队结果的途中发来的事件（例如打分失败转「出错」）已被 [_onRwkvStatus]
          // 记下，这里再对一次，免得界面停在排队前的阶段。
          _rwkvStatus = _rwkv?.status ?? _rwkvStatus;
          _detail = null;
          _rendered = null;
          _preview = null;
        });
        srsRunLogged('SrsReviewPage.stopAudio', _audio.cancel);
        // 「就绪」可能在这次排队等结果时就已经来过：那时 [_finished] 还是 false，[_onRwkvStatus] 不重排，
        // 之后也不会再有就绪事件——页面会一直停在「等 RWKV」。所以 pending 落定后当场看一次服务：已就绪就
        // 重排。不会空转：服务就绪时打分失败会转「出错」（`SrsRwkvService` 的 _scoringFailed），store 也不会
        // 在 RWKV 就绪且打分成功时报 pending，所以「就绪 + pending」只可能是这个竞态。
        if (rwkvPending && (_rwkv?.ready ?? false)) {
          await _loadNext();
        }
        return;
      }
      final _PrefetchedCard? hit = await _takePrefetch(pending, id);
      if (hit != null) {
        if (!mounted) return;
        if (plan != null) _applyCounts(plan.summary);
        _show(
          hit.detail,
          hit.rendered,
          preview: null,
          day: _day,
          audioOwner: hit.audioOwner,
          afterKnown: afterKnown,
          after: plan?.after,
        );
        unawaited(_completeShown(id, _shownGeneration, counted: plan != null));
        return;
      }
      SrsReviewPage.debugPhase?.call('nextCard');
      if (plan != null) {
        _applyCounts(plan.summary);
      } else {
        await _refreshCounts();
      }
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
      _show(
        detail,
        rendered,
        preview: null,
        day: _day,
        audioOwner: audioOwner,
        afterKnown: afterKnown,
        after: plan?.after,
      );
      unawaited(_completeShown(id, _shownGeneration, counted: true));
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
    bool afterKnown = false,
    String? after,
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
    if (detail != null) {
      _startPrefetch(detail.card.id, afterKnown: afterKnown, after: after);
    }
  }

  /// 上屏后补齐间隔预览与日界（只落到仍在显示的那张卡上）；[counted] = 计数已随排队拿到，不再数一遍。
  Future<void> _completeShown(
    String cardId,
    int generation, {
    bool counted = false,
  }) async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    try {
      final SrsDeckSummary? sum = counted ? null : await _deckSummary();
      SrsReviewPage.debugPhase?.call('deckSummary');
      final SrsDayContext day = await store.dayContext();
      final SrsAnswerPreview? preview = store.canSchedule
          ? await store.preview(cardId)
          : null;
      SrsReviewPage.debugPhase?.call('preview');
      if (!mounted || generation != _shownGeneration) return;
      setState(() {
        if (!counted) _applyCounts(sum);
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
        // 评分与排出下一张是一次调用（落库 + 计数 + 下一张 + 再下一张，SrsDbStore.answerAndStudy）。
        final SrsAnswerOutcome out = await store.answerAndStudy(
          detail.card.id,
          rating,
          durationMs: math.min(
            _answerClock.elapsedMilliseconds,
            kSrsMaxAnswerDurationMs,
          ),
          studyDeckId: widget.deckId,
        );
        SrsReviewPage.debugPhase?.call('answer:done');
        _undo.add(_UndoStep(cardId: detail.card.id, logId: out.log.id));
        _reviewedThisSession++;
        await _loadNext(usePrefetch: true, planned: out.study);
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

  FushiShortcutRegistry get _shortcuts =>
      ref.read(appProvider).shortcutRegistry;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 查词弹窗开着：Esc 关一层，翻面 / 评分键吞掉。
    final KeyEventResult? lookup = _lookup.guardKey(event);
    if (lookup != null) return lookup;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ShortcutAction? action = _shortcuts.resolveKeyboard(
      event.logicalKey,
      modifiers: <ModifierKey>{
        if (HardwareKeyboard.instance.isControlPressed) ModifierKey.ctrl,
        if (HardwareKeyboard.instance.isShiftPressed) ModifierKey.shift,
        if (HardwareKeyboard.instance.isAltPressed) ModifierKey.alt,
        if (HardwareKeyboard.instance.isMetaPressed) ModifierKey.meta,
      },
      scope: ShortcutScope.srsReview,
      physicalKey: event.physicalKey,
    );
    // 没命中的键（Esc / Alt+← 等）原样冒泡：根上的 universal「返回上一级」兜底。
    // 手柄 gameButton* 键事件同样冒泡，由全局 wrapper 转成 GamepadButtonIntent 交回
    // [_handleGamepadButton]（键盘绑定里没有它们）。
    return action != null && _executeShortcut(action)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// 手柄按钮（桌面轮询的 [GamepadButtonIntent]，Android 的 gameButton* 键事件经全局
  /// wrapper 汇合到同一 Intent）。返回 false 交回 GamepadService 的兜底（弹窗词条导航、
  /// B = 返回上一级…）。
  bool _handleGamepadButton(GamepadButton button) {
    final ShortcutAction? action = _shortcuts.resolveGamepad(
      button,
      scope: ShortcutScope.srsReview,
    );
    if (action == null) return false;
    // 查词弹窗开着时翻面 / 评分键让给弹窗的手柄兜底（与键盘一侧 guardKey 吞键同义：
    // 不翻面、不评分）。
    if (_lookup.isOpen && _flipsOrRates(action)) return false;
    return _executeShortcut(action);
  }

  /// 会翻面 / 评分（换卡）的动作：查词弹窗开着时一律不执行。
  static bool _flipsOrRates(ShortcutAction action) => switch (action) {
    ShortcutAction.srsReviewPrimary ||
    ShortcutAction.srsReviewAgain ||
    ShortcutAction.srsReviewHard ||
    ShortcutAction.srsReviewGood ||
    ShortcutAction.srsReviewEasy => true,
    _ => false,
  };

  /// 复习页动作的唯一执行体（键盘 / 卡面键盘桥 / 手柄三条入口共用）。返回是否消费。
  bool _executeShortcut(ShortcutAction action) {
    // 改了键的翻面 / 评分键不在 guardKey 的固定吞键表里：弹窗开着时在这里吞掉。
    if (_lookup.isOpen && _flipsOrRates(action)) return true;
    switch (action) {
      case ShortcutAction.srsReviewPrimary:
        _primary();
        return true;
      case ShortcutAction.srsReviewAgain:
        return _rateByKey(1);
      case ShortcutAction.srsReviewHard:
        return _rateByKey(2);
      case ShortcutAction.srsReviewGood:
        return _rateByKey(3);
      case ShortcutAction.srsReviewEasy:
        return _rateByKey(4);
      case ShortcutAction.srsReviewReplayAudio:
        // 重播音频（对齐 Anki 的 R）。
        _replayAudio();
        return true;
      case ShortcutAction.srsReviewUndo:
        _undoLast();
        return true;
      case ShortcutAction.srsReviewZoomIn:
        _zoomBy(_kZoomStep);
        return true;
      case ShortcutAction.srsReviewZoomOut:
        _zoomBy(-_kZoomStep);
        return true;
      case ShortcutAction.srsReviewZoomReset:
        _setZoom(1);
        return true;
      default:
        return false;
    }
  }

  /// 评分键只在答案面生效；问题面不消费（与改造前一致）。
  bool _rateByKey(int rating) {
    if (!_showingAnswer) return false;
    _rate(rating);
    return true;
  }

  /// 按钮提示里的快捷键：取该动作**当前**的第一条键盘绑定（改了键提示跟着变，清空了就
  /// 不挂）。
  String _withKeyHint(String label, ShortcutAction action) {
    final List<InputBinding> keys = _shortcuts
        .bindingsFor(action)
        .keyboardBindings;
    return keys.isEmpty ? label : '$label (${keys.first.displayLabel})';
  }

  /// 空格 / Enter / 手柄 A：问题面 → 显示答案；答案面 →「良好」。
  void _primary() {
    if (_showingAnswer) {
      _rate(3);
    } else {
      _showAnswer();
    }
  }

  /// 卡面键盘桥的键表（按注册表当前绑定导出），内容没变时复用同一个实例：卡面 widget
  /// 缓存（[_cardFace]）按身份比较输入。
  List<String> _bridgeKeys = const <String>[];

  List<String> _currentBridgeKeys() {
    final List<String> fresh = srsReviewBridgeTokens(_shortcuts);
    if (!listEquals(fresh, _bridgeKeys)) _bridgeKeys = fresh;
    return _bridgeKeys;
  }

  /// WebView 持焦时经键盘桥回传的 token：反解析成绑定后走与 Flutter 焦点路径同一个
  /// `resolveKeyboard`；本页没中的再按 universal 解析「返回上一级」（桥已
  /// preventDefault 掐掉了这次按键，不自己兜底它就被吞了）。
  void _onBridgeKey(String token) {
    if (_lookup.guardBridgeToken(token)) return;
    final InputBinding? binding = InputBinding.fromBridgeToken(token);
    if (binding == null) return;
    final ShortcutAction? action = _shortcuts.resolveKeyboard(
      binding.key,
      modifiers: binding.modifiers,
      scope: ShortcutScope.srsReview,
    );
    if (action != null && _executeShortcut(action)) return;
    if (_shortcuts.resolveKeyboard(
          binding.key,
          modifiers: binding.modifiers,
          scope: ShortcutScope.universal,
        ) ==
        ShortcutAction.globalBack) {
      unawaited(Navigator.of(context).maybePop());
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
        tooltip: _withKeyHint(t.undo, ShortcutAction.srsReviewUndo),
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

  // ------------------------------------------------------------------ 卡面手势

  SrsReviewSide get _side =>
      _showingAnswer ? SrsReviewSide.back : SrsReviewSide.front;

  /// 当前这一面开着的识别器（随映射 / 「只留重来 / 良好」/ 翻面变）。
  SrsCardGestureArming get _gestureArming => ref
      .read(srsReviewGesturesProvider)
      .arming(_side, hideHardEasy: ref.read(srsReviewHideHardEasyProvider));

  /// [g] 在当前这一面实际执行的动作。
  SrsReviewGestureAction _resolveGesture(SrsReviewGesture g) => ref
      .read(srsReviewGesturesProvider)
      .resolve(_side, g, hideHardEasy: ref.read(srsReviewHideHardEasyProvider));

  /// 卡面回报的手势（WebView 卡面经页内指针脚本、原生卡面经 [SrsCardGestureRegion]，同一
  /// 套判据）。查词弹窗开着时卡面上的点按是关弹窗，不执行手势。
  void _onCardGesture(SrsCardGestureEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case SrsCardGestureKind.drag:
        _onCardDrag(event.delta);
        return;
      case SrsCardGestureKind.cancel:
        _swipeHint.value = null;
        return;
      case SrsCardGestureKind.release:
        _swipeHint.value = null;
        if (_lookup.isOpen) return;
        final SrsCardGestureArming arming = _gestureArming;
        final SrsReviewGesture? swipe = srsClassifySwipe(
          event.delta,
          event.velocity,
          horizontal: arming.swipeHorizontal,
          vertical: arming.swipeVertical,
        );
        if (swipe != null) _runGestureAction(_resolveGesture(swipe));
        return;
      case SrsCardGestureKind.tap:
      case SrsCardGestureKind.doubleTap:
      case SrsCardGestureKind.longPress:
        if (_lookup.isOpen) return;
        final SrsReviewGesture gesture = switch (event.kind) {
          SrsCardGestureKind.doubleTap => SrsReviewGesture.doubleTap,
          SrsCardGestureKind.longPress => SrsReviewGesture.longPress,
          _ => srsTapGestureOf(_tapZoneOf(event.position)),
        };
        _runGestureAction(_resolveGesture(gesture));
    }
  }

  /// 单击落点在卡面区域的哪一个三分之一。
  SrsTapZone _tapZoneOf(Offset global) {
    final RenderObject? box = _cardSurfaceKey.currentContext
        ?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return SrsTapZone.center;
    final Offset local = box.globalToLocal(global);
    return srsTapZoneOf(local.dx, left: 0, width: box.size.width);
  }

  /// 滑动途中：只有朝着绑了动作的方向拖时卡面才跟手、显示松手会执行什么。
  void _onCardDrag(Offset delta) {
    final SrsCardGestureArming arming = _gestureArming;
    final ({SrsReviewGesture gesture, Offset offset, double progress})?
    preview = srsSwipePreview(
      delta,
      horizontal: arming.swipeHorizontal,
      vertical: arming.swipeVertical,
    );
    final SrsReviewGestureAction action = preview == null || _lookup.isOpen
        ? SrsReviewGestureAction.none
        : _resolveGesture(preview.gesture);
    _swipeHint.value = action == SrsReviewGestureAction.none
        ? null
        : SrsSwipeHint(
            offset: preview!.offset,
            progress: preview.progress,
            action: action,
          );
  }

  /// 执行手势绑定的动作：一律走复习页现成的实现（与按钮 / 快捷键同一条路径），按钮在
  /// 忙碌时禁用的（评分、撤销）这里同样不响应。
  void _runGestureAction(SrsReviewGestureAction action) {
    switch (action) {
      case SrsReviewGestureAction.none:
        return;
      case SrsReviewGestureAction.showAnswer:
        _showAnswer();
      case SrsReviewGestureAction.rateAgain ||
          SrsReviewGestureAction.rateHard ||
          SrsReviewGestureAction.rateGood ||
          SrsReviewGestureAction.rateEasy:
        if (!_busy) _rate(action.rating!);
      case SrsReviewGestureAction.undo:
        if (!_busy) _undoLast();
      case SrsReviewGestureAction.replayAudio:
        _replayAudio();
      case SrsReviewGestureAction.toggleToolbar:
        _toggleChrome();
      case SrsReviewGestureAction.editNote:
        unawaited(_onCardAction(_CardAction.edit));
      case SrsReviewGestureAction.bury:
        unawaited(_onCardAction(_CardAction.bury));
      case SrsReviewGestureAction.suspend:
        unawaited(_onCardAction(_CardAction.suspend));
      case SrsReviewGestureAction.flag:
        unawaited(_onCardAction(_CardAction.flag));
    }
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
    // 手柄：Actions 必须是本页焦点节点的祖先——桌面轮询与 Android 键事件都从
    // primaryFocus 往上派发 GamepadButtonIntent。
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) =>
              _handleGamepadButton(intent.button),
        ),
      },
      child: Focus(
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
    if (_finished && _rwkvPending) return _buildRwkvPending(context);
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

  /// 队列空了而 RWKV 还没准备好：说清楚在等什么（下载 / 回放 / 失败），失败给「重试」。
  Widget _buildRwkvPending(BuildContext context) {
    final SrsRwkvStatus? status = _rwkvStatus;
    final SrsRwkvService? service = _rwkv;
    final bool failed = status?.phase == SrsRwkvPhase.failed;
    final String? detail = switch (status?.phase) {
      SrsRwkvPhase.failed => t.srs_settings_rwkv_failed(
        error: '${status!.error}',
      ),
      SrsRwkvPhase.downloading => t.srs_settings_rwkv_downloading(
        percent: status!.total > 0
            ? (status.done / status.total * 100).round()
            : 0,
      ),
      SrsRwkvPhase.preparing when status!.total > 0 =>
        t.srs_settings_rwkv_preparing(done: status.done, total: status.total),
      SrsRwkvPhase.preparing ||
      SrsRwkvPhase.idle => t.srs_settings_rwkv_preparing_start,
      _ => null,
    };
    return FushiEntranceScope(
      child: Center(
        child: FushiStaggeredEntrance(
          index: 0,
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('srs-review-rwkv-pending'),
            icon: failed ? FushiIcons.error : FushiIcons.warning,
            tone: failed
                ? FushiPlaceholderTone.error
                : FushiPlaceholderTone.neutral,
            message: t.srs_review_rwkv_pending,
            detail: detail,
            action: failed && service != null
                ? FushiFilledButton(
                    key: const ValueKey<String>('srs-review-rwkv-retry'),
                    onPressed: () => srsRunLogged(
                      'SrsRwkvService.start',
                      () => service.start(force: true),
                    ),
                    child: Text(t.retry),
                  )
                : null,
          ),
        ),
      ),
    );
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
    required SrsCardGestureArming gestureArming,
  }) {
    final List<String> bridgeKeys = _currentBridgeKeys();
    final Object inputs = (
      bridgeKeys,
      gestureArming,
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
      bridgeKeys: bridgeKeys,
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
      onCardGesture: _onCardGesture,
      gestureArming: gestureArming,
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
              bottomInset: _bottomBarInset,
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
    final SrsCardGestureArming gestureArming = ref
        .watch(srsReviewGesturesProvider)
        .arming(_side, hideHardEasy: ref.watch(srsReviewHideHardEasyProvider));
    // 原生 Fushi 卡面铺到底栏背后、把底栏高度当滚动内边距；整面 WebView 卡面滚不到底栏
    // 下面，停在底栏上沿（与顶端让位浮动页头同一口径，见 [_cardScrollsUnderHeader]）。
    final bool underBar = rendered?.fushiCardDefinitions != null;
    final Widget cardFace = _cardFace(
      context,
      detail: detail,
      rendered: rendered,
      faceBuilder: faceBuilder,
      language: language,
      zoom: zoom,
      hostCss: hostCss,
      media: media,
      gestureArming: gestureArming,
    );
    return SrsCardLookupHost(
      controller: _lookup,
      // 弹窗整栈关掉：焦点回复习页（WebView / 弹窗拿走过 OS 焦点）。
      onClosed: () => _reclaim(FocusReclaimCause.overlayClosed),
      // 结构恒定（卡面与底栏都是 Stack 里的 Positioned，只换 bottom 值）：换卡在原生 /
      // WebView 卡面间切换时不重挂卡面平台视图。卡面不画自己的底板、不留左右页边距，
      // 透出路由层的形状背景并铺满正文；底栏浮在卡面上面。
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: underBar ? 0 : _bottomBarHeight,
            // Ctrl / ⌘ + 滚轮落在原生区（WebView 上的由页面脚本截下转来）：缩放卡面，
            // 并认领这次滚轮，外层不再滚动。
            child: Listener(
              key: _cardSurfaceKey,
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
              child: SizedBox.expand(
                key: const ValueKey<String>('srs-card-surface'),
                // 结构恒定（卡面在 Stack 第一格）：读首张卡时建起的卡面平台视图出卡后
                // 原地复用，加载指示只是压在上面的第二格。
                child: Stack(
                  fit: StackFit.passthrough,
                  children: <Widget>[
                    // 结构恒定：没在滑时位移为零，卡面平台视图不因手势重挂。
                    SrsSwipeFollow(hint: _swipeHint, child: cardFace),
                    SrsSwipeHintBadge(hint: _swipeHint),
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // 底栏整条（按钮之间、四周留白、底部安全区）归底栏，点按不穿到下面的卡面：
            // 原生 Fushi 卡面铺在底栏背后，穿过去会被 SrsCardGestureRegion 当成点卡面空白、
            // 切换悬浮顶栏（按偏一点评分按钮就弹顶栏）；整面 WebView 卡面停在底栏上沿，
            // 这条本来就点不到卡面——两条路径同一口径。
            child: Listener(
              key: const ValueKey<String>('srs-review-bottom-bar'),
              behavior: HitTestBehavior.opaque,
              child: _SrsHeightReporter(
                onHeight: _onBottomBarHeight,
                child: _withBottomBarScrim(
                  context,
                  underBar: underBar,
                  child: SafeArea(
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
                          duration: fushiMotionDuration(
                            context,
                            FushiMotion.short,
                          ),
                          switchInCurve: FushiMotion.enter,
                          switchOutCurve: FushiMotion.exit,
                          child: _showingAnswer
                              ? _buildRatingRow(context)
                              : _buildShowAnswer(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 原生 Fushi 卡面铺在底栏背后滚动：底栏垫一层由透明渐变到卡面底色的底板，滚到底栏
  /// 下面的释义 / 来源不再从评分按钮之间透出来、跟按钮文字叠在一起（手机上评分按钮
  /// 占满整行，透出来的字尤其乱）。整面 WebView 卡面停在底栏上沿，不需要底板。
  Widget _withBottomBarScrim(
    BuildContext context, {
    required bool underBar,
    required Widget child,
  }) {
    if (!underBar) return child;
    final SrsCardAppearance appearance = ref.watch(srsCardAppearanceProvider);
    final ColorScheme app = Theme.of(context).colorScheme;
    // 与卡面同一判据：自定义配色时卡面自己铺底（卡面配色的 surface），否则透出页面底色。
    final Color surface = appearance.colorSource == SrsCardColorSource.custom
        ? srsCardColorScheme(appearance, app).surface
        : app.surface;
    return DecoratedBox(
      key: const ValueKey<String>('srs-review-bottom-bar-scrim'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[surface.withValues(alpha: 0), surface, surface],
          stops: const <double>[0, 0.3, 1],
        ),
      ),
      child: child,
    );
  }

  void _onBottomBarHeight(double height) {
    if (!mounted || (height - _bottomBarHeight).abs() < 0.5) return;
    _bottomBarInset.value = height;
    setState(() => _bottomBarHeight = height);
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
            message: _withKeyHint(
              t.srs_review_show_answer,
              ShortcutAction.srsReviewPrimary,
            ),
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
          message: split
              ? label
              : _withKeyHint(label, ShortcutAction.srsReviewReplayAudio),
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
      // RWKV 牌组（RWKV-Instant）：进复习队列的卡在估计回忆率降到目标时出现，不看到期日，
      // FSRS-7 算的天数不是它真正回来的时间，不显示。学习 / 重学步仍按步长计时，照常显示。
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
        tooltip: _withKeyHint(label, switch (rating) {
          1 => ShortcutAction.srsReviewAgain,
          2 => ShortcutAction.srsReviewHard,
          3 => ShortcutAction.srsReviewGood,
          _ => ShortcutAction.srsReviewEasy,
        }),
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

/// 布局后回报子树高度（变了才报，排在本帧绘制之后）：复习页据此给浮动底栏让位。
class _SrsHeightReporter extends SingleChildRenderObjectWidget {
  const _SrsHeightReporter({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSrsHeightReporter(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSrsHeightReporter renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderSrsHeightReporter extends RenderProxyBox {
  _RenderSrsHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final double height = size.height;
    if (height == _reported) return;
    _reported = height;
    // 布局阶段不能 setState：本帧收尾时再报（布局发生在帧内，帧后回调必然会跑）。
    SchedulerBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}

// ------------------------------------------------------------------ 滑动反馈

/// 滑动途中的反馈：按主轴锁定的拖动位移、离「松手即触发」的进度（0..1）、松手会执行的动作。
@immutable
class SrsSwipeHint {
  const SrsSwipeHint({
    required this.offset,
    required this.progress,
    required this.action,
  });

  final Offset offset;
  final double progress;
  final SrsReviewGestureAction action;

  bool get committed => progress >= 1;

  @override
  bool operator ==(Object other) =>
      other is SrsSwipeHint &&
      other.offset == offset &&
      other.progress == progress &&
      other.action == action;

  @override
  int get hashCode => Object.hash(offset, progress, action);
}

/// 卡面跟手：滑动途中按拖动位移的一部分平移卡面，松手 / 作废时弹回（[FushiMotion.release]）。
/// 墨水屏 / 系统「减弱动态效果」下不移动。结构恒定，[child]（卡面平台视图）不会因此重挂。
class SrsSwipeFollow extends StatelessWidget {
  const SrsSwipeFollow({super.key, required this.hint, required this.child});

  final ValueListenable<SrsSwipeHint?> hint;
  final Widget child;

  /// 卡面跟手的比例（拖 100 逻辑像素，卡面走 40）。
  static const double kFollow = 0.4;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SrsSwipeHint?>(
    valueListenable: hint,
    child: child,
    builder: (BuildContext context, SrsSwipeHint? h, Widget? child) {
      final bool motion = fushiMotionEnabled(context);
      final Offset target = motion && h != null
          ? h.offset * kFollow
          : Offset.zero;
      return TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(end: target),
        // 跟手时零时长（逐帧即到）；松手 / 作废时弹回。
        duration: h != null
            ? Duration.zero
            : fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.release,
        child: child,
        builder: (BuildContext context, Offset offset, Widget? child) =>
            Transform.translate(
              key: const ValueKey<String>('srs-swipe-follow'),
              offset: offset,
              child: child,
            ),
      );
    },
  );
}

/// 滑动途中卡面中央的动作提示：评分按评分按钮同一套色调（两套设计系统各自的配色），
/// 其余动作用次要容器色 + 图标；越接近「松手即触发」越实，到了略放大。淡入淡出走
/// [FushiMotion]，墨水屏 / 减弱动态效果下直接到位。
class SrsSwipeHintBadge extends StatefulWidget {
  const SrsSwipeHintBadge({super.key, required this.hint});

  final ValueListenable<SrsSwipeHint?> hint;

  @override
  State<SrsSwipeHintBadge> createState() => _SrsSwipeHintBadgeState();
}

class _SrsSwipeHintBadgeState extends State<SrsSwipeHintBadge> {
  /// 最近一次非空的提示：淡出期间照旧画它。
  SrsSwipeHint? _last;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder<SrsSwipeHint?>(
      valueListenable: widget.hint,
      builder: (BuildContext context, SrsSwipeHint? h, Widget? _) {
        if (h != null) _last = h;
        final SrsSwipeHint? shown = _last;
        final double opacity = h == null
            ? 0
            : (h.committed ? 1 : 0.35 + 0.5 * h.progress);
        return AnimatedOpacity(
          opacity: opacity,
          duration: fushiMotionDuration(context, FushiMotion.micro),
          curve: FushiMotion.standard,
          child: shown == null
              ? const SizedBox.shrink()
              : Center(
                  child: AnimatedScale(
                    scale: shown.committed && fushiMotionEnabled(context)
                        ? 1.08
                        : 1,
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    curve: FushiMotion.release,
                    child: _badge(context, shown),
                  ),
                ),
        );
      },
    ),
  );

  Widget _badge(BuildContext context, SrsSwipeHint h) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int? rating = h.action.rating;
    final ({Color background, Color foreground}) colors = rating != null
        ? srsRatingColors(
            SrsRatingTone.values[rating - 1],
            cs,
            apple: isGlassDesign(context),
          )
        : (
            background: cs.secondaryContainer,
            foreground: cs.onSecondaryContainer,
          );
    final IconData? icon = srsReviewGestureActionIcon(h.action);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return DecoratedBox(
      key: ValueKey<String>('srs-swipe-hint-${h.action.wire}'),
      decoration: ShapeDecoration(
        color: colors.background,
        shape: const StadiumBorder(),
        shadows: kElevationToShadow[2],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.page,
          vertical: tokens.spacing.gap,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            if (icon != null) FushiIcon(icon, color: colors.foreground),
            Text(
              srsReviewGestureActionLabel(h.action),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: colors.foreground),
            ),
          ],
        ),
      ),
    );
  }
}
