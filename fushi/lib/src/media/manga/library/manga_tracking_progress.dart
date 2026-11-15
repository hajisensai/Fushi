import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

/// Tracking's view of an online manga series: what has been read, by chapter
/// number. Local volumes (no series descriptor) return null and track by
/// volume instead.
Future<MangaReadProgress?> mangaReadProgressOf(
  FushiDatabase db,
  EpubBookRow book,
) async {
  final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
    book.sourceMetadata,
  );
  if (entry == null) return null;
  final Map<String, MangaChapterStateRow> states = await db
      .getMangaChapterStates(book.uid);
  return mangaReadProgressFrom(
    chapters: entry.chapters,
    readAtByKey: <String, int>{
      for (final MapEntry<String, MangaChapterStateRow> state in states.entries)
        if (state.value.readAt case final int readAt) state.key: readAt,
    },
  );
}

/// Pure part of [mangaReadProgressOf].
///
/// - chapters without a number, or numbered 0 or below (Mihon's "unknown"),
///   never count as progress; 12.5 counts as 12;
/// - [MangaReadProgress.allRead] needs at least one chapter and every listed
///   chapter read.
MangaReadProgress mangaReadProgressFrom({
  required List<OnlineMangaChapter> chapters,
  required Map<String, int> readAtByKey,
}) {
  int? highest;
  int lastReadAt = 0;
  bool allRead = chapters.isNotEmpty;
  for (final OnlineMangaChapter chapter in chapters) {
    final int? readAt = readAtByKey[chapter.key];
    if (readAt == null) {
      allRead = false;
      continue;
    }
    if (readAt > lastReadAt) lastReadAt = readAt;
    final double? number = chapter.number;
    if (number == null || number <= 0 || number.isNaN || number.isInfinite) {
      continue;
    }
    final int whole = number.floor();
    if (whole > 0 && (highest == null || whole > highest)) highest = whole;
  }
  return (highestChapter: highest, allRead: allRead, lastReadAt: lastReadAt);
}
