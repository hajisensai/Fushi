import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
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
    });
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

  final ValueNotifier<List<_PopupStackItem>> _popupStack =
      ValueNotifier<List<_PopupStackItem>>([]);

  final ValueNotifier<bool> _isSearchingNotifier = ValueNotifier<bool>(false);

  Rect? _pendingSelectionRect;

  int _searchGeneration = 0;

  bool get isDictionaryShown => _hasVisiblePopup(_popupStack.value);

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

  _PopupStackItem? _deferredPopupItem;
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

      final item = _buildSearchPopupItem(
        result: dictionaryResult,
        selectionRect: selectionRect,
        searchTerm: searchTerm,
        visible: !deferDisplay,
      );

      if (deferDisplay) {
        _deferredPopupItem = item;
        _deferredGeneration = gen;
      } else {
        _showPopupItem(item);
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
      item.visible = true;
      _showPopupItem(item);
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
      final bool ok = await TtsChannel.instance.playAudioRef(url);
      debugPrint('[hibiki-autoread] play ok=$ok');
    } catch (e, st) {
      debugPrint('[hibiki-autoread] error: $e\n$st');
    }
  }

  void clearDictionaryResult() => _dismissPopupAt(0);

  double get popupMaxWidth => appModel.popupMaxWidth;
  double get popupMaxHeight => 360;
  double get popupPadding => 6;
  double get popupBottomReserve => 0;
  double get popupTopReserve => 0;
  late final Listenable _popupListenable =
      Listenable.merge([_popupStack, _isSearchingNotifier]);

  Widget buildDictionary() {
    return Theme(
      data: appModel.overrideDictionaryTheme ?? theme,
      child: AnimatedBuilder(
        animation: _popupListenable,
        builder: (context, _) {
          final stack = _popupStack.value;
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
    final pos = _calculatePopupPosition(_pendingSelectionRect!, screen);
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
    List<_PopupStackItem> stack,
    int index,
    Size screen, {
    required bool isTop,
  }) {
    final item = stack[index];
    final pos = _calculatePopupPosition(item.selectionRect, screen);
    final isDark = (appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark;

    return Positioned(
      left: pos.left,
      top: pos.top,
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
          isDark: isDark,
          overrideFillColor: appModel.overrideDictionaryColor,
          onDismiss: () => _dismissPopupAt(index),
          onTapOutside: clearDictionaryResult,
          onRendered: () => onDictionaryPopupRendered(index),
          headerWidget: index == 0 ? buildPopupAudioControls() : null,
          overlayWidget: isTop ? buildDictionaryLoading() : null,
          onTextSelected: (text, localRect) async {
            final parentPos =
                _calculatePopupPosition(item.selectionRect, screen);
            final childRect = localRect == Rect.zero
                ? item.selectionRect
                : localRect.shift(Offset(parentPos.left, parentPos.top));
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
            final parentPos =
                _calculatePopupPosition(item.selectionRect, screen);
            final childRect = localRect == Rect.zero
                ? item.selectionRect
                : localRect.shift(Offset(parentPos.left, parentPos.top));
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

  void _dismissPopupAt(int index) {
    _searchGeneration++;
    _pendingSelectionRect = null;
    _isSearchingNotifier.value = false;
    _deferredPopupItem = null;
    if (index > 0) {
      final parent = _popupStack.value[index - 1];
      parent.webViewKey.currentState?.clearSelection();
    }
    if (index == 0) {
      if (_popupStack.value.isNotEmpty && !appModel.lowMemoryMode) {
        final top = _popupStack.value.first;
        top
          ..visible = false
          ..selectionRect = Rect.zero;
        top.webViewKey.currentState?.clearSelection();
        _popupStack.value = [top];
      } else {
        _popupStack.value = [];
      }
      appModel.currentMediaSource?.clearCurrentSentence();
      appModel.currentMediaSource?.clearExtraData();
      onAllPopupsDismissed();
    } else {
      _popupStack.value = _popupStack.value.sublist(0, index);
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
      _lastVisiblePopup(_popupStack.value)?.webViewKey.currentState;

  /// Index of the top-most visible popup in the stack, or -1.
  @protected
  int get topVisiblePopupIndex => _lastVisiblePopupIndex(_popupStack.value);

  /// Dismiss only the top-most visible popup (one layer), leaving any parent
  /// popup in place — used by the cursor's B/Esc "back one layer".
  @protected
  void dismissTopPopup() {
    final int index = _lastVisiblePopupIndex(_popupStack.value);
    if (index >= 0) _dismissPopupAt(index);
  }

  Rect _calculatePopupPosition(Rect sel, Size screen) {
    return calcPopupPosition(
      selectionRect: sel,
      screen: screen,
      padding: popupPadding,
      maxWidth: popupMaxWidth,
      maxHeight: popupMaxHeight,
      bottomReserve: popupBottomReserve,
      topReserve: popupTopReserve,
    );
  }

  bool get dictionaryPopupShown => _hasVisiblePopup(_popupStack.value);

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
      _lastVisiblePopup(_popupStack.value)?.result;

  _PopupStackItem _buildSearchPopupItem({
    required DictionarySearchResult result,
    required Rect selectionRect,
    required String searchTerm,
    required bool visible,
  }) {
    final reusable = _reusableHiddenTopPopup();
    if (reusable == null) {
      return _PopupStackItem(
        result: result,
        selectionRect: selectionRect,
        searchTerm: searchTerm,
        visible: visible,
      );
    }
    reusable
      ..result = result
      ..selectionRect = selectionRect
      ..searchTerm = searchTerm
      ..visible = visible;
    return reusable;
  }

  @protected
  void prunePopupStack(int keepCount) {
    if (_popupStack.value.length > keepCount) {
      _popupStack.value = keepCount > 0
          ? _popupStack.value.sublist(0, keepCount)
          : <_PopupStackItem>[];
    }
  }

  void _showPopupItem(_PopupStackItem item) {
    final stack = _popupStack.value;
    if (stack.contains(item)) {
      _popupStack.value = List<_PopupStackItem>.of(stack);
    } else {
      _popupStack.value = [...stack, item];
    }
  }

  _PopupStackItem? _reusableHiddenTopPopup() {
    final stack = _popupStack.value;
    if (appModel.lowMemoryMode || stack.length != 1 || stack.first.visible) {
      return null;
    }
    return stack.first;
  }

  bool _hasVisiblePopup(List<_PopupStackItem> stack) {
    return stack.any((item) => item.visible);
  }

  int _lastVisiblePopupIndex(List<_PopupStackItem> stack) {
    for (int i = stack.length - 1; i >= 0; i--) {
      if (stack[i].visible) return i;
    }
    return -1;
  }

  _PopupStackItem? _lastVisiblePopup(List<_PopupStackItem> stack) {
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

class _PopupStackItem {
  _PopupStackItem({
    required this.result,
    required this.selectionRect,
    required this.searchTerm,
    this.visible = true,
  });

  DictionarySearchResult result;
  Rect selectionRect;
  String searchTerm;
  bool visible;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}
