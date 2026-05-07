import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/types/dictionary_media_type.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/utils.dart';

/// The page shown after performing a recursive dictionary lookup.
class RecursiveDictionaryPage extends BasePage {
  /// Create an instance of this page.
  const RecursiveDictionaryPage({
    required this.searchTerm,
    required this.killOnPop,
    this.onUpdateQuery,
    super.key,
  });

  /// The initial search term that this page searches on initialisation.
  final String searchTerm;

  /// If true, popping will exit the application.
  final bool killOnPop;

  /// Used to track changes to the query.
  final Function(String)? onUpdateQuery;

  @override
  BasePageState<RecursiveDictionaryPage> createState() =>
      _RecursiveDictionaryPageState();
}

class _RecursiveDictionaryPageState
    extends BasePageState<RecursiveDictionaryPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  DictionarySearchResult? _result;
  final List<_NestedPopupEntry> _popupStack = [];

  bool _isSearching = false;

  @override
  void initState() {
    super.initState();

    _controller.text = widget.searchTerm;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      appModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: widget.searchTerm,
      );

      appModelNoUpdate.dictionarySearchAgainNotifier.addListener(searchAgain);
      search(widget.searchTerm);
    });
  }

  @override
  void dispose() {
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(searchAgain);
    _searchFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!appModel.isDatabaseOpen) {
      return const SizedBox.shrink();
    }

    Color? backgroundColor = theme.colorScheme.surface;
    if (appModel.overrideDictionaryColor != null) {
      if ((appModel.overrideDictionaryTheme ?? theme).brightness ==
          Brightness.dark) {
        backgroundColor =
            JidoujishoColor.lighten(appModel.overrideDictionaryColor!, 0.025);
      } else {
        backgroundColor =
            JidoujishoColor.darken(appModel.overrideDictionaryColor!, 0.025);
      }
    }

    return Theme(
      data: appModel.overrideDictionaryTheme ?? theme,
      child: PopScope(
        canPop: !widget.killOnPop && _popupStack.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            return;
          }
          if (_popupStack.isNotEmpty) {
            popNestedPopupAt(_popupStack.length - 1);
          } else if (widget.killOnPop) {
            appModel.moveToBack();
          }
        },
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: backgroundColor,
          body: SafeArea(
            child: Padding(
              padding: Spacing.of(context).insets.onlyTop.semiSmall,
              child: buildDictionaryResultView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildDictionaryResultView() {
    return Column(
      children: [
        buildQueryHeader(),
        Expanded(
          child: buildFloatingSearchBody(
            context,
            const AlwaysStoppedAnimation<double>(1),
          ),
        ),
      ],
    );
  }

  Widget buildQueryHeader() {
    final ColorScheme colors = theme.colorScheme;
    final bool dark = (appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark;
    final Color searchFill = dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.82);
    final Color borderColor = dark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.12);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(
          children: [
            JidoujishoIconButton(
              tooltip: t.back,
              icon: Icons.arrow_back,
              onTap: () async {
                if (widget.killOnPop) {
                  appModel.moveToBack();
                } else {
                  Navigator.pop(context);
                }
              },
            ),
            Expanded(
              child: SizedBox(
                height: 42,
                child: TextField(
                  controller: _controller,
                  focusNode: _searchFocusNode,
                  textInputAction: TextInputAction.search,
                  cursorColor: colors.primary,
                  style: textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: t.search_ellipsis,
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    isDense: true,
                    filled: true,
                    fillColor: searchFill,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: colors.primary),
                    ),
                  ),
                  onChanged: onQueryChanged,
                  onSubmitted: searchInCurrentPage,
                ),
              ),
            ),
            buildInlineSegmentButton(),
            JidoujishoIconButton(
              tooltip: t.search,
              icon: Icons.search,
              onTap: () {
                searchInCurrentPage(_controller.text);
                _searchFocusNode.unfocus();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget buildInlineSegmentButton() {
    return JidoujishoIconButton(
      size: Theme.of(context).textTheme.titleLarge?.fontSize,
      tooltip: t.text_segmentation,
      icon: Icons.account_tree,
      onTap: openTextSegmentationForQuery,
    );
  }

  void searchInCurrentPage(String query) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return;
    }

    _controller.text = trimmed;
    _controller.selection = TextSelection.collapsed(offset: trimmed.length);
    search(trimmed);
  }

  void updateCurrentQueryFromLookup(String query) {
    searchInCurrentPage(query);
    widget.onUpdateQuery?.call(query);
  }

  void searchAgain() {
    _result = null;
    search(_controller.text);
  }

  Duration get historyDelay => Duration.zero;

  void onQueryChanged(String query) async {
    if (!appModel.autoSearchEnabled) {
      return;
    }

    if (mounted) {
      search(query);
    }
  }

  bool _showMore = false;
  String lastQuery = '';

  void search(
    String query, {
    int? overrideMaximumTerms,
  }) async {
    if (lastQuery == query && overrideMaximumTerms == null) {
      return;
    } else {
      lastQuery = query;
    }

    overrideMaximumTerms ??= appModel.maximumTerms;
    if (_controller.text != query) {
      _controller.text = query;
      _controller.selection = TextSelection.collapsed(offset: query.length);
    }

    if (mounted) {
      setState(() {
        _isSearching = true;
        _popupStack.clear();
      });
    }

    try {
      _result = await appModel.searchDictionary(
        searchTerm: query,
        searchWithWildcards: true,
        overrideMaximumTerms: overrideMaximumTerms,
      );
    } finally {
      if (_result != null) {
        if (query == _controller.text) {
          if (mounted) {
            setState(() {
              _isSearching = false;
              _showMore = _result!.entries.length < overrideMaximumTerms!;
            });
          }
          Future.delayed(historyDelay, () async {
            if (query == _controller.text) {
              appModel.addToSearchHistory(
                historyKey: DictionaryMediaType.instance.uniqueKey,
                searchTerm: _controller.text,
              );
            }
            if (_result!.entries.isNotEmpty) {
              appModel.addToDictionaryHistory(result: _result!);
            }
          });
        }
      }
    }
  }

  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    updateCurrentQueryFromLookup(searchTerm);
  }

  Future<void> pushNestedPopup(
    String query,
    Rect selectionRect, {
    bool replaceStack = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final entry = _NestedPopupEntry(
      query: trimmed,
      selectionRect: _fallbackSelectionRect(selectionRect),
    );
    setState(() {
      if (replaceStack) {
        _popupStack.clear();
      }
      _popupStack.add(entry);
    });

    try {
      entry.result = await appModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: appModel.maximumTerms,
      );
    } finally {
      if (mounted && _popupStack.contains(entry)) {
        setState(() {
          entry.isSearching = false;
        });
      }
    }

    if (!mounted || !_popupStack.contains(entry)) {
      return;
    }
    final DictionarySearchResult? result = entry.result;
    if (result != null && result.entries.isNotEmpty) {
      appModel.addToSearchHistory(
        historyKey: DictionaryMediaType.instance.uniqueKey,
        searchTerm: trimmed,
      );
      appModel.addToDictionaryHistory(result: result);
    }
  }

  Rect _fallbackSelectionRect(Rect rect) {
    if (rect != Rect.zero) {
      return rect;
    }
    return const Rect.fromLTWH(12, 12, 1, 1);
  }

  void popNestedPopupAt(int index) {
    if (index < 0 || index >= _popupStack.length) {
      return;
    }
    setState(() {
      if (index == 0) {
        _popupStack.clear();
      } else {
        _popupStack.removeRange(index, _popupStack.length);
      }
    });
  }

  Future<void> openTextSegmentationForQuery() async {
    await appModel.openTextSegmentationDialog(
      sourceText: _controller.text,
      onSearch: (selection) async {
        updateCurrentQueryFromLookup(selection.textInside);
      },
    );

    widget.onUpdateQuery?.call(_controller.text);
  }

  void showDeleteSearchHistoryPrompt() async {
    Widget alertDialog = AlertDialog(
      title: Text(t.clear_search_title),
      content: Text(t.clear_browser_description),
      actions: <Widget>[
        TextButton(
          child: Text(
            t.dialog_clear,
            style: TextStyle(
              color: theme.colorScheme.primary,
            ),
          ),
          onPressed: () async {
            appModel.clearSearchHistory(
                historyKey: DictionaryMediaType.instance.uniqueKey);
            _controller.clear();

            if (mounted) {
              Navigator.pop(context);
              setState(() {});
            }
          },
        ),
        TextButton(
          child: Text(t.dialog_cancel),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    await showAppDialog(
      context: context,
      builder: (context) => alertDialog,
    );
  }

  Widget buildFloatingSearchBody(
    BuildContext context,
    Animation<double> transition,
  ) {
    if (appModel.dictionaries.isEmpty) {
      return buildImportDictionariesPlaceholderMessage();
    }
    if (_controller.text.isEmpty) {
      if (appModel
          .getSearchHistory(historyKey: DictionaryMediaType.instance.uniqueKey)
          .isEmpty) {
        return buildEnterSearchTermPlaceholderMessage();
      } else {
        return JidoujishoSearchHistory(
          uniqueKey: DictionaryMediaType.instance.uniqueKey,
          onSearchTermSelect: (searchTerm) {
            searchInCurrentPage(searchTerm);
            _searchFocusNode.unfocus();
          },
          onUpdate: () {
            setState(() {});
          },
        );
      }
    }
    if (_isSearching) {
      if (_result != null) {
        if (_result!.entries.isNotEmpty) {
          return buildSearchResult();
        } else {
          return buildNoSearchResultsPlaceholderMessage();
        }
      } else {
        return const SizedBox.shrink();
      }
    }
    if (_result == null || _result!.entries.isEmpty) {
      return buildNoSearchResultsPlaceholderMessage();
    }

    return buildSearchResult();
  }

  Widget buildSearchResult() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: DictionaryPopupWebView(
                    key: ValueKey(_result),
                    result: _result!,
                    onTextSelected: (text, localRect) {
                      pushNestedPopup(text, localRect, replaceStack: true);
                    },
                    onLinkClick: (query, localRect) {
                      pushNestedPopup(query, localRect, replaceStack: true);
                    },
                    onMineEntry: _onMineEntry,
                    onDuplicateCheck: (expression, reading) async {
                      final repo = ref.read(ankiRepositoryProvider);
                      return repo.isDuplicate(expression, reading);
                    },
                  ),
                ),
                if (footerWidget != null) footerWidget!,
              ],
            ),
            if (_popupStack.isNotEmpty)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => popNestedPopupAt(0),
                  child: Container(color: Colors.transparent),
                ),
              ),
            for (int i = 0; i < _popupStack.length; i++)
              buildNestedPopupLayer(i, screen),
          ],
        );
      },
    );
  }

  Widget buildNestedPopupLayer(int index, Size screen) {
    final _NestedPopupEntry entry = _popupStack[index];
    final Rect pos = calcPopupPosition(
      selectionRect: entry.selectionRect,
      screen: screen,
      padding: 6,
      maxWidth: appModel.popupMaxWidth,
      maxHeight: 360,
    );
    final bool isDark =
        (appModel.overrideDictionaryTheme ?? theme).brightness ==
            Brightness.dark;

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: DictionaryPopupLayer(
        result: entry.isSearching ? null : entry.result,
        webViewKey: entry.webViewKey,
        isDark: isDark,
        onDismiss: () => popNestedPopupAt(index),
        onTapOutside: () => popNestedPopupAt(0),
        onTextSelected: (text, localRect) {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : localRect.shift(Offset(pos.left, pos.top));
          setState(() {
            _popupStack.removeRange(index + 1, _popupStack.length);
          });
          pushNestedPopup(text, childRect);
        },
        onLinkClick: (query, localRect) {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : localRect.shift(Offset(pos.left, pos.top));
          setState(() {
            _popupStack.removeRange(index + 1, _popupStack.length);
          });
          pushNestedPopup(query, childRect);
        },
        onMineEntry: _onMineEntry,
        onDuplicateCheck: (expression, reading) async {
          final repo = ref.read(ankiRepositoryProvider);
          return repo.isDuplicate(expression, reading);
        },
      ),
    );
  }

  Future<bool> _onMineEntry(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    final miningContext = AnkiMiningContext(
      sentence: fields['sentence'] ?? '',
    );
    final result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    switch (result) {
      case MineResult.success:
        final settings = await repo.loadSettings();
        Fluttertoast.showToast(
          msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
        );
        return true;
      case MineResult.duplicate:
        Fluttertoast.showToast(msg: t.card_duplicate);
        return false;
      case MineResult.notConfigured:
        Fluttertoast.showToast(msg: t.card_export_not_configured);
        return false;
      case MineResult.error:
        Fluttertoast.showToast(msg: t.card_export_failed);
        return false;
    }
  }

  Widget? get footerWidget {
    if (_showMore) {
      return null;
    }

    return Padding(
      padding: Spacing.of(context).insets.all.small,
      child: Semantics(
        label: t.show_more,
        button: true,
        child: InkWell(
          onTap: _isSearching
              ? null
              : () async {
                  search(
                    _controller.text,
                    overrideMaximumTerms:
                        _result!.entries.length + appModel.maximumTerms,
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
    );
  }

  /// Get padding meant for a placeholder message in a floating body.
  EdgeInsets get floatingBodyPadding => EdgeInsets.only(
        top: (MediaQuery.of(context).size.height / 2) -
            (AppBar().preferredSize.height * 2),
      );

  Widget buildEnterSearchTermPlaceholderMessage() {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: Icons.search,
        message: t.enter_search_term,
      ),
    );
  }

  Widget buildImportDictionariesPlaceholderMessage() {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: Icons.auto_stories_rounded,
        message: t.dictionaries_menu_empty,
      ),
    );
  }

  Widget buildNoSearchResultsPlaceholderMessage() {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: Icons.search_off,
        message: t.no_search_results,
      ),
    );
  }
}

class _NestedPopupEntry {
  _NestedPopupEntry({
    required this.query,
    required this.selectionRect,
  });

  final String query;
  final Rect selectionRect;
  DictionarySearchResult? result;
  bool isSearching = true;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}
