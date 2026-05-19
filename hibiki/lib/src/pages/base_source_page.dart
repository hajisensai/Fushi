import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
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
class BaseSourcePageState<T extends BaseSourcePage> extends BasePageState<T> {
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

  bool get isDictionaryShown => _popupStack.value.isNotEmpty;

  Widget? buildPopupAudioControls() => null;

  /// Handles leaving a source page. All sources should
  /// use this and wrap their [build] function with a [WillPopScope].
  Future<bool> onWillPop() async {
    final mediaSource = appModel.currentMediaSource;
    await onSourcePagePop();

    if (mediaSource != null) {
      await appModel.closeMedia(
        ref: ref,
        mediaSource: mediaSource,
        item: widget.item,
      );
    }
    return true;
  }

  /// Action to perform within the source page upon closing the media.
  Future<void> onSourcePagePop() async {}

  Future<int> searchDictionaryResult({
    required String searchTerm,
    required Rect selectionRect,
    int? overrideMaximumTerms,
  }) async {
    overrideMaximumTerms ??= appModel.maximumTerms;

    final gen = ++_searchGeneration;
    _pendingSelectionRect = selectionRect;
    final swTotal = Stopwatch()..start();

    try {
      _isSearchingNotifier.value = true;

      final dictionaryResult = await appModel.searchDictionary(
        searchTerm: searchTerm,
        searchWithWildcards: false,
        overrideMaximumTerms: overrideMaximumTerms,
      );

      if (_searchGeneration != gen) return 0;

      final msAfterSearch = swTotal.elapsedMilliseconds;

      appModel.addToDictionaryHistory(result: dictionaryResult);

      final item = _PopupStackItem(
        result: dictionaryResult,
        selectionRect: selectionRect,
        searchTerm: searchTerm,
      );
      _popupStack.value = [..._popupStack.value, item];

      debugPrint(
          '[dict-perf] searchDictionaryResult: search=${msAfterSearch}ms pushPopup=${swTotal.elapsedMilliseconds}ms "$searchTerm"');

      final int highlightCount = dictionaryResult.entries.isNotEmpty
          ? dictionaryResult.entries.first.word.runes.length
          : 0;

      final bool arEnabled = ReaderHoshiSource.instance.autoReadOnLookup;
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
      if (_searchGeneration == gen) {
        _isSearchingNotifier.value = false;
        _pendingSelectionRect = null;
      }
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
        extractLocalAudio: TtsChannel.instance.extractLocalAudio,
      );
      final String? url = await resolver.resolve(
        expression: expression,
        reading: reading,
        sources: sources,
      );
      debugPrint('[hibiki-autoread] resolved url=$url');
      if (url == null || url.isEmpty) return;

      if (url.startsWith('file://')) {
        final filePath = Uri.parse(url).toFilePath();
        final ok = await TtsChannel.instance.playFile(filePath);
        debugPrint('[hibiki-autoread] playFile ok=$ok');
      } else if (url.startsWith('/')) {
        final ok = await TtsChannel.instance.playFile(url);
        debugPrint('[hibiki-autoread] playFile ok=$ok');
      } else if (url.startsWith('http')) {
        final ok = await TtsChannel.instance.playUrl(url);
        debugPrint('[hibiki-autoread] playUrl ok=$ok');
      }
    } catch (e, st) {
      debugPrint('[hibiki-autoread] error: $e\n$st');
    }
  }

  void clearDictionaryResult() => _dismissPopupAt(0);

  double get popupMaxWidth => appModel.popupMaxWidth;
  double get popupMaxHeight => 360;
  double get popupPadding => 6;
  double get popupBottomReserve => 0;
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

          final showLoadingPlaceholder =
              searching && stack.isEmpty && _pendingSelectionRect != null;

          return LayoutBuilder(
            builder: (context, constraints) {
              final screen = Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: clearDictionaryResult,
                      child: Container(
                        color: Colors.transparent,
                      ),
                    ),
                  ),
                  if (showLoadingPlaceholder) _buildLoadingPlaceholder(screen),
                  for (int i = 0; i < stack.length; i++)
                    _buildPopupLayer(stack, i, screen),
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
    final isDark = (appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark;
    final fillColor = appModel.overrideDictionaryColor ??
        (isDark ? Colors.black : Colors.white);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.18);

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          children: [
            const LinearProgressIndicator(
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
              minHeight: 2.75,
            ),
            Expanded(child: Container()),
          ],
        ),
      ),
    );
  }

  Widget _buildPopupLayer(List<_PopupStackItem> stack, int index, Size screen) {
    final item = stack[index];
    final pos = _calculatePopupPosition(item.selectionRect, screen);
    final isDark = (appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark;
    final isTop = index == stack.length - 1;

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: DictionaryPopupLayer(
        result: item.result,
        webViewKey: item.webViewKey,
        isDark: isDark,
        overrideFillColor: appModel.overrideDictionaryColor,
        onDismiss: () => _dismissPopupAt(index),
        onTapOutside: clearDictionaryResult,
        headerWidget: index == 0 ? buildPopupAudioControls() : null,
        overlayWidget: isTop ? buildDictionaryLoading() : null,
        onTextSelected: (text, localRect) async {
          final parentPos = _calculatePopupPosition(item.selectionRect, screen);
          final childRect = localRect == Rect.zero
              ? item.selectionRect
              : localRect.shift(Offset(parentPos.left, parentPos.top));
          _popupStack.value = _popupStack.value.sublist(0, index + 1);
          final count = await searchDictionaryResult(
            searchTerm: text,
            selectionRect: childRect,
          );
          if (count > 0) {
            item.webViewKey.currentState?.highlightSelection(count);
          }
        },
        onLinkClick: (query, localRect) async {
          final parentPos = _calculatePopupPosition(item.selectionRect, screen);
          final childRect = localRect == Rect.zero
              ? item.selectionRect
              : localRect.shift(Offset(parentPos.left, parentPos.top));
          _popupStack.value = _popupStack.value.sublist(0, index + 1);
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
    );
  }

  void _dismissPopupAt(int index) {
    _searchGeneration++;
    _pendingSelectionRect = null;
    _isSearchingNotifier.value = false;
    if (index > 0) {
      final parent = _popupStack.value[index - 1];
      parent.webViewKey.currentState?.clearSelection();
    }
    if (index == 0) {
      _popupStack.value = [];
      appModel.currentMediaSource?.clearCurrentSentence();
      appModel.currentMediaSource?.clearExtraData();
      onAllPopupsDismissed();
    } else {
      _popupStack.value = _popupStack.value.sublist(0, index);
    }
  }

  /// Called when all dictionary popups are dismissed (stack becomes empty).
  /// Override in subclasses to hook post-dismiss logic.
  void onAllPopupsDismissed() {}

  void repositionTopPopup(Rect expandedSelectionRect) {
    final stack = _popupStack.value;
    if (stack.isEmpty) return;
    stack.last.selectionRect = expandedSelectionRect;
    _popupStack.value = List.of(stack);
  }

  Rect _calculatePopupPosition(Rect sel, Size screen) {
    return calcPopupPosition(
      selectionRect: sel,
      screen: screen,
      padding: popupPadding,
      maxWidth: popupMaxWidth,
      maxHeight: popupMaxHeight,
      bottomReserve: popupBottomReserve,
    );
  }

  bool get dictionaryPopupShown => _popupStack.value.isNotEmpty;

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
            child: Card(
              color: Colors.transparent,
              elevation: 0,
              shape: const RoundedRectangleBorder(),
              child: Column(
                children: [
                  const LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
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
      child: JidoujishoPlaceholderMessage(
        icon: Icons.search_off,
        message: t.no_search_results,
      ),
    );
  }

  DictionarySearchResult? get currentResult =>
      _popupStack.value.isNotEmpty ? _popupStack.value.last.result : null;

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
  });

  final DictionarySearchResult result;
  Rect selectionRect;
  final String searchTerm;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}
