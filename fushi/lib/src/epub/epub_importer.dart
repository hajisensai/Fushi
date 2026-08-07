import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_time_format.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/epub/epub_storage.dart';

class EpubImporter {
  EpubImporter._();

  /// Import an EPUB file into the database.
  ///
  /// Extracts the EPUB to disk, parses metadata, and inserts into EpubBooks.
  /// Returns the bookKey (the primary key = sanitized title) on success, or
  /// throws on failure (with cleanup).
  static Future<String> import({
    required FushiDatabase db,
    required Uint8List bytes,
    required String fileName,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
  }) async {
    final int tempId = DateTime.now().millisecondsSinceEpoch;
    final String tempDir = await EpubStorage.bookDirectory('.tmp-$tempId');

    final _ParseResult result = await compute(
      _parseInIsolate,
      _ParseArgs(bytes: bytes, extractDir: tempDir),
    );
    return _persistParsed(
      db: db,
      result: result,
      fileName: fileName,
      tempDir: tempDir,
      policy: policy,
    );
  }

  /// Import from a file path on disk.
  ///
  /// Preferred over [import] — the file is read inside the isolate,
  /// avoiding a large byte-array copy across the isolate boundary.
  static Future<String> importFromFile({
    required FushiDatabase db,
    required String filePath,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
  }) async {
    return importFromPath(
      db: db,
      filePath: filePath,
      fileName: p.basename(filePath),
      policy: policy,
    );
  }

  /// Import an EPUB by file path — reads inside the isolate to reduce
  /// peak memory on the main isolate.
  static Future<String> importFromPath({
    required FushiDatabase db,
    required String filePath,
    required String fileName,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    int? sourceId,
  }) async {
    final int tempId = DateTime.now().millisecondsSinceEpoch;
    final String tempDir = await EpubStorage.bookDirectory('.tmp-$tempId');

    final _ParseResult result = await compute(
      _parseFromPathInIsolate,
      _ParseArgsFromPath(filePath: filePath, extractDir: tempDir),
    );
    return _persistParsed(
      db: db,
      result: result,
      fileName: fileName,
      tempDir: tempDir,
      policy: policy,
      sourceId: sourceId,
    );
  }

  /// Shared post-parse persistence: resolve the title conflict, derive the
  /// bookKey (= sanitized stored title), move the freshly-extracted [tempDir]
  /// to the key-named directory, and insert the EpubBooks row. Returns the
  /// bookKey. On any failure cleans up the row + extracted directories.
  ///
  /// The temp directory is extracted under a `.tmp-<ts>` name BEFORE the title
  /// is known (parsing needs the on-disk extraction); once the unique stored
  /// title is resolved we move it to `bookDirectory(bookKey)` so the on-disk
  /// folder name matches the primary key for freshly-imported books.
  static Future<String> _persistParsed({
    required FushiDatabase db,
    required _ParseResult result,
    required String fileName,
    required String tempDir,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    int? sourceId,
  }) async {
    String? insertedKey;
    String extractDir = tempDir;
    try {
      final EpubBook book = result.book;
      final List<int> characterCounts = result.characterCounts;

      final String chaptersJson = buildChaptersJson(book, characterCounts);

      final String? tocJson = book.toc.isNotEmpty
          ? jsonEncode(
              book.toc
                  .map((e) => <String, Object?>{
                        'title': e.label,
                        'href': e.href,
                      })
                  .toList(),
            )
          : null;

      final String resolvedTitle =
          book.title == p.basenameWithoutExtension(tempDir)
              ? p.basenameWithoutExtension(fileName)
              : book.title;

      final List<EpubBookRow> existingBooks = await db.getAllEpubBooks();
      final String storedTitle = await resolveDuplicateTitle(
        existingTitles: existingBooks.map((EpubBookRow b) => b.title).toList(),
        proposedTitle: resolvedTitle,
        policy: policy,
      );

      // bookKey is the EpubBooks primary key (= sanitized stored title). It is
      // unique by construction (resolveDuplicateTitle guarantees no two
      // local books share a sanitized key).
      final String bookKey = sanitizeTtuFilename(storedTitle);

      // Move the freshly-extracted temp dir to the key-named directory.
      //
      // BUG-564: the target dir may already exist on disk even though no live
      // row owns the key (resolveDuplicateTitle guarantees key uniqueness
      // against live rows): a crashed import or a failed post-delete disk
      // cleanup leaves an orphan dir, and Linux rename(2) onto a non-empty
      // target throws ENOTEMPTY (errno 39) -- e.g. re-downloading a remote
      // book whose previous copy left a stale folder. Resolved by
      // [moveExtractedDirIntoPlace] (atomic replace with .bak rollback;
      // directories owned by a live row are never touched).
      final String realDir = await EpubStorage.bookPath(bookKey);
      if (realDir != tempDir) {
        final Directory srcDir = Directory(tempDir);
        if (srcDir.existsSync()) {
          try {
            extractDir = moveExtractedDirIntoPlace(
              srcDir: srcDir,
              targetDir: realDir,
              liveExtractDirs:
                  existingBooks.map((EpubBookRow b) => b.extractDir),
            );
          } catch (e) {
            ErrorLogService.instance
                .log('EpubImporter.rename', e, StackTrace.current);
            rethrow;
          }
        } else {
          extractDir = realDir;
        }
      }

      final int importedAtMs = DateTime.now().millisecondsSinceEpoch;
      insertedKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: storedTitle,
          author:
              book.author != null ? Value(book.author) : const Value.absent(),
          coverPath: book.coverHref != null
              ? Value(book.coverHref)
              : const Value.absent(),
          epubPath: fileName,
          extractDir: extractDir,
          chapterCount: book.chapters.length,
          chaptersJson: chaptersJson,
          tocJson: tocJson != null ? Value(tocJson) : const Value.absent(),
          importedAt: importedAtMs,
          // TODO-817 M1b：扫描器入库时回填来源库 id；手动导入 sourceId==null
          // → Value.absent() 落 NULL（向后兼容）。
          sourceId: sourceId != null ? Value(sourceId) : const Value.absent(),
        ),
      );

