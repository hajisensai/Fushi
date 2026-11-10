part of '../home_video_page.dart';

/// Dual-screen companion, Library tab Main mode (S5): the local video library
/// (home / series / all videos sections) publishes the card highlighted on
/// top and runs the panel's search / sort / watch-status filter on this
/// page's own state ([LibraryCompanionHook] owns the claim and the throttled
/// snapshot). The home section has no search, sort or filters on top, so it
/// publishes none.
///
/// Highlight: the focused card (its focus id embeds the video / collection),
/// else the video whose menu is open, else the selection anchor. Remote
/// placeholders are never highlighted. Continue on a focused card activates
/// that card (exactly what Enter does on top).
extension _VideoCompanion on _HomeVideoPageState {
  static const String _prefix = 'home-video-';
  static const List<String> _collectionPrefixes = <String>[
    'continue-collection-',
    'recent-collection-',
    'subscription-collection-',
    'collection-',
  ];
  static const List<String> _remotePrefixes = <String>[
    'continue-remote-',
    'recent-remote-',
    'remote-list-',
    'remote-',
  ];
  static const List<String> _videoPrefixes = <String>[
    'continue-',
    'recent-',
    'list-',
  ];

  bool get _companionHasTools => widget.section != VideoLibrarySection.home;

  LibraryCompanionHook _createVideoCompanion() => LibraryCompanionHook(
    library: CompanionLibraryKind.video,
    snapshot: _videoCompanionSnapshot,
    onSearch: (String query) {
      if (!_companionHasTools) return;
      if (_searchController.text != query) _searchController.text = query;
      _rebuild(() => _searchQuery = query);
    },
    onSort: (String id) {
      if (!_companionHasTools) return;
      for (final ShelfSortMode mode in ShelfSortMode.values) {
        if (mode.name == id) _setSortMode(mode);
      }
    },
    onFilter: (String id, bool selected) {
      if (!_companionHasTools) return;
      final VideoWatchStatusFilter? filter = VideoWatchStatusFilter.values
          .asNameMap()[id];
      if (filter == null || filter == VideoWatchStatusFilter.all) return;
      if (selected) {
        _rebuild(() => _watchStatusFilter = filter);
      } else if (_watchStatusFilter == filter) {
        _rebuild(() => _watchStatusFilter = VideoWatchStatusFilter.all);
      }
    },
    onOpenHighlighted: () => _videoCompanionHighlight()?.open(),
  );

  /// Highlights [book] on the companion while its menu ([menu]) is open.
  void _companionTrackMenu(VideoBookRow book, Future<void> menu) {
    final FushiFocusId id = FushiFocusId('$_prefix${book.bookUid}');
    _companionPressedId = id;
    _companion.publishSoon();
    unawaited(
      menu.whenComplete(() {
        if (_companionPressedId == id) _companionPressedId = null;
        if (mounted) _companion.publishSoon();
      }),
    );
  }

  CompanionLibraryMainSnapshot _videoCompanionSnapshot() {
    final bool tools = _companionHasTools;
    return CompanionLibraryMainSnapshot(
      highlighted: _videoCompanionHighlight()?.item,
      query: tools ? _searchQuery : '',
      searchable: tools,
      sorts: tools
          ? libraryCompanionOptions<ShelfSortMode>(
              values: ShelfSortMode.values,
              id: (ShelfSortMode m) => m.name,
              label: _sortModeLabel,
              selected: (ShelfSortMode m) => m == _sortMode,
            )
          : const <CompanionLibraryOption>[],
      filters: tools
          ? libraryCompanionOptions<VideoWatchStatusFilter>(
              values: <VideoWatchStatusFilter>[
                for (final VideoWatchStatusFilter f
                    in VideoWatchStatusFilter.values)
                  if (f != VideoWatchStatusFilter.all) f,
              ],
              id: (VideoWatchStatusFilter f) => f.name,
              label: _watchStatusFilterLabel,
              selected: (VideoWatchStatusFilter f) => f == _watchStatusFilter,
            )
          : const <CompanionLibraryOption>[],
    );
  }

