import 'dart:convert';
import 'dart:io';

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

  /// TODO-1032：把一组用户选定的音频文件**复制导入**到 [uid] 的持久目录，并改写
  /// 该 SRT 书的 [SrtBook.audioPaths]（清空 [SrtBook.audioRoot]），三入口（书架
  /// 重新定位/书架导入音频/阅读器内导入）归一到此唯一写入路径，避免把 SRT 书的
  /// 音频误写进 Audiobooks 表（导致导入对话框查不到、显示空表单）。
  ///
  /// 行为与阅读器内 `_openSrtBookAudioPicker` 逐字节等价：
  /// - persist 目录 key 统一为 [uid]（`AudiobookStorage.ensurePersistDir(uid)`）；
  /// - 写入前 `cleanAudioFiles` 清掉旧音频文件（整组替换语义）；
  /// - 逐个 `persistFileWithProgress` 复制进持久目录；
  /// - 落库时 `audioPaths = 复制后的路径`、`audioRoot = null`。
  ///
  /// [uid] 必须命中既有 SRT 书，否则抛 [StateError]（调用方应已加载过该书）。
  /// [pickedPaths] 为空时直接返回（无副作用），调用方负责空选过滤/提示。
  /// [onProgress] 透传给 `persistFileWithProgress`，可用于进度 UI。
  /// 返回复制后落库的音频路径列表（顺序与 [pickedPaths] 一致）。
  Future<List<String>> replaceAudio({
    required String uid,
    required List<String> pickedPaths,
    void Function(int copied, int total)? onProgress,
  }) async {
    if (pickedPaths.isEmpty) return const <String>[];

    final SrtBook? book = await findByUid(uid);
    if (book == null) {
      throw StateError('replaceAudio: no SRT book for uid=$uid');
    }

    final Directory persistDir = await AudiobookStorage.ensurePersistDir(uid);
    await AudiobookStorage.cleanAudioFiles(persistDir);

    final List<String> persisted = <String>[];
    for (final String src in pickedPaths) {
      persisted.add(
        await AudiobookStorage.persistFileWithProgress(
          File(src),
          persistDir,
          onProgress: onProgress,
        ),
      );
    }

    book.audioPaths = persisted;
    book.audioRoot = null;
    await save(book);
    return persisted;
  }

  Future<void> save(SrtBook book) async {
    await _db.upsertSrtBook(SrtBooksCompanion(
      // Carry the primary key when known so insertOnConflictUpdate (which
      // resolves on the `id` PK, not the `uid` unique index) performs a real
      // in-place update instead of hitting the UNIQUE(uid) constraint. Callers
      // that don't load `id` (fresh inserts) leave it absent — unchanged.
      id: book.id != null ? Value(book.id!) : const Value.absent(),
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
