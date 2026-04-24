import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
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

  /// The result from the last dictionary search performed with
  /// [searchDictionaryResult].
  final ValueNotifier<DictionarySearchResult?> _dictionaryResultNotifier =
      ValueNotifier<DictionarySearchResult?>(null);

  String? _lastSearchTerm;

  /// Notifies the progress bar whether or not to refresh.
  final ValueNotifier<bool> _isSearchingNotifier = ValueNotifier<bool>(false);

  /// Whether or not there is a present dictionary result.
  bool get isDictionaryShown => _dictionaryResultNotifier.value != null;

  /// The selection rect that triggered the popup, used for positioning.
  /// null means popup is hidden.
  final _selectionRectNotifier = ValueNotifier<Rect?>(null);

  /// Key for the popup WebView to keep it persistent across rebuilds.
  final GlobalKey<DictionaryPopupWebViewState> _popupWebViewKey =
      GlobalKey<DictionaryPopupWebViewState>();

  /// Standard warning dialog for leaving a source page. All sources should
  /// use this and wrap their [build] function with a [WillPopScope].
  Future<bool> onWillPop() async {
    Widget alertDialog = AlertDialog(
      shape: const RoundedRectangleBorder(),
      title: Text(t.exit_media_title),
      content: Text(t.exit_media_description),
      actions: <Widget>[
        TextButton(
            child: Text(
              t.dialog_exit,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            onPressed: () async {
              await onSourcePagePop();

              if (mounted) {
                Navigator.pop(context, true);
              }
              await appModel.closeMedia(
                ref: ref,
                mediaSource: appModel.currentMediaSource!,
                item: widget.item,
              );
            }),
        TextButton(
          child: Text(
            t.dialog_cancel,
          ),
          onPressed: () => Navigator.pop(context, false),
        ),
      ],
    );

    return await showDialog(
          context: context,
          builder: (context) => alertDialog,
        ) ??
        false;
  }

  bool _showMore = false;

  /// Action to perform within the source page upon closing the media.
  Future<void> onSourcePagePop() async {}

  /// Perform a search with a given query and update the dictionary search
  /// result. The [position] parameter determines where the pop-up will
  /// be shown on the screen.
  Future<void> searchDictionaryResult({
    required String searchTerm,
    required Rect selectionRect,
    int? overrideMaximumTerms,
  }) async {
    if (_lastSearchTerm == searchTerm && overrideMaximumTerms == null) {
      return;
    } else {
      _lastSearchTerm = searchTerm;
    }

    bool notShowMore = overrideMaximumTerms == null;

    overrideMaximumTerms ??= appModel.maximumTerms;

    late DictionarySearchResult dictionaryResult;
    _selectionRectNotifier.value = selectionRect;

    try {
      _isSearchingNotifier.value = true;

      dictionaryResult = await appModel.searchDictionary(
        searchTerm: searchTerm,
        searchWithWildcards: false,
        overrideMaximumTerms: overrideMaximumTerms,
      );
      if (notShowMore &&
          resultScrollController.hasClients &&
          resultScrollController.position.hasContentDimensions) {
        resultScrollController
            .jumpTo(resultScrollController.initialScrollOffset);
      }

      _lastSearchTerm = searchTerm;

      appModel.addToDictionaryHistory(result: dictionaryResult);
      _showMore = dictionaryResult.entries.length < overrideMaximumTerms;
      _dictionaryResultNotifier.value = dictionaryResult;

      // Auto-read the looked-up word via TTS if enabled.
      if (ReaderTtuSource.instance.autoReadOnLookup &&
          dictionaryResult.entries.isNotEmpty) {
        final entry = dictionaryResult.entries.first;
        final word = entry.reading.isNotEmpty ? entry.reading : entry.word;
        if (word.isNotEmpty) {
          TtsChannel.instance.speak(word);
        }
      }
    } finally {
      _isSearchingNotifier.value = false;
    }
  }

  /// Push lookup results to the popup WebView for JS rendering.
  /// Now handled by DictionaryPopupWebView via didUpdateWidget.

  /// Hide the dictionary and dispose of the current result.
  void clearDictionaryResult() async {
    _dictionaryResultNotifier.value = null;
    _selectionRectNotifier.value = null;
    _lastSearchTerm = null;
    _showMore = false;
    appModel.currentMediaSource?.clearCurrentSentence();
    appModel.currentMediaSource?.clearExtraData();
  }

  double get popupMaxWidth => 400;
  double get popupMaxHeight => 360;
  double get popupPadding => 6;

  /// Build a dictionary showing the result with positioning.
  Widget buildDictionary() {
    return Theme(
      data: appModel.overrideDictionaryTheme ?? theme,
      child: ValueListenableBuilder<Rect?>(
        valueListenable: _selectionRectNotifier,
        builder: (context, selectionRect, _) {
          if (selectionRect == null &&
              !_isSearchingNotifier.value &&
              _dictionaryResultNotifier.value == null) {
            return const SizedBox.shrink();
          }
          if (selectionRect == null) {
            return const SizedBox.shrink();
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final screen = Size(constraints.maxWidth, constraints.maxHeight);
              final pos = _calculatePopupPosition(selectionRect, screen);

              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: clearDictionaryResult,
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.15),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: pos.left,
                    top: pos.top,
                    width: pos.width,
                    height: pos.height,
                    child: buildDictionaryResult(),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Rect _calculatePopupPosition(Rect sel, Size screen) {
    final double width =
        (screen.width - popupPadding * 2).clamp(0, popupMaxWidth);
    final double height =
        (screen.height * 0.5).clamp(0, popupMaxHeight);

    final double spaceBelow = screen.height - sel.bottom - popupPadding;
    final double spaceAbove = sel.top - popupPadding;
    final bool showBelow = spaceBelow >= height || spaceBelow >= spaceAbove;

    double top;
    if (showBelow) {
      top = sel.bottom + 4;
    } else {
      top = sel.top - 4 - height;
    }
    top = top.clamp(popupPadding, screen.height - height - popupPadding);

    double left = sel.left;
    left = left.clamp(popupPadding, screen.width - width - popupPadding);

    return Rect.fromLTWH(left, top, width, height);
  }

  /// Used to check if the pop-up is open.
  bool get dictionaryPopupShown => _selectionRectNotifier.value != null;

  /// The dictionary result unpositioned. See [buildDictionary] for the
  /// positioned version.
  Widget buildDictionaryResult() {
    final isDark =
        (appModel.overrideDictionaryTheme ?? theme).brightness ==
            Brightness.dark;
    final fillColor = isDark
        ? Colors.black.withValues(alpha: 0.75)
        : Colors.white.withValues(alpha: 0.82);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    return _SwipeDismissWrapper(
      onDismiss: clearDictionaryResult,
      sensitivity: ReaderTtuSource.instance.dismissSwipeSensitivity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Stack(
              children: [
                buildSearchResult(),
                buildDictionaryLoading(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Executed on dictionary dismiss.
  void onDictionaryDismiss() {
    clearDictionaryResult();
  }

  /// In progress indicator for dictionary searching.
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

  /// Scroll controller for the search result.
  final ScrollController resultScrollController = ScrollController();

  /// Displays the dictionary entries via a persistent popup WebView.
  Widget buildSearchResult() {
    return ValueListenableBuilder(
      valueListenable: _dictionaryResultNotifier,
      builder: (_, __, child) {
        if (_dictionaryResultNotifier.value == null) {
          return SizedBox(
            height: double.infinity,
            width: double.infinity,
            child: Card(
              color: appModel.overrideDictionaryColor
                      ?.withValues(alpha: dictionaryEntryOpacity) ??
                  (Theme.of(context).brightness == Brightness.dark
                      ? Color.fromRGBO(16, 16, 16, dictionaryEntryOpacity)
                      : Color.fromRGBO(249, 249, 249, dictionaryEntryOpacity)),
              elevation: 0,
              shape: const RoundedRectangleBorder(),
              child: Column(
                children: [Container()],
              ),
            ),
          );
        }

        if (_dictionaryResultNotifier.value!.entries.isEmpty) {
          return buildNoSearchResultsPlaceholderMessage();
        }

        return child!;
      },
      child: DictionaryPopupWebView(
        key: _popupWebViewKey,
        result: _dictionaryResultNotifier.value ?? DictionarySearchResult(
          entries: [],
          searchTerm: '',
        ),
        onTextSelected: (text) {
          searchDictionaryResult(
            searchTerm: text,
            selectionRect: _selectionRectNotifier.value ??
                Rect.fromLTWH(0, 0, 1, 1),
          );
        },
        onMineEntry: onMineFromPopup,
      ),
    );
  }

  /// Called when the user taps mine in the popup WebView.
  void onMineFromPopup(Map<String, String> fields) {
    // Subclasses can override to handle Anki export
  }

  /// Show more widget.
  Widget? get footerWidget {
    if (_showMore) {
      return null;
    }

    return SliverToBoxAdapter(
      child: Padding(
        padding: Spacing.of(context).insets.all.small,
        child: Semantics(
          label: t.show_more,
          button: true,
          child: InkWell(
            onTap: _isSearchingNotifier.value
                ? null
                : () async {
                    searchDictionaryResult(
                      searchTerm: _lastSearchTerm!,
                      selectionRect: _selectionRectNotifier.value ??
                          Rect.fromLTWH(0, 0, 1, 1),
                      overrideMaximumTerms:
                          _dictionaryResultNotifier.value!.entries.length +
                              appModel.maximumTerms,
                    );
                  },
            child: Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.05),
              width: double.maxFinite,
              child: Padding(
                padding: Spacing.of(context).insets.all.normal,
                child: Text(
                  t.show_more,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: (textTheme.labelMedium?.fontSize)! * 0.9,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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

  /// Get the result returned from the last search.
  DictionarySearchResult? get currentResult => _dictionaryResultNotifier.value;

  /// Action upon selecting the Search option.
  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    if (appModel.isMediaOpen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await Future.delayed(const Duration(milliseconds: 5), () {});
    }
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    if (appModel.isMediaOpen) {
      await Future.delayed(const Duration(milliseconds: 5), () {});
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
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

class _SwipeDismissWrapper extends StatefulWidget {
  const _SwipeDismissWrapper({
    required this.child,
    required this.onDismiss,
    this.sensitivity = 0.3,
  });
  final Widget child;
  final VoidCallback onDismiss;
  /// 0.1 (hard to dismiss) ~ 1.0 (easy). Maps to threshold & decision distance.
  final double sensitivity;

  @override
  State<_SwipeDismissWrapper> createState() => _SwipeDismissWrapperState();
}

class _SwipeDismissWrapperState extends State<_SwipeDismissWrapper> {
  double _dragX = 0;
  double _dragY = 0;
  bool _decided = false;
  bool _isHorizontal = false;

  /// Threshold scales inversely with sensitivity: low sensitivity = high threshold.
  double get _threshold => 30 + (1.0 - widget.sensitivity) * 160;
  /// Decision distance also scales inversely.
  double get _decisionDistance => 10 + (1.0 - widget.sensitivity) * 20;

  void _reset() {
    setState(() {
      _dragX = 0;
      _dragY = 0;
      _decided = false;
      _isHorizontal = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: (e) {
        _dragX += e.delta.dx;
        _dragY += e.delta.dy;
        if (!_decided &&
            (_dragX.abs() > _decisionDistance ||
                _dragY.abs() > _decisionDistance)) {
          _decided = true;
          _isHorizontal = _dragX.abs() > _dragY.abs() * 2.5;
        }
        if (_decided && _isHorizontal) {
          setState(() {});
        }
      },
      onPointerUp: (_) {
        if (_decided && _isHorizontal && _dragX.abs() > _threshold) {
          widget.onDismiss();
        }
        _reset();
      },
      onPointerCancel: (_) => _reset(),
      child: Transform.translate(
        offset: Offset(_decided && _isHorizontal ? _dragX : 0, 0),
        child: Opacity(
          opacity: _decided && _isHorizontal
              ? (1 - (_dragX.abs() / 300)).clamp(0.3, 1.0)
              : 1.0,
          child: widget.child,
        ),
      ),
    );
  }
}
