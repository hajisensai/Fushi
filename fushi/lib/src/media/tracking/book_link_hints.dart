import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart' show EpubBookRow;
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/sync/online_novel_book.dart'
    show kLnReaderOnlineBookMarker;
import 'package:fushi_web_core/fushi_web_core.dart' show WebNovelSnapshot;

/// What the app knows about [book] for linking it to a tracking site. The
/// app owns these formats, the engine only sees the database row.
///
/// [displayTitle] is the user's rename (null when none). Online manga series,
/// web novels and LNReader novels count chapters; everything else counts
/// volumes.
BookLinkHints bookLinkHintsOf(EpubBookRow book, {String? displayTitle}) {
  final String? metadata = book.sourceMetadata;
  final OnlineMangaLibraryEntry? manga = OnlineMangaLibraryEntry.tryParse(
    metadata,
  );
  if (manga != null) {
    return (
      displayTitle: displayTitle,
      extraTitles: <String>[manga.series.title],
      authors: <String>[
        if (manga.series.author case final String author) author,
      ],
      chapterWork: true,
    );
  }
  final WebNovelSnapshot? web = WebNovelSnapshot.tryParse(metadata);
  if (web != null) {
    return (
      displayTitle: displayTitle,
      extraTitles: <String>[if (web.workTitle case final String title) title],
      authors: <String>[if (web.author case final String author) author],
      chapterWork: true,
    );
  }
  return (
    displayTitle: displayTitle,
    extraTitles: const <String>[],
    authors: const <String>[],
    chapterWork: metadata?.contains(kLnReaderOnlineBookMarker) ?? false,
  );
}
