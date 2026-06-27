import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'audiobook_model.dart';
import 'srt_book_model.dart';
import 'audiobook_storage.dart';
import '../parsers/srt_parser.dart';

class SrtBookRepository {
  const SrtBookRepository(this._db);

  final HibikiDatabase _db;

  Future<List<SrtBook>> listAll() async {
    final rows = await _db.getAllSrtBooks();
    return rows.map(_rowToModel).toList();
  }

  Future<SrtBook?> findByUid(String uid) async {
    final row = await _db.getSrtBookByUid(uid);
    if (row == null) return null;
    return _rowToModel(row);
  }

  Future<SrtBook?> findByBookKey(String bookKey) async {
    final row = await _db.getSrtBookByBookKey(bookKey);
    if (row == null) return null;
    return _rowToModel(row);
  }

  Future<void> save(SrtBook book) async {
    await _db.upsertSrtBook(SrtBooksCompanion(
      uid: Value(book.uid),
      title: Value(book.title),
      author: Value(book.author),
      audioRoot: Value(book.audioRoot),
      audioPathsJson:
          Value(book.audioPaths != null ? jsonEncode(book.audioPaths) : null),
      srtPath: Value(book.srtPath),
      coverPath: Value(book.coverPath),
      importedAt: Value(book.importedAt),
      bookKey: Value(book.bookKey),
    ));
  }

  /// Deletes the SRT book + its on-disk persist dir. Returns the number of
  /// srt_books rows actually removed (0 when [uid] matched nothing) so callers
  /// can count only real deletions (BUG-439).
  Future<int> delete(String uid) async {
    final int deleted = await _db.deleteSrtBookByUid(uid);
    await AudiobookStorage.deletePersistDir(uid);
    return deleted;
  }

  Future<List<AudioCue>> cuesFor(String uid) async {
    final rows = await ((_db.select(_db.audioCues))
          ..where((t) =>
              t.bookKey.equals(uid) &
              t.chapterHref.equals(SrtParser.defaultChapter))
          ..orderBy([(t) => OrderingTerm.asc(t.sentenceIndex)]))
        .get();
    return rows.map(AudioCue.fromRow).toList();
  }

  Future<void> saveCues({
    required String uid,
    required List<AudioCue> cues,
  }) async {
    await _db.replaceCuesForBook(uid, cues.map(AudioCue.toCompanion).toList());
  }

  static SrtBook _rowToModel(SrtBookRow r) {
    final book = SrtBook();
    book.id = r.id;
    book.uid = r.uid;
    book.title = r.title;
    book.author = r.author;
    book.audioRoot = r.audioRoot;
    book.audioPaths = r.audioPathsJson != null
        ? (jsonDecode(r.audioPathsJson!) as List).cast<String>()
        : null;
    book.srtPath = r.srtPath;
    book.coverPath = r.coverPath;
    book.importedAt = r.importedAt;
    book.bookKey = r.bookKey;
    return book;
  }
}
