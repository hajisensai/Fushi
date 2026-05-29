import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression test for the HBK-AUDIT-041 follow-up: deleteEpubBook must purge
/// audio_cues owned by an SRT book linked to the deleted epub. Those cues are
/// keyed on srt_books.uid (e.g. "srtbook_..."), NOT on the epub book uid, so a
/// cascade that only deleted cues by the epub uid left them orphaned.
void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<int> cueCount(String bookUid) async {
    final row = await db
        .customSelect("SELECT COUNT(*) AS c FROM audio_cues "
            "WHERE book_uid = '$bookUid'")
        .getSingle();
    return row.read<int>('c');
  }

  test('deleteEpubBook also deletes audio_cues owned by a linked SRT book',
      () async {
    final int epubId = await db.insertEpubBook(EpubBooksCompanion.insert(
      title: 'Book',
      epubPath: '/x.epub',
      extractDir: '/x',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    // SRT book linked to the epub (ttu_book_id == epubId), cues keyed on its
    // uid; plus an audiobook keyed on the epub book uid.
    const String srtUid = 'srtbook_test';
    final String epubUid = buildLegacyBookUid(epubId);
    await db.customStatement(
      "INSERT INTO srt_books (uid, title, srt_path, imported_at, ttu_book_id) "
      "VALUES (?, 'SRT', '/s.srt', 0, ?)",
      [srtUid, epubId],
    );
    for (final String owner in <String>[srtUid, epubUid]) {
      await db.customStatement(
        "INSERT INTO audio_cues (book_uid, chapter_href, sentence_index, "
        "text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) "
        "VALUES (?, 'c.xhtml', 0, 'f', 't', 0, 1, 0)",
        [owner],
      );
    }

    expect(await cueCount(srtUid), 1);
    expect(await cueCount(epubUid), 1);

    await db.deleteEpubBook(epubId);

    // Both the epub-uid cue and the SRT-uid cue must be gone (no orphans).
    expect(await cueCount(srtUid), 0);
    expect(await cueCount(epubUid), 0);
  });
}
