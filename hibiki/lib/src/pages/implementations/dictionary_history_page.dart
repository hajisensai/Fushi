import 'package:expandable/expandable.dart';
import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';

/// Returns the main body of the [HomeDictionaryPage] before the search bar
/// is opened.
class DictionaryHistoryPage extends BasePage {
  /// Create the main body of the [HomeDictionaryPage].
  const DictionaryHistoryPage({
    required this.onSearch,
    required this.onStash,
    required this.onShare,
    super.key,
  });

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  /// Action to be done upon selecting the stash option.
  final Function(String) onStash;

  /// Action to be done upon selecting the stash option.
  final Function(String) onShare;

  @override
  BasePageState<DictionaryHistoryPage> createState() =>
      _DictionaryHistoryPageState();
}

class _DictionaryHistoryPageState extends BasePageState<DictionaryHistoryPage> {
  @override
  Widget build(BuildContext context) {
    AnkiMapping lastSelectedMapping = appModel.lastSelectedMapping;

    List<DictionarySearchResult> historyResults =
        appModel.dictionaryHistory.reversed.toList();

    return CustomScrollView(
      cacheExtent: 999999999999999,
      controller: DictionaryMediaType.instance.scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 60)),
        ...historyResults
            .map(
              (result) => _DictionaryHistoryScrollableItem(
                result: result,
                onSearch: widget.onSearch,
                onStash: widget.onStash,
                onShare: widget.onShare,
                lastSelectedMapping: lastSelectedMapping,
              ),
            )
            .toList(),
      ],
    );
  }
}

class _DictionaryHistoryScrollableItem extends BasePage {
  const _DictionaryHistoryScrollableItem({
    required this.result,
    required this.onStash,
    required this.onSearch,
    required this.onShare,
    required this.lastSelectedMapping,
  });

  /// The result pertaining to this item.
  final DictionarySearchResult result;

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  /// Action to be done upon selecting the stash option.
  final Function(String) onStash;

  /// Action to be done upon selecting the stash option.
  final Function(String) onShare;

  /// The current mapping.
  final AnkiMapping lastSelectedMapping;

  @override
  _DictionaryHistoryScrollableItemState createState() =>
      _DictionaryHistoryScrollableItemState();
}

class _DictionaryHistoryScrollableItemState
    extends BasePageState<_DictionaryHistoryScrollableItem>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    DictionarySearchResult result = widget.result;
    List<DictionaryEntry> entries = result.entries;

    if (entries.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    /// Group entries by (word, reading) to form term groups.
    final Map<String, List<DictionaryEntry>> groupedEntries = {};
    for (final entry in entries) {
      final key = '${entry.word}\n${entry.reading}';
      groupedEntries.putIfAbsent(key, () => []).add(entry);
    }

    final termKeys = groupedEntries.keys.toList();

    List<Dictionary> dictionaries = appModel.dictionaries;
    Map<String, bool> dictionaryNamesByHidden = Map<String, bool>.fromEntries(
        dictionaries
            .map((e) => MapEntry(e.name, e.isHidden(appModel.targetLanguage))));
    Map<String, bool> dictionaryNamesByCollapsed =
        Map<String, bool>.fromEntries(dictionaries.map(
            (e) => MapEntry(e.name, e.isCollapsed(appModel.targetLanguage))));
    Map<String, int> dictionaryNamesByOrder = Map<String, int>.fromEntries(
        dictionaries.map((e) => MapEntry(e.name, e.order)));

    final Map<String, Map<String, ExpandableController>>
        expandableControllersByTermKey = {};
    for (final termKey in termKeys) {
      expandableControllersByTermKey.putIfAbsent(termKey, () => {});
      for (DictionaryEntry entry in groupedEntries[termKey]!) {
        expandableControllersByTermKey[termKey]?.putIfAbsent(
          entry.dictionaryName,
          () => ExpandableController(
            initialExpanded:
                !(dictionaryNamesByCollapsed[entry.dictionaryName] ?? false),
          ),
        );
      }
    }

    /// Show the first term group.
    final firstTermKey = termKeys.first;

    return DictionaryTermPage(
      lastSelectedMapping: widget.lastSelectedMapping,
      entries: groupedEntries[firstTermKey]!,
      onSearch: widget.onSearch,
      onStash: widget.onStash,
      onShare: widget.onShare,
      expandableControllers: expandableControllersByTermKey[firstTermKey]!,
      dictionaryNamesByHidden: dictionaryNamesByHidden,
      dictionaryNamesByOrder: dictionaryNamesByOrder,
      footerWidget: termKeys.length > 1
          ? buildFooterWidget(result: result, length: termKeys.length)
          : null,
    );
  }

  Widget buildFooterWidget({
    required DictionarySearchResult result,
    required int length,
  }) {
    return Padding(
      padding: Spacing.of(context).insets.onlyBottom.small,
      child: Semantics(
        label: t.show_more,
        button: true,
        child: InkWell(
          onTap: () async {
            await appModel.openResultFromHistory(result: result);
            appModel.refreshDictionaryHistory();
          },
          child: Container(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withOpacity(0.05)
                : Colors.black.withOpacity(0.05),
            width: double.maxFinite,
            child: Padding(
              padding: Spacing.of(context).insets.all.small,
              child: buildFooterTextSpans(
                result: result,
                length: length,
              ),
            ),
          ),
        ),
      ),
    );
  }

  double get fontSize => (textTheme.labelMedium?.fontSize)! * 0.9;

  Widget buildFooterTextSpans({
    required DictionarySearchResult result,
    required int length,
  }) {
    return Text.rich(
      TextSpan(
        text: '',
        children: <InlineSpan>[
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: EdgeInsets.only(
                top: 1.25,
                right: Spacing.of(context).spaces.small,
              ),
              child: Icon(
                DictionaryMediaType.instance.icon,
                size: fontSize,
                color: Theme.of(context).unselectedWidgetColor,
              ),
            ),
          ),
          TextSpan(
            text: t.search_label_before,
            style: TextStyle(
              fontSize: fontSize,
              color: Theme.of(context).unselectedWidgetColor,
            ),
          ),
          TextSpan(
            text: '$length ',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
            ),
          ),
          TextSpan(
            text: t.search_label_after,
            style: TextStyle(
              fontSize: fontSize,
              color: Theme.of(context).unselectedWidgetColor,
            ),
          ),
          TextSpan(
            text: ' ',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
              color: Theme.of(context).unselectedWidgetColor,
            ),
          ),
          TextSpan(
            text: result.searchTerm.trim().replaceAll('\n', ' '),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
