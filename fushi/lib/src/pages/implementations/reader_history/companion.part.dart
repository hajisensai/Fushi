part of '../reader_fushi_history_page.dart';

/// Dual-screen companion, Library tab Main mode (S5): the books shelf and the
/// manga library publish the card highlighted on top and run the panel's
/// search / sort / read-status filter on this page's own state
/// ([LibraryCompanionHook] owns the claim and the throttled snapshot).
///
/// Highlight: the focused card (its focus id embeds the item), else the card
/// whose long-press menu is open, else the selection anchor. Remote
/// placeholders (not in the library yet) are never highlighted.
extension _ShelfCompanion on _ReaderFushiHistoryPageState {
  static const String _bookPrefix = 'reader-shelf-book-';
  static const String _srtPrefix = 'reader-shelf-srt-';
  static const String _collectionPrefix = 'reader-shelf-collection-';
  static const String _heroId = 'reader-shelf-continue-hero';

  LibraryCompanionHook _createShelfCompanion() => LibraryCompanionHook(
    library: _mangaOnly
        ? CompanionLibraryKind.manga
        : CompanionLibraryKind.books,
    snapshot: _shelfCompanionSnapshot,
    onSearch: _companionSearch,
    onSort: (String id) {
      for (final ShelfSortMode mode in ShelfSortMode.values) {
        if (mode.name == id) _setSortMode(mode);
      }
    },
    onFilter: (String id, bool selected) {
      final ShelfReadStatus? status = ShelfReadStatus.values.asNameMap()[id];
      if (status == null) return;
      if (selected) {
        _setReadStatusFilter(status);
      } else if (_readStatusFilter == status) {
        _setReadStatusFilter(null);
      }
    },
    onOpenHighlighted: () => _shelfCompanionHighlight()?.open(),
  );

  /// The panel's search: the same query state as the page's own search
  /// field (the header shows its "query active" dot while collapsed; it is
  /// not expanded, which would take the controller focus off the cards).
  void _companionSearch(String query) {
    if (_searchController.text != query) _searchController.text = query;
    _rebuild(() => _searchQuery = query);
  }

  /// Runs [menu] (a card's long-press menu) with its card highlighted on
  /// the companion while the menu is open.
  Future<void> _companionPressed(
    FushiFocusId id,
    Future<void> Function() menu,
  ) async {
    _companionPressedId = id;
    _companion.publishSoon();
    try {
      await menu();
    } finally {
      if (_companionPressedId == id) _companionPressedId = null;
      if (mounted) _companion.publishSoon();
    }
  }

  CompanionLibraryMainSnapshot _shelfCompanionSnapshot() =>
      CompanionLibraryMainSnapshot(
        highlighted: _shelfCompanionHighlight()?.item,
        query: _searchQuery,
        sorts: libraryCompanionOptions<ShelfSortMode>(
          values: ShelfSortMode.values,
          id: (ShelfSortMode m) => m.name,
          label: _sortModeLabel,
          selected: (ShelfSortMode m) => m == _sortMode,
        ),
        filters: libraryCompanionOptions<ShelfReadStatus>(
          values: ShelfReadStatus.values,
          id: (ShelfReadStatus s) => s.name,
          label: _readStatusLabel,
          selected: (ShelfReadStatus s) => s == _readStatusFilter,
        ),
      );

  LibraryCompanionHighlight? _shelfCompanionHighlight() {
    final FushiFocusController? focus = FushiFocusRoot.maybeControllerOf(
      context,
    );
    return pickLibraryCompanionHighlight(
      focused: () => focus != null && focus.primaryFocusIsManagedTarget
          ? _shelfHighlightFor(focus.activeId?.value)
          : null,
      pressed: () => _shelfHighlightFor(_companionPressedId?.value),
      selected: () {
        final SelectionSlot? anchor = _selection.anchor;
        if (!_selectionMode || anchor == null) return null;
        final int? cid = anchor.collectionId;
        if (cid != null) {
          return _selectedCollectionIds.contains(cid)
              ? _shelfHighlightFor('$_collectionPrefix$cid')
              : null;
        }
        final String? key = anchor.looseKey;
        if (key == null || !_selectedKeys.contains(key)) return null;
        return key.startsWith('srt_')
            ? _shelfHighlightFor('$_srtPrefix${key.substring(4)}')
            : _shelfHighlightFor('$_bookPrefix$key');
      },
    );
  }

