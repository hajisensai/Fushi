/// EPUB reader module of the companion (`CompanionContextKind.reader`):
/// snapshot keys and command names shared by the reader page (main engine,
/// `reader_fushi/companion.part.dart`) and `ReaderCompanionPanel`. Pure Dart.
///
/// Snapshot (~1/s while the reader is the top page and the companion is up):
/// - [title] String, [author] String?, [cover] String? (local file path).
/// - [chapterTitle] String, [chapterIndex] int, [chapterCount] int.
/// - [percent] double? (0..100 of the book; null while char counts load).
/// - [toc] List of {[tocLabel], [tocDepth]} (flat, capped at [maxToc]),
///   [tocCurrent] int (index into [toc], -1 = unknown).
/// - [hasAudio] bool, [playing] bool (an audiobook is attached).
/// - [bookmarksEnabled] bool (the book has a stable id: bookmarks work),
///   [bookmarks] List of {[bookmarkId], [bookmarkLabel], [bookmarkChapter]
///   (1-based chapter number)}
///   (newest first, capped at [maxBookmarks]).
/// - [stats] Map? of this book's stats for today ([todayMs], [todayChars],
///   [todayLookups], [todayCards]); null until loaded.
abstract final class ReaderCompanionKeys {
  static const int maxToc = 400;
  static const int maxBookmarks = 100;

  static const String title = 'title';
  static const String author = 'author';
  static const String cover = 'cover';
  static const String chapterTitle = 'chapterTitle';
  static const String chapterIndex = 'chapterIndex';
  static const String chapterCount = 'chapterCount';
  static const String percent = 'percent';
  static const String toc = 'toc';
  static const String tocLabel = 'label';
  static const String tocDepth = 'depth';
  static const String tocCurrent = 'tocCurrent';
  static const String hasAudio = 'hasAudio';
  static const String playing = 'playing';
  static const String bookmarksEnabled = 'bookmarksEnabled';
  static const String bookmarks = 'bookmarks';
  static const String bookmarkId = 'id';
  static const String bookmarkLabel = 'label';
  static const String bookmarkChapter = 'chapter';
  static const String stats = 'stats';
  static const String todayMs = 'todayMs';
  static const String todayChars = 'todayChars';
  static const String todayLookups = 'todayLookups';
  static const String todayCards = 'todayCards';
}

/// Reader commands (`session.command(action, args)`).
abstract final class ReaderCompanionActions {
  /// `{forward: bool}`.
  static const String turnPage = 'turnPage';
  static const String forward = 'forward';

  /// `{percent: double}` (0..100), sent on slider release.
  static const String seekPercent = 'seekPercent';
  static const String percent = 'percent';

  /// `{index: int}` into the published toc.
  static const String goToToc = 'goToToc';
  static const String index = 'index';

  /// Attached audiobook play / pause.
  static const String playPause = 'playPause';

  /// Bookmark the current page (the reader's own bookmark logic).
  static const String addBookmark = 'addBookmark';

  /// `{id: int}`: jump to a published bookmark.
  static const String jumpToBookmark = 'jumpToBookmark';
  static const String id = 'id';
}
