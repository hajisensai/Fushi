import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:material_floating_search_bar/material_floating_search_bar.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/utils.dart';

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  /// Create an instance of this page.
  const HomeDictionaryPage({super.key});

  @override
  BaseTabPageState<BaseTabPage> createState() => _HomeDictionaryPageState();
}

class _HomeDictionaryPageState<T extends BaseTabPage> extends BaseTabPageState {
  @override
  MediaType get mediaType => DictionaryMediaType.instance;

  DictionarySearchResult? _result;

  bool _isSearching = false;
  bool _lastOpenedState = false;

  @override
  void initState() {
    super.initState();
    appModelNoUpdate.dictionarySearchAgainNotifier.addListener(searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .addListener(_onDictionaryEntriesChanged);
  }

  void _onDictionaryEntriesChanged() {
    if (!mounted) {
      return;
    }
    final model = appModelNoUpdate;
    if (mediaType.floatingSearchBarController.isClosed) {
      if (!model.isMediaOpen &&
          DictionaryMediaType.instance ==
              model.mediaTypes.values
                  .toList()[model.currentHomeTabIndex]) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .removeListener(_onDictionaryEntriesChanged);
    super.dispose();
  }

  bool get shouldPlaceholderBeShown => appModel.dictionaryHistory.isEmpty;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (shouldPlaceholderBeShown && !_lastOpenedState)
        buildPlaceholder()
      else if (!_lastOpenedState)
        buildDictionaryHistory(),
      buildFloatingSearchBar(),
    ]);
  }

  /// This is shown as the body when [shouldPlaceholderBeShown] is true.
  Widget buildPlaceholder() {
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

  Widget buildDictionaryHistory() {
    final historyResults = appModel.dictionaryHistory.reversed.toList();
    if (historyResults.every((r) => r.entries.isEmpty)) {
      return buildPlaceholder();
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 64, bottom: 16),
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
        final hasWordInfo =
            word.isNotEmpty && word != searchTerm;
        final hasReading =
            reading.isNotEmpty && reading != word && reading != searchTerm;
        final dictCount = result.entries
            .map((e) => e.dictionaryName)
            .toSet()
            .length;
        return InkWell(
          onTap: () async {
            await appModel.openResultFromHistory(result: result);
            setState(() {});
          },
          onLongPress: () {
            mediaType.floatingSearchBarController.query = searchTerm;
            mediaType.floatingSearchBarController.openWithoutFocus();
            search(searchTerm);
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
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
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
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

  /// The search bar to show at the topmost of the tab body. When selected,
  /// [buildSearchBarBody] will take the place of the remainder tab body, or
  /// the elements below the search bar when unselected.
  @override
  Widget buildFloatingSearchBar() {
    return FloatingSearchBar(
      isScrollControlled: true,
      hint: t.search_ellipsis,
      controller: mediaType.floatingSearchBarController,
      builder: buildFloatingSearchBody,
      borderRadius: BorderRadius.zero,
      elevation: 0,
      height: kToolbarHeight,
      backgroundColor: Theme.of(context).appBarTheme.backgroundColor ??
          Theme.of(context).colorScheme.surface,
      backdropColor: Colors.transparent,
      accentColor: theme.colorScheme.primary,
      scrollPadding: const EdgeInsets.only(top: 6, bottom: 56),
      transitionDuration: Duration.zero,
      margins: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      insets: EdgeInsets.zero,
      width: double.maxFinite,
      transition: SlideFadeFloatingSearchBarTransition(),
      automaticallyImplyBackButton: false,
      progress: _isSearching,
      onFocusChanged: (focused) => onFocusChanged(focused: focused),
      onQueryChanged: onQueryChanged,
      onSubmitted: search,
      debounceDelay: Duration(milliseconds: appModel.searchDebounceDelay),
      leadingActions: [
        buildBackButton(),
      ],
      actions: [
        buildDictionarySettingsButton(),
        buildClearButton(),
        buildSearchClearButton(),
        buildSearchButton(),
      ],
    );
  }

  @override
  void onFocusChanged({required bool focused}) async {
    final isOpen = mediaType.floatingSearchBarController.isOpen;
    if (isOpen != _lastOpenedState) {
      _lastOpenedState = isOpen;
      setState(() {});
    }
  }

  void searchAgain() {
    _result = null;
    search(mediaType.floatingSearchBarController.query);
  }

  Duration get historyDelay => const Duration(milliseconds: 500);

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

    if (mounted) {
      setState(() {
        _isSearching = true;
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
        if (query == mediaType.floatingSearchBarController.query) {
          if (mounted) {
            setState(() {
              _isSearching = false;
              _showMore = _result!.entries.length < overrideMaximumTerms!;
            });
          }
          Future.delayed(historyDelay, () async {
            if (query == mediaType.floatingSearchBarController.query) {
              appModel.addToSearchHistory(
                historyKey: mediaType.uniqueKey,
                searchTerm: mediaType.floatingSearchBarController.query,
              );
              if (_result!.entries.isNotEmpty) {
                appModel.addToDictionaryHistory(result: _result!);
              }
            }
          });
        }
      }
    }
  }

  Widget buildDictionaryButton() {
    return FloatingSearchBarAction(
      child: JidoujishoIconButton(
        size: textTheme.titleLarge?.fontSize,
        tooltip: t.dictionaries,
        icon: Icons.auto_stories,
        onTap: appModel.showDictionaryMenu,
      ),
    );
  }

  Widget buildClearButton() {
    return FloatingSearchBarAction(
      showIfOpened: false,
      showIfClosed: true,
      child: JidoujishoIconButton(
        size: textTheme.titleLarge?.fontSize,
        tooltip: t.clear_dictionary_title,
        icon: Icons.delete_sweep,
        onTap: showDeleteDictionaryHistoryPrompt,
      ),
    );
  }

  Widget buildSearchButton() {
    return FloatingSearchBarAction(
      showIfOpened: true,
      builder: (context, animation) {
        final bar = FloatingSearchAppBar.of(context)!;

        return ValueListenableBuilder<String>(
          valueListenable: bar.queryNotifer,
          builder: (context, query, _) {
            final isEmpty = query.isEmpty;

            return SearchToClear(
              isEmpty: isEmpty,
              size: textTheme.titleLarge!.fontSize!,
              color: bar.style.iconColor,
              duration: const Duration(milliseconds: 900) * 0.5,
              onTap: () {
                if (!isEmpty) {
                  bar.clear();
                } else {
                  bar.isOpen =
                      !bar.isOpen || (!bar.hasFocus && bar.isAlwaysOpened);
                }

                setState(() {});
              },
              searchButtonSemanticLabel: t.search,
              clearButtonSemanticLabel: t.clear,
            );
          },
        );
      },
    );
  }

  Widget buildSearchClearButton() {
    return FloatingSearchBarAction(
      showIfOpened: true,
      showIfClosed: false,
      child: JidoujishoIconButton(
        size: textTheme.titleLarge?.fontSize,
        tooltip: t.clear_search_title,
        icon: Icons.manage_search,
        onTap: showDeleteSearchHistoryPrompt,
      ),
    );
  }

  /// Dictionary settings bar action.
  Widget buildDictionarySettingsButton() {
    return FloatingSearchBarAction(
      showIfOpened: true,
      child: JidoujishoIconButton(
        size: Theme.of(context).textTheme.titleLarge?.fontSize,
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
    );
  }

  void showDeleteSearchHistoryPrompt() async {
    Widget alertDialog = AlertDialog(
      title: Text(t.clear_search_title),
      content: Text(
        t.clear_search_description,
      ),
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
            mediaType.floatingSearchBarController.clear();

            setState(() {});
            Navigator.pop(context);
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

  void showDeleteDictionaryHistoryPrompt() async {
    Widget alertDialog = AlertDialog(
      title: Text(t.clear_dictionary_title),
      content: Text(
        t.clear_dictionary_description,
      ),
      actions: <Widget>[
        TextButton(
          child: Text(
            t.dialog_clear,
            style: TextStyle(
              color: theme.colorScheme.primary,
            ),
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

  Widget buildFloatingSearchBody(
    BuildContext context,
    Animation<double> transition,
  ) {
    if (appModel.dictionaries.isEmpty) {
      return buildImportDictionariesPlaceholderMessage();
    }
    if (mediaType.floatingSearchBarController.query.isEmpty) {
      if (appModel.getSearchHistory(historyKey: mediaType.uniqueKey).isEmpty) {
        return buildEnterSearchTermPlaceholderMessage();
      } else {
        return JidoujishoSearchHistory(
          uniqueKey: mediaType.uniqueKey,
          onSearchTermSelect: (searchTerm) {
            setState(() {
              mediaType.floatingSearchBarController.query = searchTerm;
              search(searchTerm);
            });
          },
          onUpdate: () {
            setState(() {});
          },
        );
      }
    }
    if (_isSearching) {
      if (_result != null && _result!.entries.isNotEmpty) {
        return buildSearchResult();
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
    return Column(
      children: [
        Expanded(
          child: DictionaryPopupWebView(
            key: ValueKey(_result),
            result: _result!,
            onTextSelected: (text, _) {
              mediaType.floatingSearchBarController.query = text;
              search(text);
            },
            onLinkClick: (query) {
              mediaType.floatingSearchBarController.query = query;
              search(query);
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
      child: InkWell(
        onTap: _isSearching
            ? null
            : () async {
                search(
                  mediaType.floatingSearchBarController.query,
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
    );
  }

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
        icon: mediaType.outlinedIcon,
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
