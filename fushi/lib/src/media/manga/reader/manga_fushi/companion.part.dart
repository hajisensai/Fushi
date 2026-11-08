part of '../manga_fushi_page.dart';

/// Dual-screen companion: the manga reader's side ([MangaCompanionHook]).
/// Nothing here runs while the companion is not up (the hook's link builds
/// snapshots only while active; lookups fall back to the in-page popup).
class _MangaCompanionReader implements MangaCompanionReader {
  _MangaCompanionReader(this._state);

  final _MangaFushiPageState _state;

  @override
  MangaCompanionReadState? readState() => _state._companionReadState();

  @override
  void previousPage() => _state._executeReaderInputAction(
    MangaReaderInputAction.previous,
    source: _MangaReaderInputSource.remote,
  );

  @override
  void nextPage() => _state._executeReaderInputAction(
    MangaReaderInputAction.next,
    source: _MangaReaderInputSource.remote,
  );

  @override
  void previousChapter() =>
      unawaited(_state._goToAdjacentChapter(forward: false));

  @override
  void nextChapter() => unawaited(_state._goToAdjacentChapter(forward: true));

  @override
  void goToChapter(int index) => unawaited(_state._companionGoToChapter(index));

  @override
  Future<MangaCompanionOcrOutcome> recognizePage(int page) =>
      _state._companionRecognizePage(page);
}

extension _MangaCompanion on _MangaFushiPageState {
  /// Claims the manga context with the current title (the hook skips
  /// repeats). Called from didChangeDependencies and after a chapter loads.
  void _syncCompanionClaim() {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    final String title = entry != null && _shelfChapterIndex >= 0
        ? entry.series.title
        : (_bookRow?.title ?? '');
    _companion.claim(title, route: ModalRoute.of(context));
  }

  MangaCompanionReadState? _companionReadState() {
    final MokuroPayload? payload = _payload;
    if (!mounted || payload == null || payload.images.isEmpty) return null;
    final int page = _currentPage.clamp(0, payload.images.length - 1);
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    final bool online =
        entry != null &&
        _shelfChapterIndex >= 0 &&
        _shelfChapterIndex < entry.chapters.length;
    final OnlineMangaSeries? series = online ? entry.series : null;
    return MangaCompanionReadState(
      title: series?.title ?? _bookRow?.title ?? _chromeTitle,
      pageKey: '$_pageSessionGeneration/$page',
      page: page,
      pageCount: payload.images.length,
      chapter: online ? _chromeTitle : null,
      author: series?.byline ?? _bookRow?.author,
      description: series?.description,
      genres: series?.genreLabels ?? const <String>[],
      rtl: _spreadDirection == 'rtl',
      chapterNames: online
          ? <String>[
              for (final OnlineMangaChapter chapter in entry.chapters)
                mangaChapterDisplayName(chapter),
            ]
          : const <String>[],
      currentChapterIndex: online ? _shelfChapterIndex : -1,
      pageTexts: <String>[
        for (final MokuroBlock block in payload.images[page].blocks)
          block.lines.join(),
      ],
      readerOcrBusy: _wholeVolumeOcrRunning || _streamOcrBusy,
    );
  }

  Future<void> _companionGoToChapter(int index) async {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    if (!mounted ||
        entry == null ||
        _switchingChapter ||
        index < 0 ||
        index >= entry.chapters.length ||
        index == _shelfChapterIndex) {
      return;
    }
    _recordMangaJumpDeparture(source: JumpSource.chapter);
    await _switchToChapter(index);
  }

  /// "OCR this page" from the companion: the page's text through the
  /// reader's existing OCR paths, never started any other way.
  ///
  /// - The page already has text (volume OCR, mokuro, streaming OCR, PDF
  ///   text layer): nothing to run.
  /// - The reader's own OCR is running (whole-volume job / streaming page
  ///   OCR): point it at this page; its result lands like every other page.
  /// - Otherwise the page-level entry used by streaming chapters
  ///   ([prepareMangaStreamOcr]: same engine choice and Lens upload consent)
  ///   recognises just this page, and the result is put into the page (and
  ///   its tap-to-look-up overlay). Local ONNX writes the same per-page cache
  ///   the volume job uses, so the page is recovered on the next open; other
  ///   engines' results live for this reading session.
  Future<MangaCompanionOcrOutcome> _companionRecognizePage(int page) async {
    final MokuroPayload? payload = _payload;
    final String? imagesDir = _imagesDir;
    if (!mounted ||
        payload == null ||
        imagesDir == null ||
        page < 0 ||
        page >= payload.images.length) {
      return const MangaCompanionOcrOutcome(MangaCompanionOcrResult.failed);
    }
    final int existing = payload.images[page].blocks.length;
    if (existing > 0) {
      return MangaCompanionOcrOutcome(
        MangaCompanionOcrResult.recognized,
        blocks: existing,
      );
    }
    final MangaOcrRunningJob? job = _observedOcrJob;
    if (job != null) {
      job.focusPage(page);
      return const MangaCompanionOcrOutcome(MangaCompanionOcrResult.delegated);
    }
    final MangaStreamPageOcr? stream = _streamOcr;
    if (stream != null) {
      stream.focus(page);
      return const MangaCompanionOcrOutcome(MangaCompanionOcrResult.delegated);
    }
    final int generation = _pageSessionGeneration;
    try {
      final File? file = await _mangaPageFileAt(page);
      if (!mounted) {
        return const MangaCompanionOcrOutcome(MangaCompanionOcrResult.failed);
      }
      if (file == null || !await file.exists()) {
        return MangaCompanionOcrOutcome(
          MangaCompanionOcrResult.failed,
          error: t.reader_image_file_unavailable,
        );
      }
      if (!mounted) {
        return const MangaCompanionOcrOutcome(MangaCompanionOcrResult.failed);
      }
      final MangaStreamOcrSetup setup = await prepareMangaStreamOcr(
        imageDirPath: imagesDir,
        engines:
            (widget.ocrEnginesOverride ??
                    MangaOcrWizardEngines.resolve(
                      context: context,
                      db: appModel.database,
                    ))
                .withoutAiRefinement(),
        preference: MangaOcrEnginePreferenceKey.fromKey(
          appModel.mangaOcrEnginePreference,
        ),
        lensLanguage: appModel.mangaOcrLensLanguage,
        confirmLensUpload: () async {
          if (!mounted) return false;
          return (widget.lensDisclosureOverride ?? ensureGoogleLensDisclosure)(
            context,
          );
        },
      );
      switch (setup) {
        case MangaStreamOcrReady(:final MangaStreamPageRecognizer recognizer):
          final MokuroImage image;
          try {
            image = await recognizer.recognize(file);
          } finally {
            await recognizer.close();
          }
          if (mounted && generation == _pageSessionGeneration) {
            _putRecognizedPage(page, image);
          }
          return MangaCompanionOcrOutcome(
            MangaCompanionOcrResult.recognized,
            blocks: image.blocks.length,
          );
        case MangaStreamOcrNoEngine():
          return const MangaCompanionOcrOutcome(
            MangaCompanionOcrResult.noEngine,
          );
        case MangaStreamOcrLensDeclined():
          return const MangaCompanionOcrOutcome(
            MangaCompanionOcrResult.declined,
          );
        case MangaStreamOcrUnsupported():
          return const MangaCompanionOcrOutcome(
            MangaCompanionOcrResult.unsupported,
          );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaFushiPage.companionOcr', error, stack);
      return MangaCompanionOcrOutcome(
        MangaCompanionOcrResult.failed,
        error: '$error',
      );
    }
  }
}
