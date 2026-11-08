import 'dart:async';

import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/manga_companion_schema.dart';
import 'package:material_ui/material_ui.dart';

/// The manga reader's end of the dual-screen companion: claims the manga
/// context, publishes a coarse snapshot (~1/s, only while the companion is
/// up) and runs the panel's commands on the reader.
///
/// Kept out of the 8000-line page so the snapshot, the commands and the
/// "OCR this page" rule can be tested without a WebView: the page only
/// implements [MangaCompanionReader].

/// Upper bounds of what one snapshot carries.
const int kMangaCompanionMaxLines = 40;
const int kMangaCompanionMaxLineChars = 400;
const int kMangaCompanionMaxChapters = 400;
const int kMangaCompanionMaxGenres = 8;
const int kMangaCompanionMaxDescriptionChars = 4000;

/// What the reader shows right now (built by the page, only while the
/// companion is up).
@immutable
class MangaCompanionReadState {
  const MangaCompanionReadState({
    required this.title,
    required this.pageKey,
    required this.page,
    required this.pageCount,
    this.chapter,
    this.author,
    this.description,
    this.genres = const <String>[],
    this.rtl = false,
    this.chapterNames = const <String>[],
    this.currentChapterIndex = -1,
    this.pageTexts = const <String>[],
    this.readerOcrBusy = false,
  });

  /// Series title (online) or volume title (local).
  final String title;

  /// Identity of the page on show (chapter session + page index): OCR state
  /// belongs to one page and is dropped when this changes.
  final Object pageKey;

  /// 0-based page index.
  final int page;
  final int pageCount;
  final String? chapter;
  final String? author;
  final String? description;
  final List<String> genres;
  final bool rtl;

  /// Chapter names in the source's order (online sources list newest
  /// first); empty for a local volume.
  final List<String> chapterNames;

  /// Index of the current chapter in [chapterNames]; -1 = none.
  final int currentChapterIndex;

  /// Text blocks the current page already has (OCR / mokuro / PDF text
  /// layer); empty = not recognised.
  final List<String> pageTexts;

  /// An OCR run the reader already has (whole-volume job, streaming page
  /// OCR) is working.
  final bool readerOcrBusy;
}

/// How one "OCR this page" request ended.
enum MangaCompanionOcrResult {
  /// Recognised by this request ([MangaCompanionOcrOutcome.blocks] blocks).
  recognized,

  /// The reader's own running OCR (volume job / streaming) was pointed at
  /// the page; its result lands in the page like every other page.
  delegated,
  noEngine,

  /// The user declined uploading the page (Google Lens).
  declined,
  unsupported,
  failed,
}

@immutable
class MangaCompanionOcrOutcome {
  const MangaCompanionOcrOutcome(this.result, {this.blocks = 0, this.error});

  final MangaCompanionOcrResult result;
  final int blocks;
  final String? error;
}

/// The page's side of the companion.
abstract interface class MangaCompanionReader {
  /// Null while nothing is loaded.
  MangaCompanionReadState? readState();
  void previousPage();
  void nextPage();
  void previousChapter();
  void nextChapter();

  /// [index] is the chapter's index in [MangaCompanionReadState.chapterNames].
  void goToChapter(int index);

  /// Recognises page [page] (0-based) through the reader's existing OCR
  /// path and puts the result into the page.
  Future<MangaCompanionOcrOutcome> recognizePage(int page);
}

/// "OCR this page" state: one page at a time, only ever started by [run]
/// (the panel's button) — never by a page turn or by opening the book.
class MangaCompanionPageOcr {
  MangaCompanionPageOcr({required VoidCallback onChanged})
    : _onChanged = onChanged;

  final VoidCallback _onChanged;
  Object? _key;
  int _generation = 0;
  bool _running = false;
  MangaCompanionOcrOutcome? _outcome;

  /// A request is in flight.
  bool get isRunning => _running;

