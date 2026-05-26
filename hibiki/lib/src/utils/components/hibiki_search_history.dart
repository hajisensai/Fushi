import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// Used in a floating search bar body for showing search history items for
/// a certain collection named [uniqueKey].
class HibikiSearchHistory extends ConsumerStatefulWidget {
  /// Create an instance of this widget.
  const HibikiSearchHistory({
    required this.uniqueKey,
    required this.onSearchTermSelect,
    required this.onUpdate,
    this.searchSuggestions = const [],
    super.key,
  });

  /// The name of the collection that will be displayed.
  final String uniqueKey;

  /// An action that will be performed upon selecting a search term.
  final Function(String) onSearchTermSelect;

  /// An action that will be performed upon deleting a search term.
  final Function() onUpdate;

  /// This overrides the history display and shows search suggestions
  /// instead if non-null.
  final List<String> searchSuggestions;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _HibikiSearchHistoryState();
}

class _HibikiSearchHistoryState extends ConsumerState<HibikiSearchHistory> {
  AppModel get appModel => ref.watch(appProvider);

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    late List<String> searchHistory;
    if (widget.searchSuggestions.isNotEmpty) {
      searchHistory = widget.searchSuggestions;
    } else {
      searchHistory = appModel
          .getSearchHistory(historyKey: widget.uniqueKey)
          .reversed
          .toList();
    }

    return ClipRRect(
      child: Material(
        color: Colors.transparent,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          itemCount: searchHistory.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return SizedBox(height: tokens.spacing.gap * 2);
            }

            return buildSearchHistoryItem(
              uniqueKey: widget.uniqueKey,
              searchTerm: searchHistory[index - 1],
              onSearchTermSelect: widget.onSearchTermSelect,
            );
          },
        ),
      ),
    );
  }

  Widget buildSearchHistoryItem({
    required String uniqueKey,
    required String searchTerm,
    required Function(String) onSearchTermSelect,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return GestureDetector(
      onLongPress: () {
        if (widget.searchSuggestions.isNotEmpty) {
          return;
        }

        appModel.removeFromSearchHistory(
          historyKey: uniqueKey,
          searchTerm: searchTerm,
        );
        setState(() {});
        widget.onUpdate();
      },
      child: HibikiListItem(
        leading: Icon(
          widget.searchSuggestions.isNotEmpty
              ? Icons.search
              : Icons.youtube_searched_for_outlined,
        ),
        title: Text(searchTerm),
        titleMaxLines: 1,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.page,
          vertical: tokens.spacing.rowVertical + 2,
        ),
        onTap: () => onSearchTermSelect(searchTerm),
      ),
    );
  }
}
