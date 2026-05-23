import 'package:flutter/material.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:material_floating_search_bar/material_floating_search_bar.dart';
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

  final ScrollController _scrollController = ScrollController();
  List<String> _searchSuggestions = [];

  /// Search delay upon submit.
  Duration get searchDelay;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FloatingSearchBar(
      isScrollControlled: true,
      hint: mediaSource.getLocalisedSourceName(appModel),
      controller: mediaType.floatingSearchBarController,
      onSubmitted: onSubmitted,
      onQueryChanged: onQueryChanged,
      builder: buildFloatingSearchBody,
      borderRadius: BorderRadius.zero,
      elevation: 0,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      backdropColor: Colors.transparent,
      accentColor: theme.colorScheme.primary,
      scrollPadding: const EdgeInsets.only(top: 6, bottom: 56),
      transitionDuration: Duration.zero,
      margins: const EdgeInsets.symmetric(horizontal: 6),
      progress: _isSearching,
      width: double.maxFinite,
      transition: SlideFadeFloatingSearchBarTransition(),
      automaticallyImplyBackButton: false,
      onFocusChanged: (focused) => onFocusChanged(focused: focused),
      leadingActions: [
        buildChangeSourceButton(),
        buildBackButton(),
      ],
      actions: [
        buildSearchClearButton(),
        ...mediaSource.getActions(
          context: context,
          ref: ref,
          appModel: appModel,
        ),
        buildSearchButton(),
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
        searchTerm: mediaType.floatingSearchBarController.query,
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

  /// Changes between search and clear when focused.
  Widget buildSearchButton() {
    return FloatingSearchBarAction.searchToClear(
      color: theme.appBarTheme.foregroundColor,
      size: textTheme.titleLarge!.fontSize!,
      searchButtonSemanticLabel: t.search,
      clearButtonSemanticLabel: t.clear,
    );
  }

  /// Shows when the user has focused the search bar.
  Widget buildSearchClearButton() {
    return FloatingSearchBarAction(
      showIfOpened: true,
      showIfClosed: false,
      child: HibikiIconButton(
        size: textTheme.titleLarge?.fontSize,
        tooltip: t.clear_search_title,
        icon: Icons.manage_search_outlined,
        onTap: showDeleteSearchHistoryPrompt,
      ),
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
            mediaType.floatingSearchBarController.clear();

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
  Widget buildFloatingSearchBody(
    BuildContext context,
    Animation<double> transition,
  ) {
    String query = mediaType.floatingSearchBarController.query.trim();

    if (query.isEmpty) {
      List<String> searchHistory =
          appModel.getSearchHistory(historyKey: mediaSource.uniqueKey);

      if (searchHistory.isEmpty) {
        return buildEnterSearchTermPlaceholderMessage();
      } else {
        return HibikiSearchHistory(
          uniqueKey: mediaSource.uniqueKey,
          onSearchTermSelect: (searchTerm) {
            setState(() {
              mediaType.floatingSearchBarController.query = searchTerm;
            });
          },
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
        onSearchTermSelect: (searchTerm) {
          setState(() {
            mediaType.floatingSearchBarController.query = searchTerm;
          });
        },
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
}