      // v49：导入一本书写一条「added」活动事件，喂首页 Activity 时间轴。放用户导入
      // 管线（本方法），云同步/备份 MERGE 直接插行不经此路 → 不刷屏。best-effort，
      // 记账失败不影响书已导入。
      try {
        await db.addActivityEvent(
          eventType: kActivityAdded,
          mediaType: kActivityMediaBook,
          title: storedTitle,
          mediaKey: bookKey,
          dateKey: FushiTimeFormat.dayKey(
              DateTime.fromMillisecondsSinceEpoch(importedAtMs)),
          timestampMs: importedAtMs,
        );
      } catch (e) {
        ErrorLogService.instance
            .log('EpubImporter.addActivityEvent', e, StackTrace.current);
      }

      return insertedKey;
    } catch (e) {
      if (insertedKey != null) {
        try {
          await db.deleteEpubBook(insertedKey);
        } catch (e, stack) {
          ErrorLogService.instance.log('EpubImporter.rollbackDelete', e, stack);
        }
      }
      _tryDeleteDir(extractDir);
      _tryDeleteDir(tempDir);
      rethrow;
    }
  }

  /// `EpubBooks.chaptersJson` 的**唯一**序列化口径：每章 `id`/`href`/`mediaType`/
  /// `characters` + 计数口径版本 [kChapterCharCountCaliber]。
  ///
  /// 公开是给「漫画 → 书」转化用的（`book_format_rebuild.dart`）：转成漫画时这一列
  /// 被写成 `'[]'`，转回来只能由重新解析解压树重建。两处各写一份 JSON 结构，字段名
  /// 或 charCaliber 漂一个字，书架字数与 TODO-1192 的口径重算就同时坏掉。
  static String buildChaptersJson(EpubBook book, List<int> characterCounts) {
    return jsonEncode(
      book.chapters
          .asMap()
          .entries
          .map((entry) => <String, Object>{
                'id': entry.value.id,
                'href': entry.value.href,
                'mediaType': entry.value.mediaType,
                'characters': characterCounts[entry.key],
                // TODO-1192: 标记该 characters 计数的口径版本，供开书判定是否需
                // 要按新口径（[japaneseCharCount]）后台重算并回写（见
                // [kChapterCharCountCaliber] / charCountsFromChaptersJson）。
                'charCaliber': kChapterCharCountCaliber,
              })
          .toList(),
    );
  }

  /// 重新解析**已解压**的书目录 [extractDir]，返回 `(chapterCount, chaptersJson,
  /// coverPath)` 三件套。
  ///
  /// 用于「漫画 → 书」转回：本仓的 EPUB 在盘上只有解压树、没有独立 `.epub`
  /// （BUG-088），所以「撤销」不存在——只能拿解压树重新算一遍。DOM 解析与字数统计
  /// 放 isolate（与导入同款 [compute]），不卡 UI。
  static Future<({int chapterCount, String chaptersJson, String? coverPath})>
      reparseExtractedBook(String extractDir) async {
    final _ParseResult result =
        await compute(_reparseExtractedInIsolate, extractDir);
    return (
      chapterCount: result.book.chapters.length,
      chaptersJson: buildChaptersJson(result.book, result.characterCounts),
      coverPath: result.book.coverHref,
    );
  }

  /// Move the freshly-extracted [srcDir] to [targetDir]; returns the
  /// directory that finally holds the content (stored as `extract_dir`).
  ///
  /// [targetDir] may already exist on disk (BUG-564). Semantics:
  /// - target missing -> move [srcDir] into place (the normal path);
  /// - target listed in [liveExtractDirs] (some live book's `extract_dir`
  ///   points at it -- the column, not the folder name, is the truth for
  ///   existing books) -> never touch it; the new book moves to a unique
  ///   sibling `<targetDir>~<n>` instead;
  /// - target exists but is unowned (leftover of a crashed import / a failed
  ///   post-delete disk cleanup) -> atomic replace: rename it aside to a
  ///   `.bak-<ts>` sibling, move [srcDir] into place, then delete the .bak.
  ///   If the move fails the .bak is renamed back (rollback), so the previous
  ///   content is never lost mid-way. Never delete-then-rename directly: a
  ///   crash in between would lose both copies.
  ///
  /// TODO-1286: every `.tmp-<ts>` -> destination move goes through
  /// [_moveDirInto], which falls back to a recursive copy+delete when the
  /// platform rejects `rename(2)`. Android's app-storage layer (fuse/sdcardfs
  /// and custom data roots on removable volumes) can reject a directory rename
  /// even for a vacated same-parent sibling (`FileSystemException: Rename
  /// failed, path = '.../fushi_books/.tmp-<ts>'`); a bare `renameSync` there
  /// aborts the whole remote-book download, so the audiobook never downloads
  /// and the shelf/sync marker never updates. Copy+delete is the portable move
  /// primitive and cannot fail with ENOTEMPTY/ENOTDIR/EXDEV the way rename can.
  @visibleForTesting
  static String moveExtractedDirIntoPlace({
    required Directory srcDir,
    required String targetDir,
    required Iterable<String> liveExtractDirs,
    bool forceCopyFallback = false,
  }) {
    final Directory target = Directory(targetDir);
    if (!target.existsSync()) {
      _moveDirInto(srcDir, targetDir, forceCopy: forceCopyFallback);
      return targetDir;
    }

    final String canonicalTarget = p.canonicalize(targetDir);
    final bool owned = liveExtractDirs.any((String dir) =>
        dir.isNotEmpty && p.canonicalize(dir) == canonicalTarget);
    if (owned) {
      for (int i = 2;; i++) {
        final String alt = '$targetDir~$i';
        if (!Directory(alt).existsSync()) {
          _moveDirInto(srcDir, alt, forceCopy: forceCopyFallback);
          return alt;
        }
      }
    }

    final String bak =
        '$targetDir.bak-${DateTime.now().millisecondsSinceEpoch}';
    target.renameSync(bak);
    try {
      _moveDirInto(srcDir, targetDir, forceCopy: forceCopyFallback);
    } catch (_) {
      // [_moveDirInto] cleans up any partial destination on failure, so the
      // target path is clean here and the .bak restore lands on empty ground.
      try {
        Directory(bak).renameSync(targetDir);
      } catch (rollbackError, stack) {
        ErrorLogService.instance
            .log('EpubImporter.replaceRollback', rollbackError, stack);
      }
      rethrow;
    }
    try {
      Directory(bak).deleteSync(recursive: true);
    } catch (e, stack) {
      // A leftover .bak dir is inert (never a future rename target); log it.
      ErrorLogService.instance.log('EpubImporter.deleteBak', e, stack);
    }
    return targetDir;
  }

  /// Move [src] to [dest] (which MUST NOT exist). Tries `rename(2)` first and,
  /// when the platform rejects it (`FileSystemException`), falls back to a
  /// recursive copy + delete of the source. On a mid-copy failure the partial
  /// [dest] is removed so callers can safely roll back onto a clean path.
  ///
  /// [forceCopy] is a test seam: when true the rename attempt is skipped and
  /// the copy+delete branch is exercised deterministically (real `rename(2)`
  /// failures are not portably reproducible in unit tests).
  static void _moveDirInto(
    Directory src,
    String dest, {
    bool forceCopy = false,
  }) {
    if (!forceCopy) {
      try {
        src.renameSync(dest);
        return;
      } on FileSystemException catch (e) {
        // Rename rejected (Android fuse/sdcardfs, custom data root on another
        // volume, or a residual target): fall through to copy+delete.
        ErrorLogService.instance
            .log('EpubImporter.moveDirCopyFallback', e, StackTrace.current);
      }
    }
    final Directory destDir = Directory(dest);
    try {
      _copyDirSync(src, destDir);
      src.deleteSync(recursive: true);
    } catch (_) {
      // Remove the partially-copied destination so callers see a clean path.
      try {
        if (destDir.existsSync()) destDir.deleteSync(recursive: true);
      } catch (cleanupError, stack) {
        ErrorLogService.instance
            .log('EpubImporter.moveDirCleanup', cleanupError, stack);
      }
      rethrow;
    }
  }

  /// Recursively copy the contents of [src] into [dest] (created if missing).
  /// EPUB extraction produces only regular files and directories; any other
  /// entity type (e.g. a symlink) is skipped rather than followed.
  static void _copyDirSync(Directory src, Directory dest) {
    dest.createSync(recursive: true);
    for (final FileSystemEntity entity in src.listSync(followLinks: false)) {
      final String destPath = p.join(dest.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirSync(entity, Directory(destPath));
      } else if (entity is File) {
        entity.copySync(destPath);
      }
    }
  }

  static void _tryDeleteDir(String path) {
    final Directory dir = Directory(path);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e, stack) {
        ErrorLogService.instance.log('EpubImporter.cleanupDir', e, stack);
      }
    }
  }
}

