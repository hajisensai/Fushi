import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_position_mapping.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_stat_segments.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

/// 导入前给用户看的概况（只数数，不碰库以外的东西）。
class ExternalReaderImportPreview {
  const ExternalReaderImportPreview({
    required this.newBooks,
    required this.existingBooks,
    required this.statsOnlyBooks,
    required this.statRecords,
    required this.positions,
    required this.profileName,
  });

  /// 有 epub、库里还没有、会被导入的书。
  final int newBooks;

  /// 库里已有同名书（按 bookKey 对上），只补进度与统计、不重复导入。
  final int existingBooks;

  /// 只有统计没有书（Hoshi 里已删的书 / 备份里缺 epub）。
  final int statsOnlyBooks;

  /// 统计记录条数（iOS 会话 + ッツ日记录）。
  final int statRecords;

  /// 带阅读位置的书。
  final int positions;

  /// 统计要落进的 Profile。
  final String profileName;
}

/// 一本书没能导入（统计仍会按书名挂上）。
class ExternalReaderImportFailure {
  const ExternalReaderImportFailure({
    required this.title,
    required this.reason,
  });

  final String title;
  final String reason;
}

/// 导入结果。
class ExternalReaderImportReport {
  int booksImported = 0;
  int booksMatched = 0;
  int positionsWritten = 0;

  /// Fushi 里的进度比 Hoshi 新，保留 Fushi 的。
  int positionsKept = 0;
  int booksMarkedCompleted = 0;
  int sessionsImported = 0;
  int daysImported = 0;
  int segmentsWritten = 0;

  /// 用户在 Fushi 里删过这本书的统计（墓碑压制 `startAt < deletedAt`），不写回。
  int segmentsSuppressedByDeletion = 0;

  /// legacy 表里已有同书同日数据（旧的ッツ云同步写进来的）而跳过的记录数
  /// （iOS 按会话计、日记录按天计），跳过是为了不双计。
  int legacyRecordsSkipped = 0;
  bool cancelled = false;
  final List<ExternalReaderImportFailure> failures =
      <ExternalReaderImportFailure>[];
}

typedef ExternalReaderImportProgress =
    void Function(int done, int total, String title);