  /// Recognises the page [key] with [recognize] (skipped while the same page
  /// is already running).
  Future<void> run(
    Object key,
    Future<MangaCompanionOcrOutcome> Function() recognize,
  ) async {
    if (_running && _key == key) return;
    final int generation = ++_generation;
    _key = key;
    _outcome = null;
    _running = true;
    _onChanged();
    MangaCompanionOcrOutcome? outcome;
    try {
      outcome = await recognize();
    } finally {
      if (generation == _generation) {
        _running = false;
        _outcome = outcome;
        _onChanged();
      }
    }
  }

  /// State of the box for page [key]: text wins; another page reads idle
  /// (its result was dropped when the reader moved on).
  ({MangaCompanionOcrState state, String? error}) stateFor(
    Object key, {
    required bool hasText,
    required bool readerOcrBusy,
  }) {
    if (hasText) return (state: MangaCompanionOcrState.done, error: null);
    if (key != _key) return (state: MangaCompanionOcrState.idle, error: null);
    if (_running) return (state: MangaCompanionOcrState.running, error: null);
    final MangaCompanionOcrOutcome? outcome = _outcome;
    if (outcome == null) {
      return (state: MangaCompanionOcrState.idle, error: null);
    }
    final MangaCompanionOcrState state = switch (outcome.result) {
      MangaCompanionOcrResult.recognized => MangaCompanionOcrState.empty,
      MangaCompanionOcrResult.delegated =>
        readerOcrBusy
            ? MangaCompanionOcrState.running
            : MangaCompanionOcrState.empty,
      MangaCompanionOcrResult.noEngine => MangaCompanionOcrState.noEngine,
      MangaCompanionOcrResult.declined => MangaCompanionOcrState.idle,
      MangaCompanionOcrResult.unsupported => MangaCompanionOcrState.unsupported,
      MangaCompanionOcrResult.failed => MangaCompanionOcrState.failed,
    };
    return (
      state: state,
      error: state == MangaCompanionOcrState.failed ? outcome.error : null,
    );
  }
}

