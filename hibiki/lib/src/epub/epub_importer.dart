import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/epub/epub_book.dart';
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
  }) async {
    final int tempId = DateTime.now().millisecondsSinceEpoch;
    final String extractDir = await EpubStorage.bookDirectory(tempId);

    try {
      final EpubBook book = await compute(
        _parseInIsolate,
        _ParseArgs(bytes: bytes, extractDir: extractDir),
      );

      final String chaptersJson = jsonEncode(
        book.chapters
            .map((EpubChapter ch) => <String, Object>{
                  'id': ch.id,
                  'href': ch.href,
                  'mediaType': ch.mediaType,
                })
            .toList(),
      );

      final String? tocJson = book.toc.isNotEmpty
          ? jsonEncode(
              book.toc
                  .map((EpubTocItem e) => <String, Object?>{
                        'title': e.label,
                        'href': e.href,
                      })
                  .toList(),
            )
          : null;

      final int bookId = await db.into(db.epubBooks).insert(
            EpubBooksCompanion.insert(
              title: book.title,
              author: book.author != null ? Value(book.author!) : const Value.absent(),
              coverPath: book.coverHref != null ? Value(book.coverHref!) : const Value.absent(),
              epubPath: fileName,
              extractDir: extractDir,
              chapterCount: book.chapters.length,
              chaptersJson: chaptersJson,
              tocJson: tocJson != null ? Value(tocJson) : const Value.absent(),
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      // Rename temp directory to actual book ID directory
      if (bookId != tempId) {
        final String realDir = await EpubStorage.bookDirectory(bookId);
        if (realDir != extractDir) {
          final Directory srcDir = Directory(extractDir);
          if (srcDir.existsSync()) {
            srcDir.renameSync(realDir);
          }
          await (db.update(db.epubBooks)..where((tbl) => tbl.id.equals(bookId)))
              .write(EpubBooksCompanion(extractDir: Value(realDir)));
        }
      }

      return bookId;
    } catch (e) {
      final Directory dir = Directory(extractDir);
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Import from a file path on disk.
  static Future<int> importFromFile({
    required HibikiDatabase db,
    required String filePath,
  }) async {
    final File file = File(filePath);
    final Uint8List bytes = file.readAsBytesSync();
    return import(
      db: db,
      bytes: bytes,
      fileName: p.basename(filePath),
    );
  }
}

class _ParseArgs {
  const _ParseArgs({required this.bytes, required this.extractDir});
  final Uint8List bytes;
  final String extractDir;
}

EpubBook _parseInIsolate(_ParseArgs args) {
  return EpubParser.parseSync(args.bytes, args.extractDir);
}
