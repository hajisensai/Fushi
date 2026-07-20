import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/anki/anki_mined_card_action_sheet.dart';
import 'package:hibiki/src/lookup/effective_lookup_size.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/pages/implementations/sentence_context_dialog.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
import 'package:hibiki/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/utils.dart';

/// Number of characters of the body text that the looked-up word actually
/// occupies, used to drive the in-text lookup highlight (`hoshiSelection
/// .highlightSelection`).
///
/// BUG-206: this must be the length of the **inflected surface form as it
/// appears in the body** (the deinflection's matched source), NOT the length of
/// the dictionary headword. For 「うやうやしく」(6 chars in the body) the dictionary
/// entry's [DictionaryEntry.word] is the headword 「恭しい」(3 runes); highlighting
/// 3 chars covers only part of the word and — when the word is split across DOM
/// text nodes on Android — renders as two misaligned bands ("multi-select").
///
/// [DictionarySearchResult.bestLength] already carries the matched source length
/// (the FFI deinflection's `matched`, mirrored as Yomitan's `originalTextLength`)
/// and [Language.getFinalHighlightLength] is the canonical way to read it
/// (handling the space-delimited / non-space-delimited split). We only highlight
/// when there is at least one term entry, preserving the previous "no entries →
/// no highlight" behavior.
int lookupHighlightCharCount({
  required DictionarySearchResult result,
  required String searchTerm,
  required Language language,
}) {
  if (result.entries.isEmpty) return 0;
  return language.getFinalHighlightLength(
    result: result,
    searchTerm: searchTerm,
  );
}

/// A page template which assumes use of [BaseSourcePageState] by which all
/// pages in the app that are used for when using a certain source will
/// conveniently share base functionality.f
abstract class BaseSourcePage extends BasePage {
  /// Create an instance of this tab page.
  const BaseSourcePage({
    required this.item,
    super.key,
  });

  /// The media item pertaining to this usage instance of the source.
  final MediaItem? item;

  @override
  BaseSourcePageState<BaseSourcePage> createState();
}