String _cap(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// The snapshot for [s] (JSON-safe, capped). Missing data is left out.
Map<String, Object?> buildMangaCompanionSnapshot(
  MangaCompanionReadState s, {
  required MangaCompanionOcrState ocr,
  String? ocrError,
}) {
  final int count = s.chapterNames.length;
  final bool hasChapter =
      s.currentChapterIndex >= 0 && s.currentChapterIndex < count;
  // Reading order (oldest first): source position k sits at count - 1 - k.
  final List<Map<String, Object?>> chapters = <Map<String, Object?>>[];
  if (count > 0) {
    final int current = hasChapter ? count - 1 - s.currentChapterIndex : 0;
    int start = 0;
    int end = count;
    if (count > kMangaCompanionMaxChapters) {
      start = (current - kMangaCompanionMaxChapters ~/ 2).clamp(
        0,
        count - kMangaCompanionMaxChapters,
      );
      end = start + kMangaCompanionMaxChapters;
    }
    for (int r = start; r < end; r++) {
      final int index = count - 1 - r;
      chapters.add(<String, Object?>{
        MangaCompanionKeys.chapterIndex: index,
        MangaCompanionKeys.chapterName: s.chapterNames[index],
      });
    }
  }
  final List<String> lines = <String>[
    for (final String text in s.pageTexts)
      if (text.trim().isNotEmpty)
        _cap(text.trim(), kMangaCompanionMaxLineChars),
  ];
  final String? description = s.description?.trim();
  return <String, Object?>{
    MangaCompanionKeys.title: s.title,
    if (s.chapter != null && s.chapter!.isNotEmpty)
      MangaCompanionKeys.chapter: s.chapter,
    if (s.author != null && s.author!.trim().isNotEmpty)
      MangaCompanionKeys.author: s.author!.trim(),
    if (description != null && description.isNotEmpty)
      MangaCompanionKeys.description: _cap(
        description,
        kMangaCompanionMaxDescriptionChars,
      ),
    if (s.genres.isNotEmpty)
      MangaCompanionKeys.genres: s.genres
          .take(kMangaCompanionMaxGenres)
          .toList(),
    MangaCompanionKeys.page: s.page,
    MangaCompanionKeys.pageCount: s.pageCount,
    MangaCompanionKeys.rtl: s.rtl,
    if (count > 0) ...<String, Object?>{
      MangaCompanionKeys.chapters: chapters,
      MangaCompanionKeys.chapterCount: count,
      if (hasChapter) ...<String, Object?>{
        MangaCompanionKeys.currentChapter: s.currentChapterIndex,
        MangaCompanionKeys.chapterPosition: count - s.currentChapterIndex,
      },
    },
    MangaCompanionKeys.ocr: ocr.name,
    if (ocrError != null && ocrError.isNotEmpty)
      MangaCompanionKeys.ocrError: _cap(ocrError, 200),
    if (lines.isNotEmpty)
      MangaCompanionKeys.lines: lines.take(kMangaCompanionMaxLines).toList(),
  };
}

/// Claim + snapshot + commands for one manga reader page.
class MangaCompanionHook {
  MangaCompanionHook({
    required MangaCompanionReader reader,
    CompanionContextRegistry? registry,
    Duration period = const Duration(seconds: 1),
  }) : _reader = reader,
       link = CompanionPageLink(registry: registry, period: period) {
    ocr = MangaCompanionPageOcr(onChanged: link.publishNow);
  }

  final MangaCompanionReader _reader;
  final CompanionPageLink link;
  late final MangaCompanionPageOcr ocr;
  String? _claimedTitle;
  Route<Object?>? _route;
  bool _started = false;

  /// The companion is up (cheap).
  bool get isActive => link.isActive;

  /// Claims the manga context (again when [title] or [route] changed).
  void claim(String title, {Route<Object?>? route}) {
    final Route<Object?>? nextRoute = route ?? _route;
    if (title == _claimedTitle && identical(nextRoute, _route)) return;
    _claimedTitle = title;
    _route = nextRoute;
    link.claim(
      CompanionContext(CompanionContextKind.manga, title: title),
      route: nextRoute,
      onCommand: handleCommand,
    );
    if (!_started) {
      _started = true;
      link.startSnapshots(buildSnapshot);
    } else {
      link.invalidate();
      link.publishNow();
    }
  }

  /// The reader moved (page / chapter): publish right away.
  void publishNow() => link.publishNow();

  /// The current snapshot; null while nothing is loaded.
  Map<String, Object?>? buildSnapshot() {
    final MangaCompanionReadState? s = _reader.readState();
    if (s == null) return null;
    final ({MangaCompanionOcrState state, String? error}) box = ocr.stateFor(
      s.pageKey,
      hasText: s.pageTexts.any((String t) => t.trim().isNotEmpty),
      readerOcrBusy: s.readerOcrBusy,
    );
    return buildMangaCompanionSnapshot(s, ocr: box.state, ocrError: box.error);
  }

  /// A command from the panel.
  void handleCommand(String action, Map<String, Object?> args) {
    switch (action) {
      case MangaCompanionActions.previousPage:
        _reader.previousPage();
      case MangaCompanionActions.nextPage:
        _reader.nextPage();
      case MangaCompanionActions.previousChapter:
        _reader.previousChapter();
      case MangaCompanionActions.nextChapter:
        _reader.nextChapter();
      case MangaCompanionActions.goToChapter:
        final int? index = args.intOrNull(MangaCompanionActions.argIndex);
        final MangaCompanionReadState? s = _reader.readState();
        if (index == null ||
            s == null ||
            index < 0 ||
            index >= s.chapterNames.length ||
            index == s.currentChapterIndex) {
          return;
        }
        _reader.goToChapter(index);
      case MangaCompanionActions.ocrPage:
        final MangaCompanionReadState? s = _reader.readState();
        if (s == null) return;
        final int page = s.page;
        unawaited(ocr.run(s.pageKey, () => _reader.recognizePage(page)));
    }
  }

  void dispose() => link.dispose();
}