class _ParseArgs {
  const _ParseArgs({required this.bytes, required this.extractDir});
  final Uint8List bytes;
  final String extractDir;
}

class _ParseArgsFromPath {
  const _ParseArgsFromPath({required this.filePath, required this.extractDir});
  final String filePath;
  final String extractDir;
}

/// HBK-AUDIT-035: result carried back from the parse isolate — the parsed
/// [book] plus per-chapter plain-text character counts computed in-isolate.
class _ParseResult {
  const _ParseResult({required this.book, required this.characterCounts});
  final EpubBook book;
  final List<int> characterCounts;
}

/// Compute the per-chapter character counts inside the isolate so the
/// expensive html_parser DOM build never runs on the main/UI isolate.
///
/// TODO-1192: 口径改为 [EpubBook.chapterCharacterCount]（只数假名/汉字/字母数字，
/// 剔标点/括号/空白），与 hoshi 对齐；落库时同时打 [kChapterCharCountCaliber]。
List<int> _computeCharacterCounts(EpubBook book) {
  return List<int>.generate(
    book.chapters.length,
    (int index) => book.chapterCharacterCount(index),
    growable: false,
  );
}

/// 解析一个**已经解压好**的书目录（不解压、不写盘），供「漫画 → 书」转回重算
/// 章节与字数。
_ParseResult _reparseExtractedInIsolate(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  return _ParseResult(
    book: book,
    characterCounts: _computeCharacterCounts(book),
  );
}

_ParseResult _parseInIsolate(_ParseArgs args) {
  final EpubBook book = EpubParser.parseSync(args.bytes, args.extractDir);
  return _ParseResult(
    book: book,
    characterCounts: _computeCharacterCounts(book),
  );
}

_ParseResult _parseFromPathInIsolate(_ParseArgsFromPath args) {
  final EpubBook book =
      EpubParser.parseSyncFromPath(args.filePath, args.extractDir);
  return _ParseResult(
    book: book,
    characterCounts: _computeCharacterCounts(book),
  );
}
