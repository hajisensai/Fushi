part of '../reader_fushi_page.dart';

/// The reader page as the dual-screen companion sees it
/// ([ReaderCompanionHook]). Every getter reads in-memory page state; commands
/// reuse the page's own executors (the desktop remote's page turn / percent
/// jump, the TOC jump, the bookmark panel's add / jump, the audiobook
/// controller). Works the same in paginated, continuous and vn view modes:
/// none of it depends on how the chapter is laid out.
class _ReaderCompanionPageAdapter implements ReaderCompanionPage {
  _ReaderCompanionPageAdapter(this._state);

  final _ReaderFushiPageState _state;

  @override
  bool get mounted => _state.mounted;

  @override
  String? get bookTitle => _state.mounted ? _state._book?.title : null;

  @override
  bool get audiobookView => _state._lyricsMode && _state._hasActiveAudiobook;

  @override
  Map<String, Object?> readerState() {
    final _ReaderFushiPageState s = _state;
    final EpubBook book = s._book!;
    final ReaderSessionSnapshot? snap = s._sessionRemote.snapshot();
    final List<TtuTocEntry> toc = s._buildTtuToc();
    final int? current = resolveCurrentTocEntry(
      toc,
      s._currentChapter,
      s._tocCharOffsetFor(s._currentChapter),
    );
    final AudiobookPlayerController? audio = s._audiobookController;
    return <String, Object?>{
      ReaderCompanionKeys.chapterTitle: s._currentChapterLabel(),
      ReaderCompanionKeys.chapterIndex: s._currentChapter,
      ReaderCompanionKeys.chapterCount: book.chapters.length,
      ReaderCompanionKeys.percent: snap?.bookPercent,
      ReaderCompanionKeys.toc: <Map<String, Object?>>[
        for (final TtuTocEntry e in toc.take(ReaderCompanionKeys.maxToc))
          <String, Object?>{
            ReaderCompanionKeys.tocLabel: e.label,
            ReaderCompanionKeys.tocDepth: e.depth,
          },
      ],
      ReaderCompanionKeys.tocCurrent: current ?? -1,
      ReaderCompanionKeys.hasAudio: s._hasActiveAudiobook,
      ReaderCompanionKeys.playing: audio?.isPlaying ?? false,
    };
  }

  @override
  Map<String, Object?> audiobookState() {
    final _ReaderFushiPageState s = _state;
    final AudiobookPlayerController? audio = s._audiobookController;
    final List<AudioCue> cues =
        audio?.chapterCuesSnapshot ?? const <AudioCue>[];
    final int current = audio?.currentCueIdx ?? -1;
    final int center = current < 0 ? 0 : current;
    const int radius = AudiobookCompanionKeys.lineRadius;
    final int from = math.max(0, center - radius);
    final int to = math.min(cues.length, center + radius + 1);
    return <String, Object?>{
      AudiobookCompanionKeys.chapterTitle: s._currentChapterLabel(),
      AudiobookCompanionKeys.chapterIndex: s._currentChapter,
      AudiobookCompanionKeys.chapterCount: s._book?.chapters.length ?? 0,
      AudiobookCompanionKeys.playing: audio?.isPlaying ?? false,
      AudiobookCompanionKeys.speed: audio?.speed ?? 1.0,
      AudiobookCompanionKeys.positionMs:
          audio?.globalPosition.inMilliseconds ?? 0,
      AudiobookCompanionKeys.durationMs:
          audio?.totalDuration.inMilliseconds ?? 0,
      AudiobookCompanionKeys.current: current,
      AudiobookCompanionKeys.lines: <Map<String, Object?>>[
        for (int i = from; i < to; i++)
          <String, Object?>{
            AudiobookCompanionKeys.lineIndex: i,
            AudiobookCompanionKeys.lineText: cues[i].text,
          },
      ],
    };
  }

