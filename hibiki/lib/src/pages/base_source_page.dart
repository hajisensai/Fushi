import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/utils.dart';

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
      _creatorActiveStreamSubscription = appModel.creatorActiveStream.listen(
        (creatorActive) {
          if (creatorActive) {
            onCreatorOpen();
          } else {
            onCreatorClose();
          }
        },
      );
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
    _popup.seedWarmSlot(seedResult: kPopupSearchingPlaceholderResult);
  }

  @override
  void dispose() {
    _creatorActiveStreamSubscription?.cancel();
    super.dispose();
  }

  /// Used for listening to when the Card Creator is opened and closed.
  StreamSubscription<bool>? _creatorActiveStreamSubscription;

  /// Allows customisation of dictionary background.
  double get dictionaryBackgroundOpacity => 0.95;

  /// Allows customisation of opacity of dictionary entries.
  double get dictionaryEntryOpacity => 1;

  final DictionaryPopupController _popup =
      DictionaryPopupController(lowMemory: false);

  final ValueNotifier<bool> _isSearchingNotifier = ValueNotifier<bool>(false);

  Rect? _pendingSelectionRect;

  int _searchGeneration = 0;

  bool get isDictionaryShown => _hasVisiblePopup(_popup.entries);

  @protected
  void onDismissBarrierHover(PointerHoverEvent event) {}

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
    final swTotal = Stopwatch()..start();

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

      final msAfterSearch = swTotal.elapsedMilliseconds;

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
      _popup.fillResult(item, result: dictionaryResult, allLoaded: true);

      // TODO-058：嵌套（第二个）查词复用不到热槽，beginTop 会 append 一条**新建
      // WebView** 的冷层；若就绪即 show，它的 popup.html/JS/CSS 还没冷加载完，一翻
      // 可见就露白屏一瞬。只有「能复用已预热热槽」或「无词条（走 Flutter 占位，不靠
      // WebView 渲染）」才立即 show；其余冷层挂起到其 WebView 真正渲染完成（onRendered
      // → revealRendered）才翻可见。deferDisplay（阅读器手动延迟）路径不变。
      final bool revealImmediately = reuse || dictionaryResult.entries.isEmpty;
      if (deferDisplay) {
        _deferredPopupItem = item;
        _deferredGeneration = gen;
      } else if (revealImmediately) {
        _popup.show(item);
      } else {
        _popup.markPendingReveal(item);
      }

      debugPrint(
          '[dict-perf] searchDictionaryResult: search=${msAfterSearch}ms pushPopup=${swTotal.elapsedMilliseconds}ms "$searchTerm"');

      final int highlightCount = dictionaryResult.entries.isNotEmpty
          ? dictionaryResult.entries.first.word.runes.length
          : 0;

      final bool arEnabled = ReaderHibikiSource.instance.autoReadOnLookup;
      debugPrint(
          '[hibiki-autoread] autoReadOnLookup=$arEnabled entries=${dictionaryResult.entries.length}');
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
          (!deferDisplay || _deferredPopupItem == null)) {
        _isSearchingNotifier.value = false;
        _pendingSelectionRect = null;
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
      // item 已在栈内（beginTop 时加入，隐藏）；show 翻为可见并通知重建。
      _popup.show(item);
    }
    if (_searchGeneration == gen) {
      _isSearchingNotifier.value = false;
      _pendingSelectionRect = null;
    }
  }

  /// Resolve audio exactly like Hoshi: enabled sources only, no TTS fallback.
  Future<void> _autoReadWord(String expression, String reading) async {
    try {
      final sources = appModel.enabledAudioSources;
      debugPrint(
          '[hibiki-autoread] "$expression" reading="$reading" sources=${sources.length}');
      final WordAudioResolver resolver = WordAudioResolver(
        queryLocalAudio: (expression, reading) async {
          try {
            return await TtsChannel.instance
                .queryLocalAudio(expression, reading)
                .timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            debugPrint(
                '[hibiki-autoread] queryLocalAudio timed out for "$expression"');
            return null;
          }
        },
        queryLocalAudioByDbIndex: (expression, reading, dbIndex) async {
          try {
            return await TtsChannel.instance
                .queryLocalAudio(expression, reading, dbIndex: dbIndex)
                .timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            debugPrint(
                '[hibiki-autoread] queryLocalAudio timed out for "$expression"');
            return null;
          }
        },
        extractLocalAudio: TtsChannel.instance.extractLocalAudio,
        queryRemoteAudio: (expression, reading) => appModel.lookupRemoteAudio(
          expression,
          reading,
        ),
      );
      final String? url = await resolver.resolveConfigured(
        expression: expression,
        reading: reading,
        sources: appModel.audioSourceConfigs,
      );
      debugPrint('[hibiki-autoread] resolved url=$url');
      if (url == null || url.isEmpty) return;

      // Plays remote URLs and local file paths uniformly, including Windows
      // drive-letter paths (BUG-046).
      final bool ok = await TtsChannel.instance.playAudioRef(
        url,
        volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
      );
      debugPrint('[hibiki-autoread] play ok=$ok');
    } catch (e, st) {
      debugPrint('[hibiki-autoread] error: $e\n$st');
    }
  }

  void clearDictionaryResult() => _dismissPopupAt(0);

  // 弹窗盒子尺寸随「界面大小」一起放大：阅读器/词典页整树被 HibikiAppUiScaleNeutralizer
  // 中和回原生密度（净缩放=1），弹窗盒子若不乘 appUiScale，界面 200% 时它仍是原生小尺寸
  // （内容放大走 WebView 内 CSS zoom，见 DictionaryPopupWebView）。
  double get popupMaxWidth => appModel.popupMaxWidth * appModel.appUiScale;
  double get popupMaxHeight => appModel.popupMaxHeight * appModel.appUiScale;
  double get popupPadding => 6;
  double get popupBottomReserve => 0;
  double get popupTopReserve => 0;

  /// 竖排表面（reader vertical-rl）查词时让弹窗放当前列左/右侧而非上/下。
  /// 默认 false（视频/有声书横排字幕、首页等非竖排表面不变）。
  bool get popupVerticalWriting => false;
  late final Listenable _popupListenable =
      Listenable.merge([_popup, _isSearchingNotifier]);

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
                          onTap: clearDictionaryResult,
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
    final isDark = (appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark;

    // BUG-135: 隐藏热槽（warm slot，visible:false）的 Android 原生 WebView 即使被
    // Visibility 的 Opacity(0)+IgnorePointer 包住也会截获触摸，盖住正文/控件点击。
    // 停到屏幕右外侧（保持真实尺寸继续预热，Stack 用 Clip.none 不裁）即可放掉触摸。
    final bool parked = !item.visible;
    final double layerLeft = parked ? screen.width + 8 : pos.left;
    final double layerTop = parked ? 0 : pos.top;

    return Positioned(
      left: layerLeft,
      top: layerTop,
      width: pos.width,
      height: pos.height,
      child: Visibility(
        visible: item.visible,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: DictionaryPopupLayer(
          result: item.result,
          webViewKey: item.webViewKey,
          keepWebViewWarm: item.isWarmSlot,
          isDark: isDark,
          overrideFillColor: appModel.overrideDictionaryColor,
          onDismiss: () => _dismissPopupAt(index),
          onTapOutside: clearDictionaryResult,
          onRendered: () => _onPopupLayerRendered(index, item),
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
            await searchDictionaryResult(
              searchTerm: query,
              selectionRect: childRect,
            );
          },
          onMineEntry: onMineFromPopup,
          onDuplicateCheck: (expression, reading) async {
            final repo = ref.read(ankiRepositoryProvider);
            return repo.isDuplicate(expression, reading);
          },
        ),
      ),
    );
  }

  /// TODO-058：某弹窗层 WebView 渲染完成（`popupRendered`）。先把挂起的冷层翻为
  /// 可见（[markPendingReveal] 标记的层等到此刻才显示，杜绝白屏一瞬），再交给
  /// [onDictionaryPopupRendered]（阅读器据此把字符光标交给刚显示的顶层弹窗）。
  /// 顺序要紧：先 reveal 再回调，使回调里读到的 [topVisiblePopupIndex] 已是新层。
  void _onPopupLayerRendered(int index, DictionaryPopupEntry item) {
    if (!mounted) return;
    _popup.revealRendered(item);
    onDictionaryPopupRendered(index);
  }

  void _dismissPopupAt(int index) {
    _searchGeneration++;
    _pendingSelectionRect = null;
    _isSearchingNotifier.value = false;
    _deferredPopupItem = null;
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
    return calcPopupPosition(
      selectionRect: sel,
      screen: screen,
      padding: popupPadding,
      maxWidth: popupMaxWidth,
      maxHeight: popupMaxHeight,
      bottomReserve: popupBottomReserve,
      topReserve: popupTopReserve,
      verticalWriting: verticalWriting,
    );
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
        GlobalKey<DictionaryPopupWebViewState> webViewKey
      })> get debugPopupStack => _popup.entries
      .map((e) => (
            isWarmSlot: e.isWarmSlot,
            visible: e.visible,
            revealOnRender: e.revealOnRender,
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

  Future<bool> onMineFromPopup(Map<String, String> fields) async {
    return false;
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

  /// Action upon selecting the Search option.
  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    await appModel.openPopupDictionaryLookup(searchTerm: searchTerm);
  }

  /// Action upon selecting the Stash option.
  @override
  void onStash(String searchTerm) {
    appModel.addToStash(terms: [searchTerm]);
  }

  /// Performs an action before opening the Card Creator.
  void onCreatorOpen() {}

  /// Performs an action after closing the Card Creator.
  void onCreatorClose() {}
}
