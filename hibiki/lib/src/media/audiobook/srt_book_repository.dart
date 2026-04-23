import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';

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

  Future<void> save(SrtBook book) async {
    await _db.upsertSrtBook(SrtBooksCompanion(
      uid: Value(book.uid),
      title: Value(book.title),
      author: Value(book.author),
      audioRoot: Value(book.audioRoot),
      audioPathsJson: Value(
          book.audioPaths != null ? jsonEncode(book.audioPaths) : null),
      srtPath: Value(book.srtPath),
      coverPath: Value(book.coverPath),
      importedAt: Value(book.importedAt),
      ttuBookId: Value(book.ttuBookId),
    ));
  }

  Future<void> delete(String uid) => _db.deleteSrtBookByUid(uid);

  Future<List<AudioCue>> cuesFor(String uid) async {
    final rows = await ((_db.select(_db.audioCues))
          ..where((t) =>
              t.bookUid.equals(uid) &
              t.chapterHref.equals(SrtParser.defaultChapter))
          ..orderBy([(t) => OrderingTerm.asc(t.sentenceIndex)]))
        .get();
    return rows.map(AudioCue.fromRow).toList();
  }

  Future<void> saveCues({
    required String uid,
    required List<AudioCue> cues,
  }) async {
    await _db.replaceCuesForBook(
        uid, cues.map(AudioCue.toCompanion).toList());
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
    book.ttuBookId = r.ttuBookId;
    return book;
  }
}