/// 把一份扫描好的第三方阅读器备份（[ExternalReaderBackup]）落进 Fushi：
/// 书走 [EpubImporter]，阅读位置写 `reader_positions`，统计写 `study_segments`。
///
/// 统计走 `upsertStudySegmentsIfNewer`——同步 / 备份落地外来段的同一原语
/// （LWW + 墓碑门 + Profile 盖戳），所以本服务住在 sync 域。确定性 uid +
/// LWW 让重复导入同一份备份是 no-op；用户在 Fushi 里删掉（写零、`updatedAt`
/// = 删除时刻）的导入会话也不会被再次导入复活。
class ExternalReaderImportService {
  ExternalReaderImportService({required this.db, int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase db;
  final int Function() _clock;

  Future<ExternalReaderImportPreview> preview(
    ExternalReaderBackup backup,
  ) async {
    int newBooks = 0;
    int existingBooks = 0;
    int statsOnlyBooks = 0;
    int statRecords = 0;
    int positions = 0;
    for (final ExternalReaderBook book in backup.books) {
      statRecords += book.sessions.length + book.dailyRecords.length;
      if (await _findExistingKey(book) != null) {
        existingBooks++;
      } else if (!book.isArchived && book.epubEntry != null) {
        newBooks++;
      } else {
        statsOnlyBooks++;
        continue;
      }
      if (book.bookmark != null) positions++;
    }
    final int profileId = await db.resolveActiveProfileId();
    return ExternalReaderImportPreview(
      newBooks: newBooks,
      existingBooks: existingBooks,
      statsOnlyBooks: statsOnlyBooks,
      statRecords: statRecords,
      positions: positions,
      profileName: await _profileName(profileId),
    );
  }

  /// 逐本顺序导入（EPUB 解析会把整本读进内存，并发只会叠加峰值）。
  /// [isCancelled] 在书与书之间检查；已导入的不回滚。
  Future<ExternalReaderImportReport> run(
    ExternalReaderBackup backup, {
    ExternalReaderImportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final ExternalReaderImportReport report = ExternalReaderImportReport();
    final int profileId = await db.resolveActiveProfileId();
    final String profileName = await _profileName(profileId);
    final Set<String> legacyDays = await _legacyDays(profileId);
    final Map<String, int> deletedAtByKey = await _tombstones(profileId);
    final Set<(int, String)> winningDays = _winningDailyRecords(backup.books);

    final Directory tempDir = await Directory.systemTemp.createTemp(
      'fushi_ext_import_',
    );
    try {
      final int total = backup.books.length;
      for (int i = 0; i < total; i++) {
        if (isCancelled?.call() ?? false) {
          report.cancelled = true;
          break;
        }
        final ExternalReaderBook book = backup.books[i];
        onProgress?.call(i, total, book.title);
        await _importOne(
          backup: backup,
          book: book,
          bookIndex: i,
          tempDir: tempDir,
          profileId: profileId,
          profileName: profileName,
          legacyDays: legacyDays,
          deletedAtByKey: deletedAtByKey,
          winningDays: winningDays,
          report: report,
        );
      }
      onProgress?.call(total, total, '');
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException catch (e) {
        // 临时目录清不掉不影响导入结果（系统临时目录会被回收），记一笔即可。
        studyDiag('import', 'temp cleanup failed: $e');
      }
    }
    studyDiag(
      'import',
      'hoshi done: imported=${report.booksImported} '
          'matched=${report.booksMatched} failed=${report.failures.length} '
          'positions=${report.positionsWritten} '
          'sessions=${report.sessionsImported} days=${report.daysImported} '
          'segments=${report.segmentsWritten} '
          'suppressed=${report.segmentsSuppressedByDeletion} '
          'legacySkipped=${report.legacyRecordsSkipped}',
    );
    return report;
  }

  Future<void> _importOne({
    required ExternalReaderBackup backup,
    required ExternalReaderBook book,
    required int bookIndex,
    required Directory tempDir,
    required int profileId,
    required String profileName,
    required Set<String> legacyDays,
    required Map<String, int> deletedAtByKey,
    required Set<(int, String)> winningDays,
    required ExternalReaderImportReport report,
  }) async {
    final String fallbackKey = sanitizeTtuFilename(book.title);
    String bookKey = fallbackKey;
    final String? existingKey = await _findExistingKey(book);
    if (existingKey != null) {
      bookKey = existingKey;
      report.booksMatched++;
    } else if (!book.isArchived && book.epubEntry != null) {
      final String? imported = await _importEpub(
        backup: backup,
        book: book,
        bookIndex: bookIndex,
        tempDir: tempDir,
        report: report,
      );
      if (imported != null) bookKey = imported;
    }

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row != null && !book.isArchived && book.bookmark != null) {
      await _writePosition(book: book, row: row, report: report);
    }

    await _writeStatistics(
      book: book,
      bookIndex: bookIndex,
      target: ExternalReaderSegmentTarget(
        mediaKey: bookKey,
        title: row?.title ?? book.title,
        format: row?.format ?? BookFormat.epub.dbValue,
        profileId: profileId,
        profileName: profileName,
      ),
      extraTitles: <String>{if (row != null) row.title},
      legacyDays: legacyDays,
      deletedAt: deletedAtByKey[bookKey],
      winningDays: winningDays,
      report: report,
    );
  }

  /// 库里已有的同一本书：按 Hoshi 书名（与改过的显示名）的 sanitize 结果对 bookKey。
  Future<String?> _findExistingKey(ExternalReaderBook book) async {
    for (final String? title in <String?>[book.title, book.renamedTitle]) {
      if (title == null) continue;
      final String key = sanitizeTtuFilename(title);
      if (await db.getEpubBook(key) != null) return key;
    }
    return null;
  }

  Future<String?> _importEpub({
    required ExternalReaderBackup backup,
    required ExternalReaderBook book,
    required int bookIndex,
    required Directory tempDir,
    required ExternalReaderImportReport report,
  }) async {
    final String tempPath = p.join(tempDir.path, '$bookIndex.epub');
    try {
      await extractExternalReaderBackupEntry(
        archivePath: backup.archivePath,
        entryName: book.epubEntry!,
        outPath: tempPath,
      );
      // fileName 用书名：OPF 没写标题时 EpubImporter 退回文件名当标题，
      // 这样落库标题与 Hoshi 一致（Hoshi 同样退回源文件名）。
      final String key = await EpubImporter.importFromPath(
        db: db,
        filePath: tempPath,
        fileName: '${book.title}.epub',
        policy: const DuplicatePolicy.skip(),
      );
      report.booksImported++;
      return key;
    } on DuplicateImportCancelledException catch (e) {
      // EPUB 自己的标题与 Hoshi 书名不同、却撞上库里已有的书：那本就是它。
      report.booksMatched++;
      return sanitizeTtuFilename(e.title);
    } catch (e) {
      // 单本失败（坏 EPUB、解析抛 Error 也算）不能中断整份导入：记进报告，
      // 这本书的统计仍按书名挂上。
      report.failures.add(
        ExternalReaderImportFailure(title: book.title, reason: '$e'),
      );
      studyDiag('import', 'hoshi book failed "${book.title}": $e');
      return null;
    } finally {
      final File temp = File(tempPath);
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } on FileSystemException catch (e) {
          // 同上：残留临时文件随整个临时目录一起清。
          studyDiag('import', 'temp epub delete failed: $e');
        }
      }
    }
  }