  LibraryCompanionHighlight? _shelfHighlightFor(String? id) {
    if (id == null) return null;
    if (id == _heroId) {
      final MediaItem? hero = _companionHero;
      if (hero == null) return null;
      return LibraryCompanionHighlight(
        item: _companionEpubItem(hero),
        open: () => unawaited(
          appModel.openMedia(
            ref: ref,
            mediaSource: hero.getMediaSource(appModel: appModel),
            item: hero,
          ),
        ),
      );
    }
    final String? book = libraryCompanionFocusKey(id, _bookPrefix);
    if (book != null) {
      for (final MediaItem item in _visibleEpubBooks) {
        if (item.mediaIdentifier != book) continue;
        return LibraryCompanionHighlight(
          item: _companionEpubItem(item),
          open: () => unawaited(_openEpubCard(item)),
        );
      }
      return null;
    }
    final String? srt = libraryCompanionFocusKey(id, _srtPrefix);
    if (srt != null) {
      for (final SrtBook b in _visibleSrtBooks) {
        if (b.uid != srt) continue;
        return LibraryCompanionHighlight(
          item: _companionSrtItem(b),
          open: () => unawaited(_openSrtBook(b)),
        );
      }
      return null;
    }
    final int? cid = int.tryParse(
      libraryCompanionFocusKey(id, _collectionPrefix) ?? '',
    );
    final MediaCollectionRow? collection = cid == null
        ? null
        : _collectionsById[cid];
    if (collection == null || !_visibleCollectionIds.contains(cid)) {
      return null;
    }
    return LibraryCompanionHighlight(
      item: CompanionLibraryItem(
        ref: CompanionLibraryRef.collection(
          _mangaOnly
              ? CompanionLibrarySection.manga
              : CompanionLibrarySection.books,
          '${collection.id}',
        ),
        kind: CompanionLibraryItemKind.collection,
        title: collection.name,
      ),
      open: () => _openCollectionDetail(collection),
    );
  }

  CompanionLibraryItem _companionEpubItem(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final bool completed =
        bookKey != null && _completedBookKeys.contains(bookKey);
    final double fraction = _itemReadFraction(item, completed: completed);
    final bool manga = _isMangaItem(item);
    return CompanionLibraryItem(
      ref: manga
          ? CompanionLibraryRef.manga(item.mediaIdentifier)
          : CompanionLibraryRef.book(item.mediaIdentifier),
      kind: manga
          ? CompanionLibraryItemKind.manga
          : CompanionLibraryItemKind.book,
      title: mediaSource.getDisplayTitleFromMediaItem(item),
      subtitle: _companionText(item.author),
      progress: completed || fraction <= 0 ? null : fraction,
      progressLabel: completed || fraction <= 0
          ? null
          : _readProgressLabel(fraction),
      finished: completed,
      coverPath: _companionCover(item),
    );
  }

  CompanionLibraryItem _companionSrtItem(SrtBook book) {
    final MediaItem srtItem = _srtBookMediaItem(book);
    final bool completed =
        book.bookKey.isNotEmpty && _completedBookKeys.contains(book.bookKey);
    final double fraction = _srtBookHasProgress(book)
        ? _itemReadFraction(srtItem, completed: completed)
        : 0;
    return CompanionLibraryItem(
      ref: CompanionLibraryRef.audiobook(
        book.bookKey.isNotEmpty
            ? ReaderFushiSource.mediaIdentifierFor(book.bookKey)
            : ReaderFushiSource.mediaIdentifierForSrtUid(book.uid),
      ),
      kind: CompanionLibraryItemKind.audiobook,
      title: mediaSource.getDisplayTitleFromMediaItem(srtItem),
      subtitle: _companionText(book.author),
      progress: completed || fraction <= 0 ? null : fraction,
      progressLabel: completed || fraction <= 0
          ? null
          : _readProgressLabel(fraction),
      finished: completed,
      coverPath: _companionCover(srtItem),
    );
  }

  /// The cover file of [item], probed once per highlighted item (covers may
  /// sit on a network drive, BUG-3756).
  String? _companionCover(MediaItem item) {
    if (_companionCoverKey != item.mediaIdentifier) {
      _companionCoverKey = item.mediaIdentifier;
      _companionCoverPath = companionCoverFilePath(
        override: () => item
            .getMediaSource(appModel: appModel)
            .resolveOverrideThumbnailFile(appModel: appModel, item: item),
        imageUrl: item.imageUrl,
      );
    }
    return _companionCoverPath.isEmpty ? null : _companionCoverPath;
  }

  static String? _companionText(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
