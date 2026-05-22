import 'package:expandable/expandable.dart';
import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/pages.dart';

/// Returns the widget for a [DictionarySearchResult] which returns a
/// scrollable list of each [DictionaryEntry] in its mappings.
class DictionaryResultPage extends BasePage {
  /// Create the widget of a [DictionarySearchResult].
  const DictionaryResultPage({
    required this.result,
    required this.onSearch,
    required this.onStash,
    required this.onShare,
    this.cardColor,
    this.scrollController,
    this.opacity = 1,
    this.updateHistory = true,
    this.spaceBeforeFirstResult = true,
    this.footerWidget,
    super.key,
  });

  /// The result made from a dictionary database search.
  final DictionarySearchResult result;

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  /// Action to be done upon selecting the stash option.
  final Function(String) onStash;

  /// Action to be done upon selecting the share option.
  final Function(String) onShare;

  /// Whether or not to update dictionary history upon viewing this result.
  final bool updateHistory;

  /// Whether or not to put a space before the first result.
  final bool spaceBeforeFirstResult;

  /// Override color for the background color for [DictionaryTermPage].
  final Color? cardColor;

  /// Opacity for entries.
  final double opacity;

  /// Allows controlling the scroll position of the page.
  final ScrollController? scrollController;

  /// Optional footer for use for showing more.
  final Widget? footerWidget;

  @override
  BasePageState<DictionaryResultPage> createState() =>
      _DictionaryResultPageState();
}

class _DictionaryResultPageState extends BasePageState<DictionaryResultPage> {
  @override
  void initState() {
    super.initState();
    _ownsScrollController = widget.scrollController == null;
    _scrollController = widget.scrollController ?? ScrollController();
  }

  late ScrollController _scrollController;
  late bool _ownsScrollController;

  /// Group entries by (word, reading) key for expandable controllers.
  Map<String, Map<String, ExpandableController>>
      expandableControllersByTermKey = {};

  @override
  void dispose() {
    if (_ownsScrollController) {
      _scrollController.dispose();
    }
    for (final controllers in expandableControllersByTermKey.values) {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    /// Group entries by (word, reading) to form term groups.
    final Map<String, List<DictionaryEntry>> groupedEntries = {};
    for (final entry in widget.result.entries) {
      final key = '${entry.word}\n${entry.reading}';
      groupedEntries.putIfAbsent(key, () => []).add(entry);
    }

    final termKeys = groupedEntries.keys.toList();

    List<Dictionary> dictionaries = appModel.dictionaries;
    Map<String, bool> dictionaryNamesByHidden = Map<String, bool>.fromEntries(
        dictionaries
            .map((e) => MapEntry(e.name, e.isHidden(appModel.targetLanguage))));
    Map<String, int> dictionaryNamesByOrder = Map<String, int>.fromEntries(
        dictionaries.map((e) => MapEntry(e.name, e.order)));

    for (final termKey in termKeys) {
      expandableControllersByTermKey.putIfAbsent(termKey, () => {});
      for (DictionaryEntry entry in groupedEntries[termKey]!) {
        expandableControllersByTermKey[termKey]?.putIfAbsent(
          entry.dictionaryName,
          () => ExpandableController(initialExpanded: true),
        );
      }
    }

    return MediaQuery(
      data: MediaQuery.of(context).removePadding(
        removeTop: true,
        removeBottom: true,
        removeLeft: true,
        removeRight: true,
      ),
      child: RawScrollbar(
        thumbVisibility: true,
        thickness: 3,
        controller: _scrollController,
        child: Padding(
          padding: Spacing.of(context).insets.onlyRight.extraSmall,
          child: CustomScrollView(
            cacheExtent: appModel.lowMemoryMode ? 300 : 999999999999999,
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverPadding(
                  padding: widget.spaceBeforeFirstResult
                      ? Spacing.of(context).insets.onlyTop.normal
                      : EdgeInsets.zero),
              ...termKeys
                  .map((termKey) => DictionaryTermPage(
                        opacity: widget.opacity,
                        cardColor: widget.cardColor,
                        entries: groupedEntries[termKey]!,
                        onSearch: widget.onSearch,
                        onStash: widget.onStash,
                        onShare: widget.onShare,
                        expandableControllers:
                            expandableControllersByTermKey[termKey]!,
                        dictionaryNamesByHidden: dictionaryNamesByHidden,
                        dictionaryNamesByOrder: dictionaryNamesByOrder,
                      ))
                  .toList(),
              if (widget.footerWidget != null) widget.footerWidget!,
            ],
          ),
        ),
      ),
    );
  }
}