  /// 阅读位置：只在 Fushi 没有、或 Hoshi 的更新时写。`updatedAt` 用 Hoshi 的
  /// 时刻而不是 now（now 会让旧进度在互联进度同步的「新者胜」里显得最新）；
  /// `charOffset` 显式写 -1——冲突更新只改 companion 里给出的列，不写的话旧的
  /// 精确锚会残留，重开书恢复到旧位置。
  ///
  /// 「读完」与位置取舍无关（BUG-2870）：Fushi 的位置更新、或重复导入同一份备份
  /// 时位置保留不写，但 Hoshi 书签说这本读完了它就是读完了——此前只在写位置的
  /// 分支里判读完，重导一次也补不上漏标的书。
  Future<void> _writePosition({
    required ExternalReaderBook book,
    required EpubBookRow row,
    required ExternalReaderImportReport report,
  }) async {
    final ExternalReaderBookmark bookmark = book.bookmark!;
    final ExternalReaderMappedPosition? mapped = mapExternalReaderBookmark(
      bookmark: bookmark,
      bookInfo: book.bookInfo,
      chapters: parseFushiChapterRefs(row.chaptersJson),
    );
    if (mapped == null) return;
    final int? sourceAt = bookmark.lastModifiedAt ?? book.lastAccessAt;
    if (mapped.completed) {
      final int marked = await db.markEpubBookCompletedIfUnset(
        row.bookKey,
        DateTime.fromMillisecondsSinceEpoch(sourceAt ?? _clock()),
      );
      report.booksMarkedCompleted += marked;
    }
    final String uid = row.uid.isNotEmpty
        ? row.uid
        : (await db.resolveEpubBookUid(row.bookKey) ?? '');
    if (uid.isEmpty) return;
    final ReaderPositionRow? existing = await db.getReaderPosition(uid);
    if (existing != null &&
        (sourceAt == null || existing.updatedAt >= sourceAt)) {
      report.positionsKept++;
      return;
    }
    await db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(uid),
        sectionIndex: Value(mapped.sectionIndex),
        normCharOffset: Value(mapped.normCharOffset),
        charOffset: const Value(-1),
        updatedAt: Value(sourceAt ?? 1),
      ),
    );
    report.positionsWritten++;
  }

  Future<void> _writeStatistics({
    required ExternalReaderBook book,
    required int bookIndex,
    required ExternalReaderSegmentTarget target,
    required Set<String> extraTitles,
    required Set<String> legacyDays,
    required int? deletedAt,
    required Set<(int, String)> winningDays,
    required ExternalReaderImportReport report,
  }) async {
    if (!book.hasStatistics) return;
    final int nowMs = _clock();
    final Set<String> titles = <String>{
      book.title,
      if (book.renamedTitle != null) book.renamedTitle!,
      ...extraTitles,
    };
    bool legacyHas(String dateKey, [String? recordTitle]) {
      if (legacyDays.isEmpty) return false;
      for (final String title in <String>{
        ...titles,
        if (recordTitle != null) recordTitle,
      }) {
        if (legacyDays.contains(_legacyKey(title, dateKey))) return true;
      }
      return false;
    }

    final List<StudySegmentsCompanion> rows = <StudySegmentsCompanion>[];
    int sessions = 0;
    int days = 0;
    for (final ExternalReaderSession session in book.sessions) {
      final String dateKey = FushiDatabase.statDateKeyOf(
        DateTime.fromMillisecondsSinceEpoch(session.startedAt),
      );
      if (legacyHas(dateKey)) {
        report.legacyRecordsSkipped++;
        continue;
      }
      final List<StudySegmentsCompanion> pieces = studySegmentsForSession(
        session,
        target,
      );
      if (pieces.isEmpty) continue;
      sessions++;
      rows.addAll(pieces);
    }
    for (final TtuStatistics record in book.dailyRecords) {
      if (!winningDays.contains((bookIndex, record.dateKey))) continue;
      if (legacyHas(record.dateKey, record.title)) {
        report.legacyRecordsSkipped++;
        continue;
      }
      final List<StudySegmentsCompanion> pieces = studySegmentsForDailyRecord(
        record,
        sourceTitle: book.title,
        target: target,
        nowMs: nowMs,
      );
      if (pieces.isEmpty) continue;
      days++;
      rows.addAll(pieces);
    }

    // 墓碑判据与 DAO 同一（同 Profile 同身份、startAt < deletedAt）：先数出来
    // 进报告，被压制的行也就不必再送进事务。
    final List<StudySegmentsCompanion> writable = <StudySegmentsCompanion>[];
    int suppressed = 0;
    for (final StudySegmentsCompanion row in rows) {
      if (deletedAt != null && row.startAt.value < deletedAt) {
        suppressed++;
      } else {
        writable.add(row);
      }
    }
    if (writable.isNotEmpty) {
      await db.upsertStudySegmentsIfNewer(writable);
    }
    report.sessionsImported += sessions;
    report.daysImported += days;
    report.segmentsWritten += writable.length;
    report.segmentsSuppressedByDeletion += suppressed;
    studyDiag(
      'import',
      'hoshi "${target.mediaKey}": sessions=$sessions days=$days '
          'segments=${writable.length} suppressed=$suppressed',
    );
  }

  /// 同一本书（按 Hoshi 书名）同一天的日记录可能同时出现在书目录和
  /// `statistics_archive/` 里：两份的 uid 种子相同，但时长不同会切出不同片数，
  /// 混写会让多出来的片双计。预先按 (书名, dateKey) 选出 `lastStatisticModified`
  /// 最大的那份，只让它产段。返回 (书下标, dateKey) 胜出集合。
  Set<(int, String)> _winningDailyRecords(List<ExternalReaderBook> books) {
    final Map<String, (int, TtuStatistics)> winners =
        <String, (int, TtuStatistics)>{};
    for (int i = 0; i < books.length; i++) {
      for (final TtuStatistics record in books[i].dailyRecords) {
        final String key = '${books[i].title}\u0000${record.dateKey}';
        final (int, TtuStatistics)? current = winners[key];
        if (current == null ||
            record.lastStatisticModified > current.$2.lastStatisticModified) {
          winners[key] = (i, record);
        }
      }
    }
    return <(int, String)>{
      for (final (int, TtuStatistics) w in winners.values) (w.$1, w.$2.dateKey),
    };
  }

  /// legacy `reading_statistics` 里（当前 Profile 看得见时）有数据的 (书名, 日)。
  Future<Set<String>> _legacyDays(int profileId) async {
    if (!await db.legacyStatsVisibleTo(profileId)) return <String>{};
    final List<ReadingStatisticRow> rows = await db.getAllReadingStatistics();
    return <String>{
      for (final ReadingStatisticRow r in rows)
        if (r.charactersRead > 0 || r.readingTimeMs > 0)
          _legacyKey(r.title, r.dateKey),
    };
  }

  static String _legacyKey(String title, String dateKey) =>
      '$title\u0000$dateKey';

  Future<Map<String, int>> _tombstones(int profileId) async {
    final List<StudySegmentTombstoneRow> tombs = await db
        .getStudySegmentTombstones();
    return <String, int>{
      for (final StudySegmentTombstoneRow t in tombs)
        if (t.profileId == profileId && t.mediaKind == kActivityMediaBook)
          t.mediaKey: t.deletedAt,
    };
  }

  Future<String> _profileName(int profileId) async {
    if (profileId <= 0) return '';
    return (await db.getProfileById(profileId))?.name ?? '';
  }
}