  @override
  Future<ReaderCompanionBookInfo> loadBookInfo() async {
    final EpubBook? book = _state._book;
    final String? extractDir = _state._extractDir;
    final String? author = book?.author?.trim();
    final String? series = book?.series?.name.trim();
    return ReaderCompanionBookInfo(
      author: author == null || author.isEmpty ? null : author,
      series: series == null || series.isEmpty ? null : series,
      seriesIndex: series == null || series.isEmpty
          ? null
          : book?.series?.index,
      cover: extractDir == null
          ? null
          : ReaderFushiSource.resolveCoverFilePath(
              extractDir: extractDir,
              coverPath: book?.coverHref,
            ),
    );
  }

  @override
  bool get bookmarksEnabled => _state._bookUid != null;

  @override
  Future<List<ReaderCompanionBookmark>> loadBookmarks() async {
    final List<Bookmark> rows = await _state._bookmarksForBook();
    return <ReaderCompanionBookmark>[
      for (final Bookmark b in rows)
        if (b.id != null)
          (id: b.id!, label: b.label, chapter: b.sectionIndex + 1),
    ];
  }

  @override
  Stream<void>? bookmarkChanges() {
    final FushiDatabase db = _state.appModel.database;
    return db
        .tableUpdates(TableUpdateQuery.onTable(db.bookmarks))
        .map((Set<TableUpdate> _) {});
  }

  @override
  Future<ReaderCompanionStats?> loadStats() async {
    final ReaderBookStatTotals totals = await _state
        ._loadReaderBookStatTotals();
    return (
      todayMs: totals.todayMs,
      todayChars: totals.todayChars,
      todayLookups: totals.todayLookups,
      todayCards: totals.todayCards,
      allMs: totals.allMs,
      allChars: totals.allChars,
    );
  }

  @override
  Future<void> runReaderCommand(
    String action,
    Map<String, Object?> args,
  ) async {
    final _ReaderFushiPageState s = _state;
    if (s._book == null) return;
    switch (action) {
      case ReaderCompanionActions.turnPage:
        await s._sessionRemote.turnPage(
          forward: args[ReaderCompanionActions.forward] != false,
        );
      case ReaderCompanionActions.seekPercent:
        final double? percent = args.doubleOrNull(
          ReaderCompanionActions.percent,
        );
        if (percent != null) await s._sessionRemote.goToBookPercent(percent);
      case ReaderCompanionActions.goToToc:
        final int? i = args.intOrNull(ReaderCompanionActions.index);
        final List<TtuTocEntry> toc = s._buildTtuToc();
        if (i != null && i >= 0 && i < toc.length) {
          await s._jumpToChapterAnchor(
            toc[i].index,
            toc[i].fragment,
            source: JumpSource.tableOfContents,
          );
        }
      case ReaderCompanionActions.playPause:
        await s._audiobookController?.togglePlayPause();
      case ReaderCompanionActions.addBookmark:
        if (s._bookUid == null) return;
        final Bookmark? added = await s._addBookmarkAtCurrentPosition();
        if (added != null) {
          FushiToast.show(msg: t.second_screen_reader_bookmark_added);
        }
      case ReaderCompanionActions.jumpToBookmark:
        final int? id = args.intOrNull(ReaderCompanionActions.id);
        if (id == null) return;
        final List<Bookmark> rows = await s._bookmarksForBook();
        for (final Bookmark b in rows) {
          if (b.id == id) {
            await s._jumpToBookmark(b);
            return;
          }
        }
    }
  }

  @override
  Future<void> runAudiobookCommand(
    String action,
    Map<String, Object?> args,
  ) async {
    final _ReaderFushiPageState s = _state;
    final AudiobookPlayerController? audio = s._audiobookController;
    if (audio == null) return;
    await runAudiobookCompanionCommand(
      audio,
      action,
      args,
      boundarySkip: s._handleBoundarySkip,
    );
  }

  /// The page's own counter ([BaseSourcePageState.recordCompanionLookup]:
  /// per-book identity, skips source review), so companion lookups count for
  /// this book.
  @override
  void countLookup() {
    if (_state.mounted) _state.recordCompanionLookup();
  }
}