  LibraryCompanionHighlight? _videoCompanionHighlight() {
    final FushiFocusController? focus = FushiFocusRoot.maybeControllerOf(
      context,
    );
    return pickLibraryCompanionHighlight(
      focused: () {
        if (focus == null || !focus.primaryFocusIsManagedTarget) return null;
        final CompanionLibraryItem? item = _videoCompanionItemFor(
          focus.activeId?.value,
        );
        return item == null
            ? null
            : LibraryCompanionHighlight(
                item: item,
                open: activateLibraryCompanionFocus,
              );
      },
      pressed: () => _videoCompanionExplicit(_companionPressedId?.value),
      selected: () {
        final SelectionSlot? anchor = _selection.anchor;
        if (!_selectionMode || anchor == null) return null;
        final int? cid = anchor.collectionId;
        if (cid != null) {
          return _selectedCollectionIds.contains(cid)
              ? _videoCompanionExplicit('${_prefix}collection-$cid')
              : null;
        }
        final String? uid = anchor.looseKey;
        return uid != null && _selectedUids.contains(uid)
            ? _videoCompanionExplicit('$_prefix$uid')
            : null;
      },
    );
  }

  /// A highlight that is not focused: Continue runs the card's open action.
  LibraryCompanionHighlight? _videoCompanionExplicit(String? id) {
    final CompanionLibraryItem? item = _videoCompanionItemFor(id);
    if (item == null) return null;
    final String key = CompanionLibraryRef.keyOf(item.ref);
    if (item.kind == CompanionLibraryItemKind.collection) {
      final MediaCollectionRow? collection =
          _collectionsById[int.tryParse(key.substring(key.indexOf('/') + 1))];
      if (collection == null) return null;
      return LibraryCompanionHighlight(
        item: item,
        open: () => _openCollectionDetail(collection),
      );
    }
    final VideoBookRow? book = _companionVideo(key);
    if (book == null) return null;
    return LibraryCompanionHighlight(
      item: item,
      open: () => unawaited(_open(book)),
    );
  }

  CompanionLibraryItem? _videoCompanionItemFor(String? id) {
    final String? rest = libraryCompanionFocusKey(id, _prefix);
    if (rest == null) return null;
    for (final String p in _collectionPrefixes) {
      final int? cid = int.tryParse(libraryCompanionFocusKey(rest, p) ?? '');
      if (cid == null) continue;
      final MediaCollectionRow? collection = _collectionsById[cid];
      if (collection == null) return null;
      return CompanionLibraryItem(
        ref: CompanionLibraryRef.collection(
          CompanionLibrarySection.video,
          '${collection.id}',
        ),
        kind: CompanionLibraryItemKind.collection,
        title: _workTitle(collection),
      );
    }
    for (final String p in _remotePrefixes) {
      if (rest.startsWith(p)) return null;
    }
    String uid = rest;
    for (final String p in _videoPrefixes) {
      final String? key = libraryCompanionFocusKey(rest, p);
      if (key != null) {
        uid = key;
        break;
      }
    }
    final VideoBookRow? book = _companionVideo(uid);
    return book == null ? null : _companionVideoItem(book);
  }

  VideoBookRow? _companionVideo(String uid) {
    for (final VideoBookRow b in _videosCache ?? const <VideoBookRow>[]) {
      if (b.bookUid == uid) return b;
    }
    return null;
  }

  CompanionLibraryItem _companionVideoItem(VideoBookRow book) {
    final bool done = book.completedAt != null;
    final int episodes = playlistEpisodeCount(book.playlistJson);
    final double? fraction = done
        ? null
        : episodes > 1
        ? videoWatchFraction(
            completed: false,
            currentEpisode: book.currentEpisode,
            episodeCount: episodes,
          )
        : _bookPositionFraction(book);
    final bool started = fraction != null && fraction > 0;
    final String? cover = book.coverPath;
    return CompanionLibraryItem(
      ref: CompanionLibraryRef.video(book.bookUid),
      kind: CompanionLibraryItemKind.video,
      title: _metadataWorkByBook[book.bookUid]?.title ?? book.title,
      progress: started ? fraction : null,
      progressLabel: !started
          ? null
          : episodes > 1
          ? t.second_screen_library_data_progress_episode(
              n: book.currentEpisode + 1,
            )
          : t.second_screen_library_data_progress_percent(
              n: (fraction * 100).round(),
            ),
      finished: done,
      coverPath: cover == null || cover.isEmpty ? null : cover,
    );
  }
}
