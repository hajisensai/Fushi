import 'package:flutter/material.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The search bar used for the home page when a certain source is enabled.
abstract class BaseMediaSearchBar extends BaseTabPage {
  /// Create an instance of this bar.
  const BaseMediaSearchBar({super.key});
}

/// State for [BaseMediaSearchBar].
abstract class BaseMediaSearchBarState<T extends BaseMediaSearchBar>
    extends BaseTabPageState {
  /// The paging controller which holds the media items for the search.
  PagingController<int, MediaItem>? pagingController;

  bool _isSearching = false;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  List<String> _searchSuggestions = [];

  /// Search delay upon submit.
  Duration get searchDelay;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChanged);
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    onFocusChanged(focused: _searchFocusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: <Widget>[
                buildChangeSourceButton(),
                if (_searchFocusNode.hasFocus ||
                    _searchController.text.isNotEmpty)
                  buildBackButton(onTap: _clearSearch),
                Expanded(
                  child: HibikiSearchField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    hintText: mediaSource.getLocalisedSourceName(appModel),
                    onChanged: onQueryChanged,
                    onSubmitted: onSubmitted,
                  ),
                ),
                buildSearchClearButton(),
                ...mediaSource.getActions(
                  context: context,
                  ref: ref,
                  appModel: appModel,
                ),
                buildSearchButton(),
              ],
            ),
          ),
        ),
        if (_isSearching) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: buildSearchBody(context)),
      ],
    );
  }

  /// Called when the user has submitted the search query.
  void onSubmitted(String query) async {
    query = query.trim();

    if (!_isSearching) {
      pagingController = null;

      setState(() {
        _isSearching = true;
      });

      pagingController = PagingController(firstPageKey: 1);
      try {
        List<MediaItem>? newItems = await mediaSource.searchMediaItems(
          context: context,
          searchTerm: query,
          pageKey: 1,
        );
        if (newItems != null && newItems.isNotEmpty) {
          pagingController?.appendPage(newItems, 2);
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('MediaSearchBar.initialSearch', e, stack);
        pagingController?.appendLastPage([]);
      }
      pagingController?.addPageRequestListener((pageKey) async {
        try {
          List<MediaItem>? newItems = await mediaSource.searchMediaItems(
            context: context,
            searchTerm: query,
            pageKey: pageKey,
          );
          if (newItems != null && newItems.isNotEmpty) {
            pagingController?.appendPage(newItems, pageKey);
          }
        } catch (e, stack) {
          ErrorLogService.instance.log('MediaSearchBar.pageSearch', e, stack);
          pagingController?.appendLastPage([]);
        }
      });
      appModel.addToSearchHistory(
        historyKey: mediaSource.uniqueKey,
        searchTerm: _searchController.text,
      );

      setState(() {
        _isSearching = false;
      });
    }
  }

  /// Called when the search bar query has changed.
  void onQueryChanged(String query) async {
    query = query.trim();
    pagingController = null;

    if (query.isEmpty) {
      _searchSuggestions = [];
      _isSearching = false;
      setState(() {});
      return;
    }

    mediaSource.generateSearchSuggestions(query).then((newSuggestions) {
      _searchSuggestions = newSuggestions;
      setState(() {});
    });
  }

  /// Clear button that only clears text without closing the search bar.
  Widget buildSearchButton() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _searchController,
      builder: (context, value, _) {
        if (value.text.isEmpty) return const SizedBox.shrink();
        return HibikiIconButton(
          size: textTheme.titleLarge?.fontSize,
          tooltip: t.clear,
          icon: Icons.close,
          onTap: () {
            _searchController.clear();
            onQueryChanged('');
            _searchFocusNode.requestFocus();
          },
        );
      },
    );
  }

  /// Shows when the user has focused the search bar.
  Widget buildSearchClearButton() {
    return HibikiIconButton(
      size: textTheme.titleLarge?.fontSize,
      tooltip: t.clear_search_title,
      icon: Icons.manage_search_outlined,
      onTap: showDeleteSearchHistoryPrompt,
    );
  }

  /// Shows when the clear search history is shown.
  void showDeleteSearchHistoryPrompt() async {
    Widget alertDialog = adaptiveAlertDialog(
      context: context,
      title: Text(t.clear_search_title),
      content: Text(
        t.clear_search_description,
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          child: Text(
            t.dialog_clear,
          ),
          onPressed: () async {
            appModel.clearSearchHistory(historyKey: mediaSource.uniqueKey);
            _searchController.clear();

            setState(() {});
            Navigator.pop(context);
          },
        ),
        adaptiveDialogAction(
          context: context,
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

  /// Shows when the user taps on the floating search bar.
  Widget buildSearchBody(BuildContext context) {
    String query = _searchController.text.trim();

    if (query.isEmpty) {
      List<String> searchHistory =
          appModel.getSearchHistory(historyKey: mediaSource.uniqueKey);

      if (searchHistory.isEmpty) {
        return buildEnterSearchTermPlaceholderMessage();
      } else {
        return HibikiSearchHistory(
          uniqueKey: mediaSource.uniqueKey,
          onSearchTermSelect: _selectSearchTerm,
          onUpdate: () {
            setState(() {});
          },
        );
      }
    }

    if (_isSearching || pagingController == null) {
      return HibikiSearchHistory(
        uniqueKey: mediaSource.uniqueKey,
        searchSuggestions: _searchSuggestions,
        onSearchTermSelect: _selectSearchTerm,
        onUpdate: () {
          setState(() {});
        },
      );
    }

    if (pagingController!.itemList != null) {
      return RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: _scrollController,
        child: buildResultList(),
      );
    }

    return buildNoSearchResultsPlaceholderMessage();
  }

  /// Shows when there are proper search results returned.
  Widget buildResultList() {
    throw UnimplementedError();
  }

  /// Shows when the search term is empty and there is nothing in search history.
  Widget buildEnterSearchTermPlaceholderMessage() {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.search,
        message: t.enter_search_term,
      ),
    );
  }

  /// Shows when the media item search has returned no items.
  Widget buildNoSearchResultsPlaceholderMessage() {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.search_off,
        message: t.no_search_results,
      ),
    );
  }

  void _clearSearch() {
    _searchController.clear();
    onQueryChanged('');
    _searchFocusNode.unfocus();
  }

  void _selectSearchTerm(String searchTerm) {
    setState(() {
      _searchController.text = searchTerm;
      _searchController.selection = TextSelection.collapsed(
        offset: searchTerm.length,
      );
    });
    onQueryChanged(searchTerm);
    _searchFocusNode.requestFocus();
  }
}
