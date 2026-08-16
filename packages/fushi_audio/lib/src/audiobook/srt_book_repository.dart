import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'audiobook_model.dart';
import 'audiobook_path_relocator.dart';
import 'audiobook_repository.dart';
import 'srt_book_model.dart';
import 'audiobook_storage.dart';
import '../parsers/srt_parser.dart';

class SrtBookRepository {
  const SrtBookRepository(this._db);

  final FushiDatabase _db;

  /// 书架 / 媒体源列出用的全量读取。列出前顺手自愈被旧数据根遗弃的绝对路径
  /// （[repairMovedPaths]）——范式同 `VideoBookRepository.listForShelf` 对封面的
  /// 自愈（TODO-1255）。
  Future<List<SrtBook>> listAll() async {
    await repairMovedPaths();
    final rows = await _db.getAllSrtBooks();
    return rows.map(_rowToModel).toList();
  }

  /// BUG-1575 第二步：自愈已经落在用户库里的坏路径。
  ///
  /// 合并导入曾把 `srt_books` 四列**逐列原样**插进本机库而不做路径 rebase，于是
  /// 跨包名迁移（hibiki -> fushi）后行里指着**旧**数据根。修好导入代码救不了已经
  /// 坏掉的库，只能在读取侧自愈。
  ///
  /// 为什么挂在列出路径上，而不是「迁移导入完成后跑一次」或「启动时一次性修复」：
  /// 前者追不上已经迁移完（中转文件已删、完成标志已写）的设备；后者要多扛一个
  /// 「跑过了没」的 pref 状态，而且那个标志一旦为真，未来任何一次数据根变动都
  /// 不再自愈。挂在列出路径上零额外状态、天然幂等，且用户看见症状的那一屏正好
  /// 就是修复发生的那一屏。
  ///
  /// 代价：健康库里每行几次 stat，且**不构造 relocator、不扫目录**（书架本来就
  /// 要为「重新定位」按钮对同一批路径跑 `AudiobookStorage.hasMissingPaths`）。
  /// 判据与保守策略见 [AudiobookPathRelocator]。
  ///
  /// [audiobooksRoot] 默认惰性取 [AudiobookStorage.audiobooksRootDir]（只在真有
  /// 断链行时才解析）；解析失败（纯 Dart 单测、无 path_provider）降级为不修，
  /// **绝不让列书本身失败**。返回真改写了的行数。
  Future<int> repairMovedPaths({
    String? audiobooksRoot,
    bool Function(String path)? exists,
    List<String> Function(String root)? listEntries,
  }) async {
    final List<SrtBookRow> rows = await _db.getAllSrtBooks();
    final bool Function(String) probe =
        exists ?? AudiobookPathRelocator.defaultExists;
    if (!rows.any((SrtBookRow r) => _hasMissingPath(r, probe))) return 0;

    String? root = audiobooksRoot;
    if (root == null) {
      try {
        root = await AudiobookStorage.audiobooksRootDir();
      } catch (e) {
        debugPrint(
            '[fushi-audio] srt path repair skipped (no documents root): $e');
        return 0;
      }
    }

    final AudiobookPathRelocator relocator = AudiobookPathRelocator(
      audiobooksRoot: root,
      exists: exists,
      listEntries: listEntries,
    );
    int rowsChanged = 0;
    for (final SrtBookRow row in rows) {
      final String? newAudioRoot =
          row.audioRoot == null ? null : relocator.relocate(row.audioRoot!);
      final String? newSrtPath = relocator.relocate(row.srtPath);
      final String? newCover =
          row.coverPath == null ? null : relocator.relocate(row.coverPath!);
      final String? newPathsJson =
          _relocateAudioPathsJson(row.audioPathsJson, relocator, row.uid);
      if (newAudioRoot == null &&
          newSrtPath == null &&
          newCover == null &&
          newPathsJson == null) {
        continue;
      }
      await _db.updateSrtBookPaths(
        row.uid,
        audioRoot: newAudioRoot,
        audioPathsJson: newPathsJson,
        srtPath: newSrtPath,
        coverPath: newCover,
      );
      rowsChanged++;
    }
    if (!relocator.stats.isEmpty) {
      debugPrint('[fushi-audio] srt path repair: rows=$rowsChanged '
          '${relocator.stats} root=$root');
    }
    return rowsChanged;
  }

