import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_floating_search_bar/material_floating_search_bar.dart';
import 'package:spaces/spaces.dart';
import 'dart:io';

import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
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
    appModelNoUpdate.dictionaryEntriesNotifier.addListener(() {
      if (mediaType.floatingSearchBarController.isClosed) {
        if (!appModel.isMediaOpen &&
            DictionaryMediaType.instance ==
                appModel.mediaTypes.values
                    .toList()[appModel.currentHomeTabIndex]) {
          if (mounted) {
            setState(() {});
          }
        }
      }
    });
  }

  @override
  void dispose() {
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
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: mediaType.outlinedIcon,
        message: t.info_empty_home_tab,
      ),
    );
  }

  Widget buildDictionaryHistory() {
    final historyResults = appModel.dictionaryHistory.reversed.toList();
    final allEntries = historyResults.expand((r) => r.entries).toList();
    if (allEntries.isEmpty) {
      return buildPlaceholder();
    }
    final mergedResult = DictionarySearchResult(
      entries: allEntries,
      searchTerm: '',
    );
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: DictionaryPopupWebView(
        key: ValueKey(allEntries.length),
        result: mergedResult,
        onTextSelected: (text) {
          mediaType.floatingSearchBarController.query = text;
          mediaType.floatingSearchBarController.open();
          search(text);
        },
        onMineEntry: _onMineEntry,
      ),
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
      backgroundColor: appModel.isDarkMode
          ? const Color.fromARGB(255, 30, 30, 30)
          : const Color.fromARGB(255, 229, 229, 229),
      backdropColor: Colors.transparent,
      accentColor: theme.colorScheme.primary,
      scrollPadding: const EdgeInsets.only(top: 6, bottom: 56),
      transitionDuration: Duration.zero,
      margins: const EdgeInsets.symmetric(horizontal: 6),
      width: double.maxFinite,
      transition: SlideFadeFloatingSearchBarTransition(),
      automaticallyImplyBackButton: false,
      progress: _isSearching,
      onFocusChanged: (focused) => onFocusChanged(focused: focused),
      onQueryChanged: onQueryChanged,
      onSubmitted: search,
      debounceDelay: Duration(milliseconds: appModel.searchDebounceDelay),
      leadingActions: [
        buildDictionaryButton(),
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

          await showDialog(
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

    await showDialog(
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

    await showDialog(
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
              FocusManager.instance.primaryFocus?.unfocus();
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
            onTextSelected: (text) {
              mediaType.floatingSearchBarController.query = text;
              search(text);
            },
            onMineEntry: _onMineEntry,
          ),
        ),
        if (footerWidget != null)
          footerWidget!,
      ],
    );
  }

  void _onMineEntry(Map<String, String> fields) {
    appModel.openCreator(
      ref: ref,
      killOnPop: false,
      creatorFieldValues: CreatorFieldValues(
        textValues: {
          TermField.instance: fields['expression'] ?? '',
          ReadingField.instance: fields['reading'] ?? '',
          MeaningField.instance: fields['glossary'] ?? '',
        },
      ),
      onCreatorReady: (creatorModel) async {
        final String wordAudioUrl = fields['audio'] ?? '';
        if (wordAudioUrl.isEmpty) return;
        try {
          File? audioFile;
          if (wordAudioUrl.startsWith('file://')) {
            audioFile = File(wordAudioUrl.replaceFirst('file://', ''));
          } else if (wordAudioUrl.startsWith('/')) {
            audioFile = File(wordAudioUrl);
          } else if (wordAudioUrl.startsWith('http')) {
            final response = await HttpClient()
                .getUrl(Uri.parse(wordAudioUrl))
                .then((req) => req.close());
            final bytes = await response.fold<List<int>>(
                [], (prev, chunk) => prev..addAll(chunk));
            if (bytes.isNotEmpty) {
              final ext = wordAudioUrl.contains('.opus')
                  ? '.opus'
                  : wordAudioUrl.contains('.ogg')
                      ? '.ogg'
                      : '.mp3';
              audioFile = File('${Directory.systemTemp.path}/mine_word_audio$ext');
              await audioFile.writeAsBytes(bytes);
            }
          }
          if (audioFile == null || !audioFile.existsSync()) {
            final expression = fields['expression'] ?? '';
            if (expression.isNotEmpty) {
              final ttsPath = '${Directory.systemTemp.path}/mine_word_tts.wav';
              final ttsResult = await TtsChannel.instance.ttsToFile(expression, ttsPath);
              if (ttsResult != null) {
                audioFile = File(ttsResult);
              }
            }
          }
          if (audioFile != null && audioFile.existsSync()) {
            AudioField.instance.setAudioFile(
              appModel: appModel,
              creatorModel: creatorModel,
              file: audioFile,
            );
          }
        } catch (e) {
          debugPrint('[hibiki-mine] word audio failed: $e');
        }
      },
    );
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
