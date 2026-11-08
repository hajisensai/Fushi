/// Wire schema of the manga companion panel (snapshot keys, command names,
/// OCR states), shared by the manga reader (main engine) and the panel
/// (companion engine). Pure Dart.
library;

/// Snapshot keys published by the manga reader.
abstract final class MangaCompanionKeys {
  /// Series title (online series) or the volume's title (local volume).
  static const String title = 'title';

  /// Current chapter's display name (online series only).
  static const String chapter = 'chapter';

  /// Author / artist from the source or the volume row.
  static const String author = 'author';

  /// Series description from the source.
  static const String description = 'description';

  /// Genre labels from the source (capped).
  static const String genres = 'genres';

  /// Current page, 0-based.
  static const String page = 'page';
  static const String pageCount = 'pageCount';

  /// Right-to-left page order (arrow icons follow it).
  static const String rtl = 'rtl';

  /// Chapters in reading order (oldest first), each `{i: <index for
  /// goToChapter>, n: <display name>}`; capped to a window around the current
  /// chapter.
  static const String chapters = 'chapters';
  static const String chapterIndex = 'i';
  static const String chapterName = 'n';

  /// Current chapter's index in [chapters] terms (the `i` value); -1 = none.
  static const String currentChapter = 'currentChapter';

  /// 1-based reading position of the current chapter ("9 of 24").
  static const String chapterPosition = 'chapterPosition';
  static const String chapterCount = 'chapterCount';

  /// [MangaCompanionOcrState] wire name of the "text on this page" box.
  static const String ocr = 'ocr';

  /// Short error detail for [MangaCompanionOcrState.failed].
  static const String ocrError = 'ocrError';

  /// Text blocks recognised on the current page (capped).
  static const String lines = 'lines';
}

/// Commands the panel sends to the manga reader.
abstract final class MangaCompanionActions {
  static const String previousPage = 'previousPage';
  static const String nextPage = 'nextPage';
  static const String previousChapter = 'previousChapter';
  static const String nextChapter = 'nextChapter';

  /// Args: `{index: <chapter i>}`.
  static const String goToChapter = 'goToChapter';
  static const String argIndex = 'index';

  /// Recognises the text of the current page (only ever on this command).
  static const String ocrPage = 'ocrPage';
}

/// State of the "text on this page" box.
enum MangaCompanionOcrState {
  /// Not recognised and not asked for: the panel offers "OCR this page".
  idle,

  /// Recognising the current page.
  running,

  /// The page has text ([MangaCompanionKeys.lines]).
  done,

  /// Recognised, but no text was found.
  empty,

  /// Recognition failed ([MangaCompanionKeys.ocrError]).
  failed,

  /// No OCR engine is ready.
  noEngine,

  /// The chosen engine only recognises whole volumes.
  unsupported;

  static MangaCompanionOcrState fromWire(String? value) {
    for (final MangaCompanionOcrState state in values) {
      if (state.name == value) return state;
    }
    return idle;
  }
}
