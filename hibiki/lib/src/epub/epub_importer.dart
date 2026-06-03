import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_storage.dart';

class EpubImporter {
  EpubImporter._();

  /// Import an EPUB file into the database.
  ///
  /// Extracts the EPUB to disk, parses metadata, and inserts into EpubBooks.
  /// Returns the book ID on success, or throws on failure (with cleanup).
  static Future<int> import({
    required HibikiDatabase db,
    required Uint8List bytes,
    required String fileName,
    DuplicateTitleCallback? onDuplicateTitle,
  }) async {
    final int tempId = DateTime.now().millisecondsSinceEpoch;
    final String extractDir = await EpubStorage.bookDirectory(tempId);
    int? insertedBookId;

    try {
      // HBK-AUDIT-035: parse AND compute per-chapter character counts inside
      // the isolate. The main isolate only serializes the precomputed ints,
      // so no html_parser.parse() runs on the UI thread per chapter.
      final _ParseResult result = await compute(
        _parseInIsolate,
        _ParseArgs(bytes: bytes, extractDir: extractDir),
      );
      final EpubBook book = result.book;
      final List<int> characterCounts = result.characterCounts;

      final String chaptersJson = jsonEncode(
        book.chapters
            .asMap()
            .entries
            .map((entry) => <String, Object>{
                  'id': entry.value.id,
                  'href': entry.value.href,
                  'mediaType': entry.value.mediaType,
                  'characters': characterCounts[entry.key],
                })
            .toList(),
      );

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
          book.title == p.basenameWithoutExtension(extractDir)
              ? p.basenameWithoutExtension(fileName)
              : book.title;

      final List<EpubBookRow> existingBooks = await db.getAllEpubBooks();
      final String storedTitle = await resolveBookTitleConflict(
        existingTitles: existingBooks.map((EpubBookRow b) => b.title).toList(),
        proposedTitle: resolvedTitle,
        onDuplicateTitle: onDuplicateTitle,
      );

      insertedBookId = await db.into(db.epubBooks).insert(
            EpubBooksCompanion.insert(
              title: storedTitle,
              author: book.author != null
                  ? Value(book.author)
                  : const Value.absent(),
              coverPath: book.coverHref != null
                  ? Value(book.coverHref)
                  : const Value.absent(),
              epubPath: fileName,
              extractDir: extractDir,
              chapterCount: book.chapters.length,
              chaptersJson: chaptersJson,
              tocJson: tocJson != null ? Value(tocJson) : const Value.absent(),
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      // Rename temp directory to actual book ID directory
      if (insertedBookId != tempId) {
        final String realDir = await EpubStorage.bookPath(insertedBookId);
        if (realDir != extractDir) {
          final Directory srcDir = Directory(extractDir);
          if (srcDir.existsSync()) {
            try {
              srcDir.renameSync(realDir);
            } catch (e) {
              ErrorLogService.instance
                  .log('EpubImporter.rename', e, StackTrace.current);
              rethrow;
            }
          }
          await (db.update(db.epubBooks)
                ..where((tbl) => tbl.id.equals(insertedBookId!)))
              .write(EpubBooksCompanion(extractDir: Value(realDir)));
        }
      }

      return insertedBookId;
    } catch (e) {
      if (insertedBookId != null) {
        try {
          await (db.delete(db.epubBooks)
                ..where((tbl) => tbl.id.equals(insertedBookId!)))
              .go();
        } catch (e, stack) {
          ErrorLogService.instance.log('EpubImporter.rollbackDelete', e, stack);
        }
        final String realDir = await EpubStorage.bookPath(insertedBookId);
        _tryDeleteDir(realDir);
      }
      _tryDeleteDir(extractDir);
      rethrow;
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

  /// Import from a file path on disk.
  ///
  /// Preferred over [import] — the file is read inside the isolate,
  /// avoiding a large byte-array copy across the isolate boundary.
  static Future<int> importFromFile({
    required HibikiDatabase db,
    required String filePath,
    DuplicateTitleCallback? onDuplicateTitle,
  }) async {
    return importFromPath(
      db: db,
      filePath: filePath,
      fileName: p.basename(filePath),
      onDuplicateTitle: onDuplicateTitle,
    );
  }

  /// Import an EPUB by file path — reads inside the isolate to reduce
  /// peak memory on the main isolate.
  static Future<int> importFromPath({
    required HibikiDatabase db,
    required String filePath,
    required String fileName,
    DuplicateTitleCallback? onDuplicateTitle,
  }) async {
    final int tempId = DateTime.now().millisecondsSinceEpoch;
    final String extractDir = await EpubStorage.bookDirectory(tempId);
    int? insertedBookId;

    try {
      // HBK-AUDIT-035: parse AND compute per-chapter character counts inside
      // the isolate. The main isolate only serializes the precomputed ints,
      // so no html_parser.parse() runs on the UI thread per chapter.
      final _ParseResult result = await compute(
        _parseFromPathInIsolate,
        _ParseArgsFromPath(filePath: filePath, extractDir: extractDir),
      );
      final EpubBook book = result.book;
      final List<int> characterCounts = result.characterCounts;

      final String chaptersJson = jsonEncode(
        book.chapters
            .asMap()
            .entries
            .map((entry) => <String, Object>{
                  'id': entry.value.id,
                  'href': entry.value.href,
                  'mediaType': entry.value.mediaType,
                  'characters': characterCounts[entry.key],
                })
            .toList(),
      );

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
          book.title == p.basenameWithoutExtension(extractDir)
              ? p.basenameWithoutExtension(fileName)
              : book.title;

      final List<EpubBookRow> existingBooks = await db.getAllEpubBooks();
      final String storedTitle = await resolveBookTitleConflict(
        existingTitles: existingBooks.map((EpubBookRow b) => b.title).toList(),
        proposedTitle: resolvedTitle,
        onDuplicateTitle: onDuplicateTitle,
      );

      insertedBookId = await db.into(db.epubBooks).insert(
            EpubBooksCompanion.insert(
              title: storedTitle,
              author: book.author != null
                  ? Value(book.author)
                  : const Value.absent(),
              coverPath: book.coverHref != null
                  ? Value(book.coverHref)
                  : const Value.absent(),
              epubPath: fileName,
              extractDir: extractDir,
              chapterCount: book.chapters.length,
              chaptersJson: chaptersJson,
              tocJson: tocJson != null ? Value(tocJson) : const Value.absent(),
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      if (insertedBookId != tempId) {
        final String realDir = await EpubStorage.bookPath(insertedBookId);
        if (realDir != extractDir) {
          final Directory srcDir = Directory(extractDir);
          if (srcDir.existsSync()) {
            try {
              srcDir.renameSync(realDir);
            } catch (e) {
              ErrorLogService.instance
                  .log('EpubImporter.rename', e, StackTrace.current);
              rethrow;
            }
          }
          await (db.update(db.epubBooks)
                ..where((tbl) => tbl.id.equals(insertedBookId!)))
              .write(EpubBooksCompanion(extractDir: Value(realDir)));
        }
      }

      return insertedBookId;
    } catch (e) {
      if (insertedBookId != null) {
        try {
          await (db.delete(db.epubBooks)
                ..where((tbl) => tbl.id.equals(insertedBookId!)))
              .go();
        } catch (e, stack) {
          ErrorLogService.instance.log('EpubImporter.rollbackDelete', e, stack);
        }
        final String realDir = await EpubStorage.bookPath(insertedBookId);
        _tryDeleteDir(realDir);
      }
      _tryDeleteDir(extractDir);
      rethrow;
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
List<int> _computeCharacterCounts(EpubBook book) {
  return List<int>.generate(
    book.chapters.length,
    (int index) => book.chapterPlainText(index).length,
    growable: false,
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