  /// 返回改写后的 JSON；**null = 保持原值**（无一条需要改，或值本身不是 JSON
  /// 字符串列表）。坏值不得中断整批自愈。
  static String? _relocateAudioPathsJson(
    String? json,
    AudiobookPathRelocator relocator,
    String uid,
  ) {
    if (json == null) return null;
    late final List<String> paths;
    try {
      final dynamic decoded = jsonDecode(json);
      if (decoded is! List) return null;
      paths = decoded.whereType<String>().toList();
    } catch (e) {
      debugPrint('[fushi-audio] srt path repair: bad audioPathsJson for '
          '$uid: $e');
      return null;
    }
    bool changed = false;
    final List<String> out = paths.map((String path) {
      final String? fixed = relocator.relocate(path);
      if (fixed == null) return path;
      changed = true;
      return fixed;
    }).toList();
    return changed ? jsonEncode(out) : null;
  }

  static bool _hasMissingPath(SrtBookRow row, bool Function(String) probe) {
    bool broken(String? path) =>
        path != null && path.isNotEmpty && !probe(path);
    if (broken(row.audioRoot) || broken(row.srtPath) || broken(row.coverPath)) {
      return true;
    }
    final String? json = row.audioPathsJson;
    if (json == null) return false;
    try {
      final dynamic decoded = jsonDecode(json);
      if (decoded is! List) return false;
      return decoded.whereType<String>().any(broken);
    } catch (_) {
      return false;
    }
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
    // 删除传播：重新导入同 uid 的纯字幕书 → 清其 sync 删除墓碑，防「删了又加、墓碑
    // 还在」误判（范式仿 [AudiobookRepository.saveAudiobook] / 书 / 视频的插入清墓碑）。
    await _db.clearSyncDeletionTombstone(
        SyncTombstoneKind.srtbook.dbValue, book.uid);
  }

  /// Deletes the SRT book + its on-disk persist dir. Returns the number of
  /// srt_books rows actually removed (0 when [uid] matched nothing) so callers
  /// can count only real deletions (BUG-439).
  ///
  /// [propagateDeletion]（默认 false）：true 时记一条 `srtbook` sync 删除墓碑，供同步
  /// 发布到远端标记、其他设备逐条确认后也删（对应删除弹窗「从所有设备删除」）。false
  /// （含消费远端删除标记的路径）只删本机，绝不回写墓碑造成传播循环。app 层按
  /// `DeleteScope` 传入——用 bool 而非 DeleteScope 是为了不让本包反向依赖 app 层，
  /// 与同包 [AudiobookRepository.deleteAudiobook] 同一范式。
  ///
  /// 墓碑**只对 standalone 行写**（该行 `bookKey` 为空）：这类纯字幕书无 EpubBooks 行，
  /// 跨设备身份就是 uid。srt-backed 行（`bookKey` 非空）的身份是 bookKey，它的墓碑由
  /// `ReaderFushiSource.deleteBook` 写成 `book` 种类——两者互斥，同一资产绝不会产生
  /// 两条墓碑、也就不会在对端弹出两条重复的删除确认。
  Future<int> delete(String uid, {bool propagateDeletion = false}) async {
    // 身份判据要在删行前读（删完就查不到 bookKey 了）。
    final bool standalone = propagateDeletion &&
        ((await _db.getSrtBookByUid(uid))?.bookKey.isEmpty ?? false);
    final int deleted = await _db.deleteSrtBookByUid(uid);
    // 墓碑写在磁盘清理**之前**：DB 行是唯一真相源，此刻这本书对用户已经消失；持久化
    // 目录删除是删完再打扫的尾活，Windows 上可能因句柄占用抛 errno 32/145。若把墓碑
    // 排在它后面，一次尾活失败就会静默吞掉用户「从所有设备删除」的意图（同 TODO-1359
    // 那类「尾活失败翻转结果」的坑）。
    if (deleted > 0 && standalone) {
      try {
        await _db.writeSyncDeletionTombstone(SyncTombstoneKind.srtbook.dbValue,
            uid, DateTime.now().millisecondsSinceEpoch);
      } catch (_) {
        // best-effort：记账失败不影响字幕书已删。
      }
    }
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
    book.language = r.language;
    return book;
  }
}