/// A base class for providing all pages used for media in the app with a
/// collection of shared functions and variables. In large part, this was
/// implemented to define shortcuts for common lengthy methods across UI code.
abstract class BaseSourcePageState<T extends BaseSourcePage>
    extends BasePageState<T> {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seedWarmPopup();
    });
  }

  /// BUG-092: seed a single persistent, hidden popup slot on open so its
  /// [DictionaryPopupWebView] cold-loads popup.html + JS + CSS ONCE while the
  /// page is idle, and is then reused warm for every lookup — eliminating the
  /// per-lookup WebView cold-load (the white flash) on the reader / video /
  /// audiobook surfaces. The reader's pre-lookup [prunePopupStack] and the
  /// dismiss path both preserve this slot rather than discard it.
  ///
  /// Low-memory mode keeps no warm slot (it disposes the popup on close), so it
  /// is skipped there to honour the memory budget.
  void _seedWarmPopup() {
    if (!mounted) return;
    // 此刻 AppModel 已初始化（源页开页在 init 之后）→ 安全设真实 lowMemory。
    _popup.lowMemory = appModel.lowMemoryMode;
    _popup.onLookupStarted = _recordLookupCounter;
    _popup.seedWarmSlot(seedResult: kPopupSearchingPlaceholderResult);
  }

  @override
  void dispose() {
    _visibleRenderFailsafeTimer?.cancel();
    // TODO-058：controller 现持有挂起层兜底 Timer，作为其所有者必须 dispose 取消，防泄漏。
    _popup.dispose();
    _isSearchingNotifier.dispose();
    super.dispose();
  }

  /// Allows customisation of dictionary background.
  double get dictionaryBackgroundOpacity => 0.95;

  /// Allows customisation of opacity of dictionary entries.
  double get dictionaryEntryOpacity => 1;

  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );

  final ValueNotifier<bool> _isSearchingNotifier = ValueNotifier<bool>(false);

  Rect? _pendingSelectionRect;

  int _searchGeneration = 0;

  /// TODO-716：桌面对齐手机的"滑动关闭弹窗"。弹窗显示时全屏 barrier 盖住正文，
  /// 在 barrier 上水平拖累计位移过阈即关一层（[dismissTopPopup]，与光标 B/Esc 逐层
  /// 退回同语义；TODO-834 后这与「点 barrier 真空白清整栈」不同——滑动是明确的
  /// 关前置弹窗手势，对齐手机顶栏 [SwipeDismissWrapper] 的逐层关），仅当
  /// [ReaderHibikiSource.enableSwipeToClose] 开启时生效。
  /// 单击经 Flutter 手势竞技场仍走 onTap，与拖动互斥。阈值/灵敏度复用
  /// [swipeDismissThreshold]（与顶栏 [SwipeDismissWrapper] 同一公式，不漂移）。
  final BarrierSwipeDismissTracker _barrierSwipe = BarrierSwipeDismissTracker();

  void _onBarrierHorizontalDragStart(DragStartDetails details) {
    _barrierSwipe.begin();
  }

  void _onBarrierHorizontalDragUpdate(DragUpdateDetails details) {
    _barrierSwipe.update(details.delta.dx);
  }

  void _onBarrierHorizontalDragEnd(DragEndDetails details) {
    // 双向水平（左右皆可），与手机 [SwipeDismissWrapper] 的 _dragX.abs() 一致；
    // 过阈关一层（[dismissTopPopup]）。阈值/位移累积由共享纯追踪器统一，不漂移。
    if (_barrierSwipe.end(
      sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
    )) {
      dismissTopPopup();
    }
  }

  bool get isDictionaryShown => _hasVisiblePopup(_popup.entries);

  @protected
  void onDismissBarrierHover(PointerHoverEvent event) {}

  /// TODO-1027：点全屏 dismiss barrier（弹窗矩形外的真空白处）的钩子。默认行为
  /// 是一次性清整栈（[clearDictionaryResult] → 会话收尾，保留隐藏热槽 BUG-092）—
  /// 视频/有声书/首页等横排表面维持「点空白关栈」旧语义不变。
  ///
  /// 阅读器覆写此钩子（见 reader_hibiki_page.dart）：barrier 叠在阅读器 WebView 之上，
  /// 点弹窗外的新词正文若只关栈，tap 到不了底下的 WebView，必须再点一次才查新词
  /// （查词被关窗逻辑堵塞）。覆写后用 WebView 的 RenderBox 把 [globalPos] 逆映成
  /// CSS 坐标转发给选词：命中词→无缝换新查词弹窗（复用热槽），命中真空白→才关栈。
  @protected
  void onDismissBarrierTap(Offset globalPos) => clearDictionaryResult();

  Widget? buildPopupAudioControls() => null;

  /// Handles leaving a source page. All sources should
  /// use this and wrap their [build] function with a [PopScope].
  Future<bool> onWillPop() async {
    final mediaSource = appModel.currentMediaSource;
    final item = widget.item;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await onSourcePagePop();

    if (mediaSource != null) {
      await appModel.closeMedia(
        ref: ref,
        mediaSource: mediaSource,
        item: item,
      );
    }

    if (item != null && messenger != null) {
      triggerAutoSyncAfterClose(
        db: appModel.database,
        mediaIdentifier: item.mediaIdentifier,
        messenger: messenger,
        onReport: appModel.presentAutoConflicts,
      );
    }
    return true;
  }

  /// Action to perform within the source page upon closing the media.
  Future<void> onSourcePagePop() async {}

  DictionaryPopupEntry? _deferredPopupItem;
  int _deferredGeneration = 0;
  DictionaryPopupEntry? _visibleRenderPendingItem;
  int _visibleRenderPendingGeneration = 0;
  Timer? _visibleRenderFailsafeTimer;

  Future<int> searchDictionaryResult({
    required String searchTerm,
    required Rect selectionRect,
    int? overrideMaximumTerms,
    bool deferDisplay = false,
  }) async {
    overrideMaximumTerms ??= appModel.maximumTerms;

    final gen = ++_searchGeneration;
    _pendingSelectionRect = selectionRect;
    _deferredPopupItem = null;

    try {
      if (!deferDisplay) {
        _isSearchingNotifier.value = true;
      }

      final dictionaryResult = await appModel.searchDictionary(
        searchTerm: searchTerm,
        searchWithWildcards: false,
        overrideMaximumTerms: overrideMaximumTerms,
      );

      if (_searchGeneration != gen) return 0;

      appModel.addToDictionaryHistory(result: dictionaryResult);

      // 复用条件与旧 _reusableHiddenTopPopup 等价：栈恰为 [单个隐藏热槽] 时原地复用，
      // 否则（嵌套等）追加新层。reuse=false 时 beginTop 直接 append。
      final bool reuse = _popup.entries.length == 1 &&
          _popup.entries.first.isWarmSlot &&
          !_popup.entries.first.visible;
      final DictionaryPopupEntry item = _popup.beginTop(
        term: searchTerm,
        rect: selectionRect,
        reuseWarmSlot: reuse,
        replaceStack: false,
        visible: false,
      );
      // TODO-962：阅读器/有声书弹窗此前硬编码 allLoaded:true，关掉了「加载更多」分页
      // （[_buildPopupLayer] 的 onScrolledToBottom 恒 null），使弹窗永远停在第一页。
      // maximumTerms 按 glossary 注释**行**计预算（language.dart），一个高频词头的注释
      // 行就能吃满整个上限 → 只剩 1 个词头（首页/视频弹窗均正常，唯一差异就在此标志 +
      // load-more 接线）。按真实截断计算：结果数 < 本次查询上限 ⇒ 已全部加载，否则可能
      // 被截断，开放下滑加载（[loadMoreForLayer]，与 mixin/home 同构）。
      _popup.fillResult(
        item,
        result: dictionaryResult,
        allLoaded: dictionaryResult.entries.length < overrideMaximumTerms,
      );

      // TODO-058 / BUG-480：嵌套冷层继续挂起到 popupRendered；复用热槽也不能裸奔
      // 直显内容区。macOS 上隐藏/屏外热槽的 JS 注入可能没跑到当前结果，直 show 会露出
      // 白色空 WebView。需要 WebView 渲染的结果先显示带盖板的壳，并在可见后一帧强制
      // 重推当前结果，收到 popupRendered 后再撤盖板。空结果走 Flutter 占位，不靠 WebView。
      final bool needsWebViewRender = _itemNeedsWebViewRender(item);
      final bool revealImmediately = reuse || dictionaryResult.entries.isEmpty;
      if (deferDisplay) {
        _deferredPopupItem = item;
        _deferredGeneration = gen;
      } else if (revealImmediately && needsWebViewRender) {
        _showPopupWaitingForRender(item, gen);
      } else if (revealImmediately) {
        _popup.show(item);
      } else {
        _popup.markPendingReveal(item);
      }

      final int highlightCount = lookupHighlightCharCount(
        result: dictionaryResult,
        searchTerm: searchTerm,
        language: appModel.targetLanguage,
      );

      final bool arEnabled = ReaderHibikiSource.instance.autoReadOnLookup;
      if (arEnabled && dictionaryResult.entries.isNotEmpty) {
        final entry = dictionaryResult.entries.first;
        final expression = entry.word;
        final reading = entry.reading;
        if (expression.isNotEmpty) {
          _autoReadWord(expression, reading);
        }
      }

      return highlightCount;
    } finally {
      if (_searchGeneration == gen &&
          (!deferDisplay || _deferredPopupItem == null) &&
          _visibleRenderPendingItem == null) {
        _isSearchingNotifier.value = false;
        _pendingSelectionRect = null;
      }
    }
  }

  /// TODO-962：阅读器/有声书弹窗第 [index] 层「加载更多」——续查下一批词头并增量追加。
  ///
  /// 与 [DictionaryPageMixin.loadMoreForEntry] / [HomeDictionaryPageState] 的
  /// `_loadMore` 同构：以「当前已显示词条数 + [AppModel.maximumTerms]」为新上限重查
  /// 同一个 [searchTerm]，再 [DictionaryPopupController.fillResult] 更新该层
  /// （`notifyListeners` 经 [buildDictionary] 的 [AnimatedBuilder] 自动重建，无需
  /// setState）。webview 的 `_pushResults` 据 searchTerm 不变 + entries 增多自动判定
  /// `isLoadMore` → 走 `window.updatePopupIncremental()` 增量渲染，保滚动位/热槽。
  /// [allLoaded] 仍按真实截断（结果数 < 新上限）计算，到底即关闭后续 load-more。
  Future<void> loadMoreForLayer(int index) async {
    final List<DictionaryPopupEntry> entries = _popup.entries;
    if (index < 0 || index >= entries.length) return;
    final DictionaryPopupEntry entry = entries[index];
    final DictionarySearchResult? current = entry.result;
    if (entry.allLoaded || entry.isSearching || current == null) return;

    final int newMax = current.entries.length + appModel.maximumTerms;
    entry.isSearching = true;
    try {
      final DictionarySearchResult result = await appModel.searchDictionary(
        searchTerm: entry.searchTerm,
        searchWithWildcards: false,
        overrideMaximumTerms: newMax,
      );
      // 续查期间该层可能被裁掉/换词（嵌套查词、关栈）；用身份核对确保只更新原层。
      if (!mounted || !_popup.entries.contains(entry)) return;
      _popup.fillResult(
        entry,
        result: result,
        allLoaded: result.entries.length < newMax,
      );
    } finally {
      // fillResult 成功路径已把 isSearching 清 false；失败/提前 return 在此兜底复位。
      if (_popup.entries.contains(entry) && entry.isSearching) {
        entry.isSearching = false;
      }
    }
  }

  void showDeferredPopup({Rect? selectionRect}) {
    final item = _deferredPopupItem;
    final gen = _deferredGeneration;
    _deferredPopupItem = null;
    if (item != null) {
      if (selectionRect != null) {
        item.selectionRect = selectionRect;
      }
      // item 已在栈内（beginTop 时加入，隐藏）。需要 WebView 渲染的结果先带盖板
      // 翻可见，等当前结果 popupRendered 后再撤盖板，避免 macOS 隐藏热槽漏注入后露白。
      if (_itemNeedsWebViewRender(item)) {
        _showPopupWaitingForRender(item, gen);
      } else {
        _popup.show(item);
      }
    }
    if (_searchGeneration == gen && _visibleRenderPendingItem == null) {
      _isSearchingNotifier.value = false;
      _pendingSelectionRect = null;
    }
  }

  bool _itemNeedsWebViewRender(DictionaryPopupEntry item) {
    final result = item.result;
    if (result == null) return false;
    // A completed empty lookup is rendered by Flutter's no-results placeholder.
    // Waiting for the reused warm WebView here exposes an empty shell on macOS.
    return result.entries.isNotEmpty || result.kanjiResults.isNotEmpty;
  }

  void _showPopupWaitingForRender(
    DictionaryPopupEntry item,
    int generation,
  ) {
    _visibleRenderFailsafeTimer?.cancel();
    _visibleRenderPendingItem = item;
    _visibleRenderPendingGeneration = generation;
    _isSearchingNotifier.value = true;
    _popup.show(item);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _visibleRenderPendingItem != item ||
          _visibleRenderPendingGeneration != generation ||
          !_popup.entries.contains(item) ||
          !item.visible) {
        return;
      }
      // refreshCurrentResult 已去重（同一结果不再全量重推）：返回 false 表示当前
      // 结果**已经渲染完成**、popupRendered 不会再来（阅读器 deferDisplay 路径下
      // 渲染信号可能早于盖板架起）——立即走同一条 rendered 路径撤盖板，不空等
      // 1.8s failsafe。state 为 null（WebView 未挂载）时维持等待，交给 failsafe。
      final bool renderPending =
          item.webViewKey.currentState?.refreshCurrentResult() ?? true;
      if (!renderPending) {
        _onPopupLayerRendered(_popup.entries.indexOf(item), item);
      }
    });

    _visibleRenderFailsafeTimer = Timer(
      DictionaryPopupController.kRevealFailsafeTimeout,
      () {
        if (!mounted ||
            _visibleRenderPendingItem != item ||
            _visibleRenderPendingGeneration != generation) {
          return;
        }
        _clearVisibleRenderPending();
      },
    );
  }

  void _clearVisibleRenderPending({DictionaryPopupEntry? item}) {
    if (item != null && _visibleRenderPendingItem != item) return;
    _visibleRenderFailsafeTimer?.cancel();
    _visibleRenderFailsafeTimer = null;
    _visibleRenderPendingItem = null;
    _visibleRenderPendingGeneration = 0;
    _isSearchingNotifier.value = false;
    _pendingSelectionRect = null;
  }

  /// Resolve audio exactly like Hoshi: enabled sources only, no TTS fallback.
  Future<void> _autoReadWord(String expression, String reading) async {
    await LookupAutoReadCoordinator.instance.runAutomatic(
      expression: expression,
      reading: reading,
      play: () => _playAutoReadWord(expression, reading),
    );
  }

  Future<void> _playAutoReadWord(String expression, String reading) {
    // Prefer the popup's own <audio> (unified fast path); fall back to the Dart
    // player when the popup WebView is not ready. Capture the state once so the
    // callback does not re-evaluate the getter mid-play.
    final DictionaryPopupWebViewState? popup = topPopupState;
    return autoReadWordUnified(
      appModel,
      expression,
      reading,
      playInWebView: popup?.playWordAudioUrl,
    );
  }

  void clearDictionaryResult() => _dismissPopupAt(0);

  // 弹窗盒子尺寸随「界面大小」一起放大：阅读器/词典页整树被 HibikiAppUiScaleNeutralizer
  // 中和回原生密度（净缩放=1），弹窗盒子若不乘 appUiScale，界面 200% 时它仍是原生小尺寸
  // （内容放大走 WebView 内 CSS zoom，见 DictionaryPopupWebView）。
  //
  // Phase B（尺寸拖拽）：拖动把手期间用预览态 [_popupResizePreview]（基准逻辑像素）临时
  // 覆盖偏好真值，让盒子实时跟手放大/缩小；松手 [_onPopupResizeEnd] 才落偏好并清预览。
  double get popupMaxWidth =>
      (_popupResizePreview?.width ?? appModel.popupMaxWidth) *
      appModel.appUiScale;
  double get popupMaxHeight =>
      (_popupResizePreview?.height ?? appModel.popupMaxHeight) *
      appModel.appUiScale;
  double get popupPadding => 6;
  double get popupBottomReserve => 0;
  double get popupTopReserve => 0;

  /// 竖排表面（reader vertical-rl）查词时让弹窗放当前列左/右侧而非上/下。
  /// 默认 false（视频/有声书横排字幕、首页等非竖排表面不变）。
  bool get popupVerticalWriting => false;
  late final Listenable _popupListenable =
      Listenable.merge([_popup, _isSearchingNotifier]);

  /// Phase B 尺寸拖拽的预览态（基准逻辑像素，未缩放）。非空 = 正在拖把手，[popupMaxWidth]
  /// / [popupMaxHeight] 用它临时覆盖偏好实时预览；null = 未拖，用已落库真值。松手清空。
  LookupSize? _popupResizePreview;

  /// Phase B 拖拽尺寸的**冻结原点**（2026-07-15）：拖右下把手时把弹窗左上角钉在拖拽起点，
  /// 只往右下生长（否则贴词定位在词靠右时会把左缘往左推=「从右下拖却从左上动」）。持续到
  /// 换词（选区变）或关窗；[_popupResizeAnchorSelection] 记它属于哪张卡（哪个选区）。
  Offset? _popupResizeAnchorTopLeft;
  Rect? _popupResizeAnchorSelection;

  /// 顶层卡片本帧贴词算出的 rect / 选区缓存，供 [_onPopupResizeStart] 取当前左上角冻结。
  Rect? _topPopupAnchoredRect;
  Rect? _topPopupSelectionRect;

  /// 拖把手起手：把当前偏好基准尺寸存入预览态（后续增量累积其上），并冻结顶层卡当前左上角。
  void _onPopupResizeStart() {
    setState(() {
      _popupResizePreview =
          LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight);
      _popupResizeAnchorTopLeft = _topPopupAnchoredRect?.topLeft;
      _popupResizeAnchorSelection = _topPopupSelectionRect;
    });
  }

  /// 拖把手进行：把盒坐标系增量位移 [deltaPx] 经 [resolveDraggedLookupSize] 折算回基准
  /// （除 appUiScale）并 clamp，实时驱动重建。
  void _onPopupResizeUpdate(Offset deltaPx) {
    final LookupSize base = _popupResizePreview ??
        LookupSize(appModel.popupMaxWidth, appModel.popupMaxHeight);
    setState(() {
      _popupResizePreview = resolveDraggedLookupSize(
        currentBaseWidth: base.width,
        currentBaseHeight: base.height,
        deltaWidthPx: deltaPx.dx,
        deltaHeightPx: deltaPx.dy,
        uiScale: appModel.appUiScale,
      );
    });
  }

  /// 松手：把预览尺寸一次性落偏好（`setPopupMaxWidth/Height` 单一真值，与设置滑杆同源），
  /// 清空预览态回到「读真值」。
  void _onPopupResizeEnd() {
    final LookupSize? committed = _popupResizePreview;
    setState(() => _popupResizePreview = null);
    if (committed != null) {
      appModel.setPopupMaxWidth(committed.width);
      appModel.setPopupMaxHeight(committed.height);
    }
  }

  /// 拖拽被竞技场中途取消：丢弃预览态回到「读真值」，不落偏好；一并撤销冻结原点（回贴词）。
  void _onPopupResizeCancel() {
    if (_popupResizePreview == null) return;
    setState(() {
      _popupResizePreview = null;
      _popupResizeAnchorTopLeft = null;
      _popupResizeAnchorSelection = null;
    });
  }

  Widget buildDictionary() {
    return Theme(
      data: appModel.overrideDictionaryTheme ?? theme,
      child: AnimatedBuilder(
        animation: _popupListenable,
        builder: (context, _) {
          final stack = _popup.entries;
          final searching = _isSearchingNotifier.value;
          if (stack.isEmpty && !searching) return const SizedBox.shrink();
          final hasVisiblePopup = _hasVisiblePopup(stack);
          final visibleTopIndex = _lastVisiblePopupIndex(stack);

          final showLoadingPlaceholder =
              searching && !hasVisiblePopup && _pendingSelectionRect != null;

          return LayoutBuilder(
            builder: (context, constraints) {
              final screen = Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                // BUG-135: 隐藏热槽停到屏幕右外侧（_buildPopupLayer），Clip.none 让它
                // 在屏外照常预热、又不裁掉（默认 hardEdge 会裁，原生 WebView 失温）。
                clipBehavior: Clip.none,
                children: [
                  if (hasVisiblePopup || searching)
                    Positioned.fill(
                      child: Listener(
                        onPointerHover: onDismissBarrierHover,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          // TODO-834（反转 TODO-720 / BUG-403）：点**所有弹窗矩形外**
                          // 的真空白 = 一次性清整栈（会话级路径 [clearDictionaryResult]
                          // → [_dismissPopupAt(0)] 触发会话收尾 [onAllPopupsDismissed]，
                          // 保留隐藏热槽 BUG-092）。barrier 只在弹窗矩形之外命中（弹窗本
                          // 体的 onTapOutside 单独处理「点某层本体空白」只关其后代）。光标
                          // B/Esc 的逐层退回（[dismissTopPopup]）不受本改动影响。
                          // TODO-1027：barrier 上 onTapUp 拿全局坐标转发给
                          // [onDismissBarrierTap]（阅读器覆写为「命中词→换新查词」，
                          // 默认表面仍清整栈）。onTapUp 与 onHorizontalDrag* 经
                          // Flutter 手势竞技场天然分流（单击 vs 横拖），互斥不冲突。
                          onTapUp: (details) =>
                              onDismissBarrierTap(details.globalPosition),
                          // TODO-716：桌面对齐手机——在 barrier 上水平拖过阈同样关一层。
                          // 仅当滑动关闭开关开启时挂横拖识别（否则只 onTap，与旧行为一致）。
                          // 竞技场天然分流：单击走 onTap、横拖走 onHorizontalDrag*，互斥。
                          onHorizontalDragStart:
                              ReaderHibikiSource.instance.enableSwipeToClose
                                  ? _onBarrierHorizontalDragStart
                                  : null,
                          onHorizontalDragUpdate:
                              ReaderHibikiSource.instance.enableSwipeToClose
                                  ? _onBarrierHorizontalDragUpdate
                                  : null,
                          onHorizontalDragEnd:
                              ReaderHibikiSource.instance.enableSwipeToClose
                                  ? _onBarrierHorizontalDragEnd
                                  : null,
                          child: Container(
                            color: Colors.transparent,
                          ),
                        ),
                      ),
                    ),
                  if (showLoadingPlaceholder) _buildLoadingPlaceholder(screen),
                  for (int i = 0; i < stack.length; i++)
                    _buildPopupLayer(
                      stack,
                      i,
                      screen,
                      isTop: i == visibleTopIndex,
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildLoadingPlaceholder(Size screen) {
    // 加载占位只在「顶层」搜索期出现（嵌套搜索时父弹窗仍 visible，hasVisiblePopup
    // 为真，不显示占位），故按 index 0 取竖排避让。
    final pos = _calculatePopupPosition(
      _pendingSelectionRect!,
      screen,
      verticalWriting: _layerVerticalWriting(0),
    );
    final effectiveCs = (appModel.overrideDictionaryTheme ?? theme).colorScheme;
    final fillColor = appModel.overrideDictionaryColor ?? effectiveCs.surface;

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: HibikiPopupSurface(
        color: fillColor,
        child: Column(
          children: [
            LinearProgressIndicator(
              backgroundColor: Colors.transparent,
              color: effectiveCs.primary,
              minHeight: 2.75,
            ),
            Expanded(child: Container()),
          ],
        ),
      ),
    );
  }

  Widget _buildPopupLayer(
    List<DictionaryPopupEntry> stack,
    int index,
    Size screen, {
    required bool isTop,
  }) {
    final item = stack[index];
    final pos = _calculatePopupPosition(
      item.selectionRect,
      screen,
      verticalWriting: _layerVerticalWriting(index),
    );
    // Phase B 拖拽尺寸：缓存顶层卡当前 rect/选区，供 [_onPopupResizeStart] 冻结其左上角。
    if (isTop) {
      _topPopupSelectionRect = item.selectionRect;
      _topPopupAnchoredRect = pos;
    }
    final isDark = (appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark;

    // BUG-135 parking + Visibility 几何收口在 [parkedPopupLayer]。
    return parkedPopupLayer(
      pos: pos,
      // BUG-797：「选择句子上下文」原生对话框打开期间把弹窗停靠屏外，否则原生平台视图
      // （WebView2 / Android platform view）盖住 showAppDialog 弹的对话框（层级不对）。
      visible: item.visible && !_sentenceContextDialogOpen,
      screen: screen,
      child: DictionaryPopupLayer(
        result: item.result,
        webViewKey: item.webViewKey,
        keepWebViewWarm: item.isWarmSlot,
        // TODO-869：本层有后代弹窗时注入 __hasChildPopup，点卡片本体留白才能关子窗。
        hasChildPopup: index < stack.length - 1,
        isDark: isDark,
        overrideFillColor: appModel.overrideDictionaryColor,
        onDismiss: () => _dismissPopupAt(index),
        // TODO-407②：平台/偏好级"滑动关闭"开关（Windows/Linux 默认 false）。
        enableSwipeToClose: ReaderHibikiSource.instance.enableSwipeToClose,
        // TODO-407①：顶层仍渲染"X 关闭"并走既有关闭汇聚点 [_dismissPopupAt(0)]
        // （不破坏 BUG-072 续播 / 清句 / 清栈）。
        onClose: () => _dismissPopupAt(index),
        // TODO-485：嵌套层即便禁用滑动关闭，也有显式返回父层入口。
        onBack: null,
        // Phase B：app 内弹窗右下角尺寸拖拽把手（全 5 平台）。拖动 = 可视化改「最大宽高」
        // 偏好（与设置滑杆同一真值）。任意层都能拖（都编辑共享真值），预览态在宿主级。
        showResizeGrip: true,
        onResizeStart: _onPopupResizeStart,
        onResizeUpdate: _onPopupResizeUpdate,
        onResizeEnd: _onPopupResizeEnd,
        onResizeCancel: _onPopupResizeCancel,
        // TODO-834：点**某层弹窗本体的空白区**（非内容区）只关该层衍生的后代层，
        // 保留本层 + 祖先（不关母代）。点顶层（无后代）= no-op 栈不变。
        onTapOutside: () => dismissDescendantsOf(index),
        onRendered: () => _onPopupLayerRendered(index, item),
        // TODO-058 fail-safe：弹窗 WebView 加载失败也走同一翻可见入口（加载失败
        // 也显示，不卡死「点查词什么都不出」）。
        onRenderError: () => _onPopupLayerRendered(index, item),
        headerWidget: index == 0 ? buildPopupAudioControls() : null,
        overlayWidget: isTop ? buildDictionaryLoading() : null,
        onTextSelected: (text, localRect) async {
          final childRect = localRect == Rect.zero
              ? item.selectionRect
              : popupWordScreenRect(
                  webViewKey: item.webViewKey,
                  localRect: localRect,
                  fallback: item.selectionRect,
                );
          prunePopupStack(index + 1);
          final count = await searchDictionaryResult(
            searchTerm: text,
            selectionRect: childRect,
          );
          if (count > 0) {
            item.webViewKey.currentState?.highlightSelection(count);
          }
        },
        onLinkClick: (query, localRect) async {
          final childRect = localRect == Rect.zero
              ? item.selectionRect
              : popupWordScreenRect(
                  webViewKey: item.webViewKey,
                  localRect: localRect,
                  fallback: item.selectionRect,
                );
          prunePopupStack(index + 1);
          // TODO-1190: symmetric with onTextSelected above — mark the clicked
          // headword/link target in this parent card after the child search
          // (it previously highlighted only on plain-text selection, so a
          // headword/kanji-tag tap left the source word unmarked).
          final count = await searchDictionaryResult(
            searchTerm: query,
            selectionRect: childRect,
          );
          if (count > 0) {
            item.webViewKey.currentState?.highlightSelection(count);
          }
        },
        // TODO-962：弹窗滚到底时若该层结果可能被截断（!allLoaded）就续查下一批词头
        // （与 dictionary_page_mixin / home_dictionary_page 同构），webview 的
        // _pushResults 据 searchTerm 不变 + entries 增多自动判 isLoadMore → 走
        // window.updatePopupIncremental() 增量追加，不重渲染整页、保滚动位/热槽。
        onScrolledToBottom:
            item.allLoaded ? null : () => loadMoreForLayer(index),
        onMineEntry: onMineFromPopup,
        onUpdateEntry: onUpdateFromPopup,
        // TODO-948②：阅读器/有声书弹窗收藏按钮接线（视频走 mixin，不经此处）。
        onFavoriteEntry: onFavoriteFromPopup,
        onFavoriteCheck: onFavoriteCheckFromPopup,
        onDuplicateCheck: (expression, reading) async {
          final repo = ref.read(ankiRepositoryProvider);
          return repo.isDuplicate(expression, reading);
        },
        // TODO-614：覆写范围=「全部」时按内容反查可覆写的已存在 note id，让阅读器/
        // 有声书/视频弹窗里更早制的卡也能点绿 ✓↩ 覆写（默认 latest / AnkiDroid 回 null）。
        onOverwriteTargetNoteId: (expression, reading) async {
          final repo = ref.read(ankiRepositoryProvider);
          return repo.findOverwriteTargetNoteId(expression, reading);
        },
        // TODO-1007/1008：点 ✓（卡已存在）弹操作选择（覆写/新增重复卡/查看·在 Anki
        // 中打开），命中多张让用户选哪张。reader 覆写 onMineFromPopup/onUpdateFromPopup
        // 做真实制卡/覆盖（基类无操作）。
        onMinedCardAction: onMinedCardActionFromPopup,
        // TODO-1360：已制卡的词旁「在 Anki 中打开卡片」按钮 → 反查命中卡直接跳转打开。
        onOpenInAnki: onOpenInAnkiFromPopup,
        // TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：仅支持草稿的表面（reader 覆写
        // [supportsSentenceDraft]=true）传入回调；其余表面传 null，弹窗不渲染「+句」。
        onAppendSentence:
            supportsSentenceDraft ? onAppendSentenceToDraft : null,
        onSetSentenceContext:
            supportsSentenceDraft ? onSetSentenceContextToDraft : null,
        onClearSentenceDraft:
            supportsSentenceDraft ? onClearSentenceDraftToDraft : null,
        // Niratan「制卡前调整·选择句子上下文」模态：弹窗按需拉取当前草稿的真实上下
        // 文句（前/当前/后）+ 词偏移做预览。只在支持草稿的表面接线，其余传 null。
        onSentenceContextPreview:
            supportsSentenceDraft ? onSentenceContextPreviewFromDraft : null,
        // BUG-763/766：点某词条「调整上下文」→ 弹 app 原生顶层对话框（不再画在弹窗
        // WebView 内）；确认制卡回该层 WebView（item.webViewKey）精确点中该词条制卡。
        onOpenSentenceContextModal: supportsSentenceDraft
            ? (int entryIndex, String matched) => _openSentenceContextDialog(
                  webViewKey: item.webViewKey,
                  entryIndex: entryIndex,
                  matched: matched,
                )
            : null,
      ),
    );
  }

  /// BUG-797：「制卡·选择句子上下文」原生对话框打开期间置真。查词弹窗是**原生平台视图**
  /// （桌面 WebView2 / Android platform view），总画在 Flutter overlay 之上——`showAppDialog`
  /// 弹的对话框在 Flutter overlay 层，会被原生弹窗**盖住**（用户报「层级不对」，对话框被词典
  /// 弹窗遮住右半边）。对话框期间据此把弹窗 [parkedPopupLayer] 的 `visible` 强制翻假 → 弹窗
  /// 停靠到屏外（[parkedPopupLayer] 的 BUG-135 停靠语义，webview 仍存活、确认制卡回点照常），
  /// 让对话框独占屏幕；关闭后复原。
  bool _sentenceContextDialogOpen = false;

  /// BUG-763/766：弹窗点某词条「调整上下文」→ 弹 **app 原生顶层对话框**
  /// （[SentenceContextDialog]，不再画在查词弹窗 WebView 内——那受弹窗表面尺寸/半透明
  /// 限制，句子框重叠、显示不全）。复用宿主已有 [onSetSentenceContextToDraft] /
  /// [onSentenceContextPreviewFromDraft] 驱动增减 + 预览（后端零改动）；「确认制卡」回
  /// [webViewKey] 那层弹窗精确点中第 [entryIndex] 个词条制卡按钮
  /// （[DictionaryPopupWebViewState.mineEntryByIndex]，复用全部制卡/查重/覆写逻辑）。
  /// BUG-797：对话框打开期间把弹窗 WebView 停靠屏外（见 [_sentenceContextDialogOpen]），
  /// 否则原生平台视图盖住对话框。
  Future<void> _openSentenceContextDialog({
    required GlobalKey<DictionaryPopupWebViewState> webViewKey,
    required int entryIndex,
    required String matched,
  }) async {
    if (!mounted) return;
    setState(() => _sentenceContextDialogOpen = true);
    try {
      await showAppDialog<void>(
        context: context,
        builder: (_) => SentenceContextDialog(
          matched: matched,
          fetchPreview: onSentenceContextPreviewFromDraft,
          setContext: onSetSentenceContextToDraft,
          onConfirm: () =>
              webViewKey.currentState?.mineEntryByIndex(entryIndex),
        ),
      );
    } finally {
      if (mounted) setState(() => _sentenceContextDialogOpen = false);
    }
  }

  /// TODO-058：某弹窗层 WebView 渲染完成（`popupRendered`）。先把挂起的冷层翻为
  /// 可见（[markPendingReveal] 标记的层等到此刻才显示，杜绝白屏一瞬），再交给
  /// [onDictionaryPopupRendered]（阅读器据此把字符光标交给刚显示的顶层弹窗）。
  /// 顺序要紧：先 reveal 再回调，使回调里读到的 [topVisiblePopupIndex] 已是新层。
  void _onPopupLayerRendered(int index, DictionaryPopupEntry item) {
    if (!mounted) return;
    _popup.revealRendered(item);
    _clearVisibleRenderPending(item: item);
    onDictionaryPopupRendered(index);
  }

  void _dismissPopupAt(int index) {
    _searchGeneration++;
    _pendingSelectionRect = null;
    _isSearchingNotifier.value = false;
    _deferredPopupItem = null;
    _clearVisibleRenderPending();
    if (index > 0) {
      final parent = _popup.entries[index - 1];
      parent.webViewKey.currentState?.clearSelection();
    }
    if (index == 0) {
      _popup.lowMemory = appModel.lowMemoryMode;
      // 关栈前清掉热槽 WebView 选区（仅保留热槽的分支需要）。
      if (_popup.entries.isNotEmpty && _popup.entries.first.isWarmSlot) {
        _popup.entries.first.webViewKey.currentState?.clearSelection();
      }
      _popup.dismissAt(0);
      appModel.currentMediaSource?.clearCurrentSentence();
      appModel.currentMediaSource?.clearExtraData();
      onAllPopupsDismissed();
    } else {
      _popup.dismissAt(index);
      onDictionaryStackChanged();
    }
  }

  /// Called when all dictionary popups are dismissed (stack becomes empty).
  /// Override in subclasses to hook post-dismiss logic.
  void onAllPopupsDismissed() {}

  /// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：本表面是否支持「+句」累积草稿。
  /// 默认 false（纯查词/视频 E 未接入），reader 覆写为 true。决定弹窗是否渲染「+句」
  /// 按钮（经 [onAppendSentence] → `window.sentenceDraftEnabled`）。
  @protected
  bool get supportsSentenceDraft => false;

  /// TODO-270 F/G：弹窗「+句」追加当前正查句到本表面会话级制卡草稿，返回累积句数
  /// （含本句）。默认 no-op 返回 0（[supportsSentenceDraft] 为 false 时不会被调用）。
  /// reader 覆写：把当前句 + 句子音频区间推进草稿。
  @protected
  Future<int> onAppendSentenceToDraft() async => 0;

  /// TODO-393「上 N 句 / 下 N 句」上下文选择：把当前句之前 [prevCount] 句、之后
  /// [nextCount] 句作上下文**整体设置**进本表面会话级制卡草稿（不掺历史累积），返回
  /// 上下文句总数（上 N + 下 N）。默认 no-op 返回 0（[supportsSentenceDraft] 为 false
  /// 时不会被调用）。reader/视频覆写：reader 走 DOM 句子上下文，视频走 cue 列表前后取。
  @protected
  Future<int> onSetSentenceContextToDraft(int prevCount, int nextCount) async =>
      0;

  /// TODO-382「+句」可撤销：清空本表面会话级制卡草稿，返回清空后的句数（恒 0）。
  /// 默认 no-op（[supportsSentenceDraft] 为 false 时不会被调用）。reader/视频覆写。
  @protected
  Future<int> onClearSentenceDraftToDraft() async => 0;

  /// Niratan「制卡前调整·选择句子上下文」：把当前会话级草稿的真实上下文句
  /// （上 N / 下 N，已按阅读顺序）+ 当前正查句 + 词在当前句里的偏移打包成 JSON-safe
  /// Map（[buildSentenceContextPreview] 的结构）回给弹窗渲染三栏预览。默认返回空 Map
  /// （[supportsSentenceDraft] 为 false 时不会被调用）。reader/视频覆写：各自提供当前
  /// 正查句与词偏移来源。
  @protected
  Future<Map<String, Object?>> onSentenceContextPreviewFromDraft() async =>
      const <String, Object?>{};

  /// Called when a non-last popup layer is dismissed (the stack shrinks but a
  /// parent popup remains). Override (reader) to keep the char cursor following
  /// the new top popup — covers both B/Esc and swipe dismissal of a deeper layer.
  void onDictionaryStackChanged() {}

  /// Called after the popup at [index] finishes rendering. Override (reader) to
  /// hand the char-level cursor to the freshly shown top popup.
  void onDictionaryPopupRendered(int index) {}

  /// The currently top-most VISIBLE popup's WebView state — the surface the
  /// char-level cursor drives when it lives in the dictionary. Null when no
  /// popup is visible.
  @protected
  DictionaryPopupWebViewState? get topPopupState =>
      _lastVisiblePopup(_popup.entries)?.webViewKey.currentState;

  /// Index of the top-most visible popup in the stack, or -1.
  @protected
  int get topVisiblePopupIndex => _lastVisiblePopupIndex(_popup.entries);

  /// Dismiss only the top-most visible popup (one layer), leaving any parent
  /// popup in place — used by the cursor's B/Esc "back one layer".
  @protected
  void dismissTopPopup() {
    final int index = _lastVisiblePopupIndex(_popup.entries);
    if (index >= 0) _dismissPopupAt(index);
  }

  /// TODO-834：关闭第 [index] 层**衍生的所有后代层**（index 更大的全部层），保留本层
  /// + 祖先。线性扁平栈里 index 即 depth，无分叉，故「后代」= `index+1..end`，用
  /// [DictionaryPopupController.truncateTo] 精确裁掉。点最顶层（无后代）= no-op 栈不变
  /// （本层成新顶层，选区高亮保留，不走清整栈路径）。裁完调一次
  /// [onDictionaryStackChanged] 让光标跟随回到新顶层（与 B/Esc 逐层退回同钩子）。
  @protected
  void dismissDescendantsOf(int index) {
    if (index < 0 || index >= _popup.entries.length - 1) return; // 无后代=no-op
    _popup.truncateTo(index + 1);
    onDictionaryStackChanged();
  }

  /// 竖排避让（放当前列左/右侧而非上/下）只对**顶层弹窗**成立：顶层选区来自
  /// 书面文字，可能是竖排列。嵌套层（index>0）的选区来自上一层弹窗内部，而弹
  /// 窗内容（assets/popup/*）恒为横排，必须按横排上下避让——不能继承外层书的
  /// 竖排设定。
  bool _layerVerticalWriting(int index) => index == 0 && popupVerticalWriting;

  Rect _calculatePopupPosition(
    Rect sel,
    Size screen, {
    bool verticalWriting = false,
  }) {
    // TODO-108：查词弹窗位置计算的单一收口点（reader/有声书/独立查词页家族共用），
    // 底部固定模式忽略选区放屏幕底部全宽面板。video 家族在 dictionary_page_mixin
    // 用同一个 [resolvePopupRect] 收口（不碰 video_hibiki_page）。reserve/padding/
    // verticalWriting 走本类 getter（子类可 override，如 reader 预留底栏）。
    final Rect anchored = resolvePopupRect(
      selectionRect: sel,
      screen: screen,
      bottomDocked: appModel.popupBottomDocked,
      maxWidth: popupMaxWidth,
      maxHeight: popupMaxHeight,
      padding: popupPadding,
      bottomReserve: popupBottomReserve,
      topReserve: popupTopReserve,
      verticalWriting: verticalWriting,
    );
    // Phase B 拖拽尺寸（2026-07-15）：被拖的那张卡（选区匹配）冻结左上角，从右下生长，
    // 消除「词靠右缘时贴词定位把左缘左移」的 bug。底部固定 dock 模式忽略选区、不冻结。
    if (!appModel.popupBottomDocked &&
        _popupResizeAnchorTopLeft != null &&
        _popupResizeAnchorSelection == sel) {
      return anchorPopupTopLeft(
        anchored: anchored,
        topLeft: _popupResizeAnchorTopLeft!,
        screen: screen,
        inset: popupPadding,
      );
    }
    return anchored;
  }

  bool get dictionaryPopupShown => _hasVisiblePopup(_popup.entries);

  /// Test-only snapshot of the popup stack (BUG-092): lets widget tests assert
  /// the warm-slot seed/prune/reuse lifecycle without rendering the real
  /// [DictionaryPopupWebView], which cannot instantiate the platform WebView in
  /// the unit-test harness.
  @visibleForTesting
  List<
      ({
        bool isWarmSlot,
        bool visible,
        bool revealOnRender,
        // TODO-962：暴露 allLoaded + entryCount，让 widget 测试断言「弹窗结果被截断时
        // 不再硬编码 allLoaded:true、load-more 后词头数增加」。按名访问，不破坏既有解构。
        bool allLoaded,
        int entryCount,
        GlobalKey<DictionaryPopupWebViewState> webViewKey
      })> get debugPopupStack => _popup.entries
      .map((e) => (
            isWarmSlot: e.isWarmSlot,
            visible: e.visible,
            revealOnRender: e.revealOnRender,
            allLoaded: e.allLoaded,
            entryCount: e.result?.entries.length ?? 0,
            webViewKey: e.webViewKey,
          ))
      .toList();

  /// TODO-058 test hook: simulate the WebView at [index] firing `popupRendered`
  /// (the fake test WebView never fires real lifecycle callbacks). Reveals a
  /// pending cold layer exactly like the production [DictionaryPopupLayer.onRendered]
  /// path, so widget tests can assert "nested popup hidden until render".
  @visibleForTesting
  void debugFirePopupRendered(int index) {
    if (index < 0 || index >= _popup.entries.length) return;
    _onPopupLayerRendered(index, _popup.entries[index]);
  }

  /// TODO-058 fail-safe test hook: simulate the WebView at [index] firing the
  /// load-error callback (`onReceivedError` -> [DictionaryPopupLayer.onRenderError]).
  /// Reveals a pending cold layer exactly like the production error wiring, so
  /// widget tests can assert "load failure still shows the popup, not stuck hidden".
  @visibleForTesting
  void debugFirePopupRenderError(int index) {
    if (index < 0 || index >= _popup.entries.length) return;
    // Same reveal entry the onRenderError closure uses in _buildPopupLayer.
    _onPopupLayerRendered(index, _popup.entries[index]);
  }

  void onDictionaryDismiss() {
    clearDictionaryResult();
  }

  Widget buildDictionaryLoading() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isSearchingNotifier,
      builder: (context, value, child) {
        return Visibility(
          visible: value,
          child: SizedBox(
            height: double.infinity,
            width: double.infinity,
            child: HibikiCard(
              padding: EdgeInsets.zero,
              color: Colors.transparent,
              borderColor: Colors.transparent,
              borderRadius: BorderRadius.zero,
              child: Column(
                children: [
                  LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    color: theme.colorScheme.primary,
                    minHeight: 2.75,
                  ),
                  Expanded(child: Container())
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) async {
    return const MinePopupResult();
  }

  /// TODO-270 D：覆盖「最新制的那张卡」（reader 覆写做真实更新；基类无操作）。
  Future<MinePopupResult> onUpdateFromPopup(
    int noteId,
    Map<String, String> fields,
  ) async {
    return const MinePopupResult();
  }

  /// TODO-1007/1008：点 ✓（卡已存在）的编排入口（reader/有声书车道，与
  /// [DictionaryPageMixin.onMinedCardAction] 对称）。据当前词条 [fields] 的
  /// expression/reading 反查 Anki 全部命中卡，弹操作选择让用户选（覆写哪张 /
  /// 新增重复卡 / 查看·在 Anki 中打开），复用可被 reader 覆写的 [onMineFromPopup] /
  /// [onUpdateFromPopup] 执行。
  Future<MinePopupResult> onMinedCardActionFromPopup(
      Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final expression = fields['expression'] ?? '';
    final reading = fields['reading'] ?? '';
    final r = await runAnkiMinedCardAction(
      context: context,
      repo: repo,
      expression: expression,
      reading: reading,
      mineNew: () async {
        final res = await onMineFromPopup(fields);
        return (ankiConnect: res.ankiConnect, noteId: res.noteId);
      },
      overwrite: (noteId) async {
        final res = await onUpdateFromPopup(noteId, fields);
        return (ankiConnect: res.ankiConnect, noteId: res.noteId);
      },
    );
    return MinePopupResult(ankiConnect: r.ankiConnect, noteId: r.noteId);
  }

  /// TODO-1360：已制卡的词旁「在 Anki 中打开卡片」按钮的 reader/有声书车道入口（与
  /// [DictionaryPageMixin.onOpenInAnki] 对称）。据当前词条 expression/reading 反查命中
  /// 卡并直接跳转打开（单卡直开 / 多卡弹选择 / 无卡 toast），不制卡、不覆写。
  Future<void> onOpenInAnkiFromPopup(String expression, String reading) async {
    final repo = ref.read(ankiRepositoryProvider);
    await openMinedCardInAnki(
      context: context,
      repo: repo,
      expression: expression,
      reading: reading,
    );
  }

  /// 收藏/制卡计入统计时的来源标识。阅读器（EPUB）/有声书都归书籍统计
  /// （[kStatSourceBook]）；视频走 [DictionaryPageMixin] 自己覆写，不经本基类。
  @protected
  String get dictionarySourceType => kStatSourceBook;

  /// TODO-1204：本次查词归属的书身份（[bookKey] + [title]），供 per-book 查词计数。
  /// 阅读器（EPUB/有声书）覆写返回当前书（[title] 与阅读统计 tile 的 title 聚合键
  /// 对齐）；无书来源保持 null → 查词只进统计页「查词」汇总，不落 per-book tile。
  @protected
  ({String? bookKey, String? title})? get lookupBookIdentity => null;

  /// TODO-1204：[DictionaryPopupController.onLookupStarted] 注入点——每次查词
  /// （顶层 / 嵌套 / 重复查各一次）累加 [HibikiDatabase.addLookupCount]。best-effort，
  /// 失败吞掉并记日志（与 [addMiningCount] 记账同容错口径）。
  void _recordLookupCounter() {
    // best-effort：连同同步阶段（[AppModel.database] late 字段 getter 在 DB 未初始化
    // 时会抛 LateInitializationError）一起吞掉——查词计数是旁路埋点，任何异常都不得
    // 打断弹窗查词流程（否则 [DictionaryPopupController.beginTop] 会随查词一起崩）。
    try {
      final ({String? bookKey, String? title})? identity = lookupBookIdentity;
      unawaited(appModel.database
          .addLookupCount(
        bookKey: identity?.bookKey,
        title: identity?.title ?? '',
        sourceType: dictionarySourceType,
        dateKey: statTodayKey(),
      )
          .catchError((Object e, StackTrace st) {
        debugPrint('[hibiki-stats] addLookupCount failed: $e\n$st');
      }));
    } catch (e, st) {
      debugPrint('[hibiki-stats] addLookupCount failed (sync): $e\n$st');
    }
  }

  /// TODO-948②：弹窗右部「收藏」按钮回调（阅读器 EPUB 走本基类的 [_buildPopupLayer]，
  /// 不经 [DictionaryPageMixin]，曾因这里漏接线导致点击无反应）。切换收藏当前词条：
  /// 已收藏则取消（返回 false），否则按 [dictionarySourceType] 落 DB（返回 true）。
  /// 与 [DictionaryPageMixin.onFavoriteEntry] 行为一致，真写穿 FavoriteWords 表。
  Future<bool> onFavoriteFromPopup(Map<String, String> fields) async {
    final String expression = fields['expression'] ?? '';
    final String reading = fields['reading'] ?? '';
    if (expression.isEmpty) return false;
    final db = appModel.database;
    final bool already = await db.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: dictionarySourceType,
    );
    if (already) {
      await db.removeFavoriteWord(
        expression: expression,
        reading: reading,
        sourceType: dictionarySourceType,
      );
      // TODO-956 A：桌面 flutter_inappwebview_windows fork 的 callHandler 返回值
      // marshalling 与移动端不同，弹窗里 ☆→★ 变色依赖 JS 往返的返回值（popup.js
      // favoriteEntry），桌面可能收不到 → 星标不变色 → 用户判定「点了没用」（DB 其实
      // 已写）。DB 写成功后**与 callHandler 返回值解耦**直接弹 toast，保证两宿主都有
      // 确定反馈，不依赖也不改动返回值通道。
      HibikiToast.show(msg: t.word_favorite_removed);
      return false;
    }
    // TODO-1252：把当前书身份（阅读器 / 有声书覆写 lookupBookIdentity）随收藏落库，
    // 供统计页 per-book tile 聚合「收藏 N」；无书来源为 null / '' → 只进汇总。
    final ({String? bookKey, String? title})? favIdentity = lookupBookIdentity;
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: fields['glossary'] ?? '',
      sourceType: dictionarySourceType,
      dateKey: statTodayKey(),
      bookKey: favIdentity?.bookKey,
      title: favIdentity?.title ?? '',
    );
    HibikiToast.show(msg: t.word_favorite_added);
    return true;
  }

  /// TODO-948②：查询某词条当前是否已收藏（供弹窗按钮初始 ☆/★ 状态）。
  Future<bool> onFavoriteCheckFromPopup(
      String expression, String reading) async {
    if (expression.isEmpty) return false;
    return appModel.database.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: dictionarySourceType,
    );
  }

  /// Placeholder when there are no search results.
  Widget buildNoSearchResultsPlaceholderMessage() {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.search_off,
        message: t.no_search_results,
      ),
    );
  }

  DictionarySearchResult? get currentResult =>
      _lastVisiblePopup(_popup.entries)?.result;

  @protected
  void prunePopupStack(int keepCount) {
    if (keepCount > 0) {
      final pending = _visibleRenderPendingItem;
      if (pending != null) {
        final index = _popup.entries.indexOf(pending);
        if (index < 0 || index >= keepCount) {
          _clearVisibleRenderPending(item: pending);
        }
      }
      _popup.truncateTo(keepCount);
      return;
    }
    // keepCount <= 0: a fresh top-level lookup is starting. Preserve the
    // persistent warm slot (index 0) so its already-loaded WebView survives and
    // the upcoming lookup reuses it warm (BUG-092) — only drop nested children
    // and hide the slot. Low-memory mode keeps no warm slot, so it clears.
    if (_popup.entries.isEmpty) return;
    _popup.lowMemory = appModel.lowMemoryMode;
    if (_popup.entries.first.isWarmSlot && !appModel.lowMemoryMode) {
      _popup.entries.first.webViewKey.currentState?.clearSelection();
    }
    _clearVisibleRenderPending();
    _popup.pruneToWarmSlot();
  }

  bool _hasVisiblePopup(List<DictionaryPopupEntry> stack) {
    return stack.any((item) => item.visible);
  }

  int _lastVisiblePopupIndex(List<DictionaryPopupEntry> stack) {
    for (int i = stack.length - 1; i >= 0; i--) {
      if (stack[i].visible) return i;
    }
    return -1;
  }

  DictionaryPopupEntry? _lastVisiblePopup(List<DictionaryPopupEntry> stack) {
    final index = _lastVisiblePopupIndex(stack);
    if (index < 0) return null;
    return stack[index];
  }
}
