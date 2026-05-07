import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/utils.dart';

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  const HomeDictionaryPage({super.key});

  @override
  BaseTabPageState<BaseTabPage> createState() => _HomeDictionaryPageState();
}

class _HomeDictionaryPageState<T extends BaseTabPage> extends BaseTabPageState {
  @override
  MediaType get mediaType => DictionaryMediaType.instance;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  DictionarySearchResult? _result;
  final List<_NestedPopupEntry> _popupStack = [];

  bool _isSearching = false;
  String _lastQuery = '';
  bool _allLoaded = false;

  @override
  void initState() {
    super.initState();
    appModelNoUpdate.dictionarySearchAgainNotifier.addListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .addListener(_onDictionaryEntriesChanged);
  }

  void _onDictionaryEntriesChanged() {
    if (!mounted) return;
    final model = appModelNoUpdate;
    if (!model.isMediaOpen &&
        DictionaryMediaType.instance ==
            model.mediaTypes.values.toList()[model.currentHomeTabIndex]) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .removeListener(_onDictionaryEntriesChanged);
    _searchFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _hasActiveQuery => _controller.text.isNotEmpty;

  void _clearSearch() {
    _controller.clear();
    _popupStack.clear();
    _result = null;
    _isSearching = false;
    _lastQuery = '';
    _allLoaded = false;
    _searchFocusNode.unfocus();
    setState(() {});
  }

  // ── build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasActiveQuery && _popupStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_popupStack.isNotEmpty) {
          _popNestedPopupAt(_popupStack.length - 1);
        } else if (_hasActiveQuery) {
          _clearSearch();
        }
      },
      child: Column(
        children: [
          _buildSearchHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildSearchHeader() {
    final ColorScheme colors = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
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
                  onChanged: _onQueryChanged,
                  onSubmitted: _search,
                ),
              ),
            ),
            JidoujishoIconButton(
              size: textTheme.titleLarge?.fontSize,
              tooltip: t.dictionary_settings,
              icon: Icons.settings,
              onTap: () async {
                double oldFontSize = appModel.dictionaryFontSize;
                await showAppDialog(
                  context: context,
                  builder: (context) => const DictionarySettingsDialogPage(),
                );
                if (appModel.dictionaryFontSize != oldFontSize) {
                  appModel.refresh();
                }
              },
            ),
            JidoujishoIconButton(
              size: textTheme.titleLarge?.fontSize,
              tooltip: t.clear_dictionary_title,
              icon: Icons.delete_sweep,
              onTap: _showDeleteDictionaryHistoryPrompt,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_hasActiveQuery) {
      return _buildQueryBody();
    }
    if (appModel.dictionaryHistory.isEmpty) {
      return _buildPlaceholder();
    }
    return _buildDictionaryHistory();
  }

  Widget _buildQueryBody() {
    if (_result != null && _result!.entries.isNotEmpty) {
      return _buildSearchResultBody();
    }
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: Icons.search_off,
        message: t.no_search_results,
      ),
    );
  }

  Widget _buildPlaceholder() {
    final noDictionaries = appModel.dictionaries.isEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JidoujishoPlaceholderMessage(
            icon: mediaType.outlinedIcon,
            message: noDictionaries
                ? t.dictionaries_menu_empty
                : t.info_empty_home_tab,
          ),
          if (noDictionaries) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.auto_stories, size: 18),
              label: Text(t.dialog_import_dictionary),
              onPressed: appModel.showDictionaryMenu,
            ),
          ],
        ],
      ),
    );
  }

  // ── dictionary history list ────────────────────────────────────────

  Widget _buildDictionaryHistory() {
    final historyResults = appModel.dictionaryHistory.reversed.toList();
    if (historyResults.every((r) => r.entries.isEmpty)) {
      return _buildPlaceholder();
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      controller: DictionaryMediaType.instance.scrollController,
      itemCount: historyResults.length,
      itemBuilder: (context, index) {
        final result = historyResults[index];
        if (result.entries.isEmpty) {
          return const SizedBox.shrink();
        }
        final searchTerm = result.searchTerm.trim();
        final first = result.entries.first;
        final word = first.word;
        final reading = first.reading;
        final hasWordInfo = word.isNotEmpty && word != searchTerm;
        final hasReading =
            reading.isNotEmpty && reading != word && reading != searchTerm;
        final dictCount =
            result.entries.map((e) => e.dictionaryName).toSet().length;
        return InkWell(
          onTap: () {
            _controller.text = searchTerm;
            _controller.selection =
                TextSelection.collapsed(offset: searchTerm.length);
            _search(searchTerm);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            searchTerm.replaceAll('\n', ' '),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (hasWordInfo || hasReading) ...[
                            const SizedBox(height: 2),
                            Text(
                              [
                                if (hasWordInfo) word,
                                if (hasReading) reading,
                              ].join('  '),
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    Text(
                      '$dictCount',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── search logic ───────────────────────────────────────────────────

  void _onQueryChanged(String query) {
    if (query.isEmpty) {
      _clearSearch();
      return;
    }
    if (!appModel.autoSearchEnabled) return;
    if (mounted) _search(query);
  }

  void _searchAgain() {
    _result = null;
    _search(_controller.text);
  }

  void _search(
    String query, {
    int? overrideMaximumTerms,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;

    if (_lastQuery == trimmed && overrideMaximumTerms == null) return;
    _lastQuery = trimmed;
    overrideMaximumTerms ??= appModel.maximumTerms;

    if (_controller.text != trimmed) {
      _controller.text = trimmed;
      _controller.selection = TextSelection.collapsed(offset: trimmed.length);
    }

    if (mounted) {
      setState(() {
        _isSearching = true;
        _popupStack.clear();
      });
    }

    try {
      _result = await appModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: overrideMaximumTerms,
      );
    } finally {
      if (_result != null && trimmed == _controller.text) {
        final bool allLoaded =
            _result!.entries.length < overrideMaximumTerms;
        if (mounted) {
          setState(() {
            _isSearching = false;
            _allLoaded = allLoaded;
          });
        }

        // Auto-load more when not all results are loaded yet.
        if (!allLoaded && mounted) {
          _loadMore();
        }

        appModel.addToSearchHistory(
          historyKey: mediaType.uniqueKey,
          searchTerm: trimmed,
        );
        if (_result!.entries.isNotEmpty) {
          appModel.addToDictionaryHistory(result: _result!);
        }
      }
    }
  }

  void _loadMore() {
    if (_isSearching || _allLoaded || _result == null) return;
    final current = _result!.entries.length;
    _lastQuery = '';
    _search(
      _controller.text,
      overrideMaximumTerms: current + appModel.maximumTerms,
    );
  }

  // ── search results with nested popups ──────────────────────────────

  Widget _buildSearchResultBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            DictionaryPopupWebView(
              key: ValueKey(_result),
              result: _result!,
              onTextSelected: (text, localRect) {
                _pushNestedPopup(text, localRect, replaceStack: true);
              },
              onLinkClick: (query, localRect) {
                _pushNestedPopup(query, localRect, replaceStack: true);
              },
              onMineEntry: _onMineEntry,
              onDuplicateCheck: (expression, reading) async {
                final repo = ref.read(ankiRepositoryProvider);
                return repo.isDuplicate(expression, reading);
              },
            ),
            if (_popupStack.isNotEmpty)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _popNestedPopupAt(0),
                  child: Container(color: Colors.transparent),
                ),
              ),
            for (int i = 0; i < _popupStack.length; i++)
              _buildNestedPopupLayer(i, screen),
          ],
        );
      },
    );
  }

  Future<void> _pushNestedPopup(
    String query,
    Rect selectionRect, {
    bool replaceStack = false,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final entry = _NestedPopupEntry(
      query: trimmed,
      selectionRect: _fallbackSelectionRect(selectionRect),
    );
    setState(() {
      if (replaceStack) _popupStack.clear();
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
        setState(() => entry.isSearching = false);
      }
    }

    if (!mounted || !_popupStack.contains(entry)) return;
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
    if (rect != Rect.zero) return rect;
    return const Rect.fromLTWH(12, 12, 1, 1);
  }

  void _popNestedPopupAt(int index) {
    if (index < 0 || index >= _popupStack.length) return;
    setState(() {
      if (index == 0) {
        _popupStack.clear();
      } else {
        _popupStack.removeRange(index, _popupStack.length);
      }
    });
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    final _NestedPopupEntry entry = _popupStack[index];
    final Rect pos = calcPopupPosition(
      selectionRect: entry.selectionRect,
      screen: screen,
      padding: 6,
      maxWidth: appModel.popupMaxWidth,
      maxHeight: 360,
    );
    final bool isDark = theme.brightness == Brightness.dark;

    return Positioned(
      left: pos.left,
      top: pos.top,
      width: pos.width,
      height: pos.height,
      child: DictionaryPopupLayer(
        result: entry.isSearching ? null : entry.result,
        webViewKey: entry.webViewKey,
        isDark: isDark,
        onDismiss: () => _popNestedPopupAt(index),
        onTapOutside: () => _popNestedPopupAt(0),
        onTextSelected: (text, localRect) {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : localRect.shift(Offset(pos.left, pos.top));
          setState(() {
            _popupStack.removeRange(index + 1, _popupStack.length);
          });
          _pushNestedPopup(text, childRect);
        },
        onLinkClick: (query, localRect) {
          final Rect childRect = localRect == Rect.zero
              ? entry.selectionRect
              : localRect.shift(Offset(pos.left, pos.top));
          setState(() {
            _popupStack.removeRange(index + 1, _popupStack.length);
          });
          _pushNestedPopup(query, childRect);
        },
        onMineEntry: _onMineEntry,
        onDuplicateCheck: (expression, reading) async {
          final repo = ref.read(ankiRepositoryProvider);
          return repo.isDuplicate(expression, reading);
        },
      ),
    );
  }

  // ── Anki mining ────────────────────────────────────────────────────

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

  // ── dialogs ────────────────────────────────────────────────────────

  void _showDeleteDictionaryHistoryPrompt() async {
    Widget alertDialog = AlertDialog(
      title: Text(t.clear_dictionary_title),
      content: Text(t.clear_dictionary_description),
      actions: <Widget>[
        TextButton(
          child: Text(
            t.dialog_clear,
            style: TextStyle(color: theme.colorScheme.primary),
          ),
          onPressed: () async {
            Navigator.pop(context);
            await appModel.clearDictionaryHistory();
            setState(() {});
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
