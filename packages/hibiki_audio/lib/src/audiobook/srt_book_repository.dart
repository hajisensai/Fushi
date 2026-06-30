import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'audiobook_model.dart';
import 'audiobook_repository.dart';
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

    // TODO-1032 PR2：愈合旧数据。PR1 把 SRT 书音频归一到 SrtBooks.audioPaths，但
    // 旧版书架「导入音频」曾对同一本 EPUB 配对 SRT 书落过一条 **Audiobooks** 脏行
    // （audioOnly 导入，无对齐字幕）。读取端 AudiobookSessionLauncher.resolve 先查
    // Audiobooks 再回退 SrtBooks，那条脏行存在时永远优先返回旧/错音频 → 用户在
    // SrtBooks 重新定位的正确音频被无视（「重新导入后音频不对」根因）。
    // 写入非空音频后删除这条脏行，让 resolve 落到 SrtBook 正确音频。
    await _healDirtyAudiobookRow(book);

    return persisted;
  }

  /// TODO-1032 PR2：删除「旧版书架 audioOnly 导入误落的 Audiobook 脏行」，使读取端
  /// resolve 落到本次写入的 SrtBook 正确音频。
  ///
  /// 严守的隔离判据（绝不误删真 EPUB 有声书）：
  /// 1. 仅当本次 [book] 真带音频（[SrtBook.audioPaths] 非空）才触发——否则会删出
  ///    「两边都没音频」。
  /// 2. 仅对 **EPUB 配对 SRT 书**愈合：[SrtBook.bookKey] 非空（standalone 字幕书
  ///    bookKey 为空，从不落 Audiobook 行，天然豁免）。
  /// 3. **核心**：只删 **没有对齐字幕** 的 Audiobook 行（`alignmentPath` 空 **且**
  ///    `alignmentFormat` 空）。Audiobooks.alignmentPath / alignmentFormat 都是
  ///    NOT NULL 列：**真 EPUB 有声书**导入恒带对齐字幕（alignmentPath 指向真实
  ///    .srt/.smil 文件、alignmentFormat 为 'srt'/'lrc'/... 非空，见
  ///    AudiobookImportDialog `_doImport` 与 audiobook_alignment_service），v29
  ///    backfill 也只为这种带对齐的 audiobook 造同 bookKey 的 SrtBook 配对行；而
  ///    SRT 字幕书误落的脏行**没有对齐字幕**（对齐 cue 由 SrtBook 自身在 uid
  ///    命名空间持有，脏 Audiobook 行只带裸音频、对齐字段为空）。两者都可能共享
  ///    同一 bookKey 且都有「带音频的 SrtBook 配对行」，唯一可靠区分点就是
  ///    Audiobook 行**自身是否带对齐字幕**——带对齐 → 真有声书会话来源，绝不删。
  ///
  /// cue 隔离：[AudiobookRepository.deleteAudiobook] 删 audio_cues 按 **bookKey**
  /// （裸 EPUB key）；SrtBook 自己的 cue key 是 **uid**（`srtbook_epub_<bookKey>`，
  /// 见 [cuesFor] 用 `t.bookKey.equals(uid)`）——不同命名空间，删脏行 cue 天然不碰
  /// SrtBook cue。进度隔离：SrtBook 进度 pref key 为 `audiobook_pos_<uid>`，脏行
  /// 进度为 `audiobook_pos_<bookKey>`，`deleteAudiobook` 只删表行+cue+persistDir，
  /// 不删 pref，且 key 本就不同——删脏行不连带丢 SrtBook 进度。
  Future<void> _healDirtyAudiobookRow(SrtBook book) async {
    final List<String>? audioPaths = book.audioPaths;
    if (audioPaths == null || audioPaths.isEmpty) return; // guard 1
    final String bookKey = book.bookKey;
    if (bookKey.isEmpty) return; // guard 2: standalone 字幕书无脏行

    final AudiobookRow? abRow = await _db.getAudiobookByBookKey(bookKey);
    if (abRow == null) return; // 无 Audiobook 行 → 无脏行可愈合
    // guard 3: 带对齐字幕 = 真 EPUB 有声书（含 v29 backfill 的配对来源），绝不删。
    // alignmentPath / alignmentFormat 为 NOT NULL 列，真有声书恒非空；脏行恒为空。
    final bool hasAlignment =
        abRow.alignmentPath.isNotEmpty || abRow.alignmentFormat.isNotEmpty;
    if (hasAlignment) return;

    // 确证为 audioOnly 脏行：删行（连带 bookKey 命名空间下的脏 cue + persistDir）。
    await AudiobookRepository(_db).deleteAudiobook(bookKey);
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
