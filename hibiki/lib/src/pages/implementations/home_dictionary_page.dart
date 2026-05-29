import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/utils.dart';

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  const HomeDictionaryPage({super.key, this.focusSignal});

  final ValueNotifier<int>? focusSignal;

  @override
  BaseTabPageState<BaseTabPage> createState() => _HomeDictionaryPageState();
}

class _HomeDictionaryPageState<T extends BaseTabPage> extends BaseTabPageState
    with DictionaryPageMixin {
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => theme;

  @override
  MediaType get mediaType => DictionaryMediaType.instance;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  DictionarySearchResult? _result;
  final List<NestedPopupEntry> _popupStack = [];

  bool _isSearching = false;
  String _lastQuery = '';
  bool _allLoaded = false;
  Timer? _debounceTimer;

  bool _historyWritten = false;

  @override
  void initState() {
    super.initState();
    appModelNoUpdate.dictionarySearchAgainNotifier.addListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .addListener(_onDictionaryEntriesChanged);
    _searchFocusNode.addListener(_onFocusChanged);
    (widget as HomeDictionaryPage).focusSignal?.addListener(_onFocusSignal);
  }

  void _onFocusSignal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _onFocusChanged() {
    if (!_searchFocusNode.hasFocus) {
      _commitHistory();
    }
  }

  void _commitHistory() {
    if (_historyWritten) return;
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty || _result == null || _result!.entries.isEmpty) return;
    _historyWritten = true;
    appModel.addToSearchHistory(
      historyKey: mediaType.uniqueKey,
      searchTerm: trimmed,
    );
    appModel.addToDictionaryHistory(result: _result!);
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
    (widget as HomeDictionaryPage).focusSignal?.removeListener(_onFocusSignal);
    _searchFocusNode.removeListener(_onFocusChanged);
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .removeListener(_onDictionaryEntriesChanged);
    _commitHistory();
    _debounceTimer?.cancel();
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
      child: DesktopContentLayout(
        kind: DesktopContentKind.dictionary,
        child: Column(
          children: [
            if (!isCupertinoPlatform(context)) _buildPageHeader(),
            _buildSearchHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildPageHeader() {
    return HibikiPageHeader(
      title: t.dictionaries,
      actions: <Widget>[
        HibikiIconButton(
          tooltip: t.clear_dictionary_title,
          icon: Icons.delete_sweep_outlined,
          onTap: _showDeleteDictionaryHistoryPrompt,
        ),
      ],
    );
  }

  Widget _buildSearchHeader() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isCupertinoPlatform(context) ? 8 : 16,
        0,
        isCupertinoPlatform(context) ? 8 : 16,
        8,
      ),
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(
          children: [
            Expanded(
              child: HibikiSearchField(
                fieldKey:
                    const ValueKey<String>('home_dictionary_search_field'),
                controller: _controller,
                focusNode: _searchFocusNode,
                hintText: t.search_ellipsis,
                onChanged: _onQueryChanged,
                onSubmitted: _search,
              ),
            ),
            if (isCupertinoPlatform(context))
              IconButton(
                tooltip: t.clear_dictionary_title,
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: _showDeleteDictionaryHistoryPrompt,
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
      return Center(child: adaptiveIndicator(context: context));
    }
    return Center(
      child: HibikiPlaceholderMessage(
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
          HibikiPlaceholderMessage(
            icon: mediaType.outlinedIcon,
            message: noDictionaries
                ? t.dictionaries_menu_empty
                : t.info_empty_home_tab,
          ),
          if (noDictionaries) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.auto_stories_outlined, size: 18),
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
        return HibikiCard(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          onTap: () {
            _controller.text = searchTerm;
            _controller.selection =
                TextSelection.collapsed(offset: searchTerm.length);
            _showCachedResult(result);
          },
          padding: EdgeInsets.zero,
          child: HibikiListItem(
            title: Text(searchTerm.replaceAll('\n', ' ')),
            subtitle: hasWordInfo || hasReading
                ? Text([
                    if (hasWordInfo) word,
                    if (hasReading) reading,
                  ].join('  '))
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$dictCount'),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── search logic ───────────────────────────────────────────────────

  void _onQueryChanged(String query) {
    _debounceTimer?.cancel();
    _historyWritten = false;
    if (query.isEmpty) {
      _clearSearch();
      return;
    }
    if (!appModel.autoSearchEnabled) return;
    final int delay = appModel.searchDebounceDelay;
    if (delay <= 0) {
      if (mounted) _search(query, writeHistory: false);
    } else {
      _debounceTimer = Timer(Duration(milliseconds: delay), () {
        if (mounted) _search(query, writeHistory: false);
      });
    }
  }

  void _searchAgain() {
    _lastQuery = '';
    _search(_controller.text);
  }

  void _showCachedResult(DictionarySearchResult cached) {
    setState(() {
      _result = cached;
      _isSearching = false;
      // Non-empty cache always allows one scroll-to-bottom probe;
      // _loadMore will set _allLoaded if nothing new comes back.
      _allLoaded = cached.entries.isEmpty;
      _lastQuery = cached.searchTerm.trim();
      _popupStack.clear();
    });
  }

  void _search(
    String query, {
    int? overrideMaximumTerms,
    bool writeHistory = true,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;

    if (_lastQuery == trimmed && overrideMaximumTerms == null) {
      if (writeHistory &&
          !_historyWritten &&
          _result != null &&
          _result!.entries.isNotEmpty) {
        _historyWritten = true;
        appModel.addToSearchHistory(
          historyKey: mediaType.uniqueKey,
          searchTerm: trimmed,
        );
        appModel.addToDictionaryHistory(result: _result!);
      }
      return;
    }
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
        final bool allLoaded = _result!.entries.length < overrideMaximumTerms;
        if (mounted) {
          setState(() {
            _isSearching = false;
            _allLoaded = allLoaded;
          });
        }

        if (writeHistory) {
          _historyWritten = true;
          appModel.addToSearchHistory(
            historyKey: mediaType.uniqueKey,
            searchTerm: trimmed,
          );
          if (_result!.entries.isNotEmpty) {
            appModel.addToDictionaryHistory(result: _result!);
            if (ReaderHibikiSource.instance.autoReadOnLookup) {
              final entry = _result!.entries.first;
              if (entry.word.isNotEmpty) {
                autoReadWord(entry.word, entry.reading);
              }
            }
          }
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
      writeHistory: false,
    );
  }

  // ── search results with nested popups ──────────────────────────────

  Widget _buildSearchResultBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            const SizedBox.shrink(
              key: ValueKey<String>('home_dictionary_result_evidence'),
            ),
            DictionaryPopupWebView(
              result: _result!,
              onTextSelected: (text, localRect) {
                _pushNestedPopup(text, localRect, replaceStack: true);
              },
              onLinkClick: (query, localRect) {
                _pushNestedPopup(query, localRect, replaceStack: true);
              },
              onMineEntry: onMineEntry,
              onDuplicateCheck: checkDuplicate,
              onScrolledToBottom: _allLoaded ? null : _loadMore,
            ),
            if (_popupStack.isNotEmpty)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _popNestedPopupAt(0),
                  child: Container(
                    color: Colors.transparent,
                  ),
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
  }) {
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      popupStack: _popupStack,
      replaceStack: replaceStack,
      autoRead: true,
    );
  }

  void _popNestedPopupAt(int index) {
    popNestedPopupAt(index, _popupStack);
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    return buildNestedPopupLayer(
      index: index,
      screen: screen,
      popupStack: _popupStack,
      onPush: (text, rect) => _pushNestedPopup(text, rect),
      onPop: _popNestedPopupAt,
    );
  }

  // ── dialogs ────────────────────────────────────────────────────────

  void _showDeleteDictionaryHistoryPrompt() async {
    await showAppDialog(
      context: context,
      builder: (context) => HomeDictionaryClearHistoryDialog(
        onConfirm: () async {
          Navigator.pop(context);
          await appModel.clearDictionaryHistory();
          if (mounted) setState(() {});
        },
      ),
    );
  }
}

@visibleForTesting
class HomeDictionaryClearHistoryDialog extends StatelessWidget {
  const HomeDictionaryClearHistoryDialog({
    required this.onConfirm,
    super.key,
  });

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
        title: t.clear_dictionary_title,
        leadingIcon: Icons.delete_sweep_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.clear_dictionary_description,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              child: Text(t.dialog_cancel),
              onPressed: () => Navigator.pop(context),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              child: Text(t.dialog_clear),
              onPressed: onConfirm,
            ),
          ],
        ),
      ),
    );
  }
}
