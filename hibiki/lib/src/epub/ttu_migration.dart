import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:html/parser.dart' as html_parser;

import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/reader_position_repository.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_reader.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/utils.dart';

class TtuMigration {
  static const String _idsKey = 'ttu_migration_book_ids';

  static Future<int> migrateIfNeeded(
    HibikiDatabase db,
    int ttuServerPort,
  ) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    List<int> allIds;
    final String? cachedIdsJson = prefs.getString(_idsKey);
    if (cachedIdsJson != null) {
      allIds = (jsonDecode(cachedIdsJson) as List<dynamic>).cast<int>();
    } else {
      final List<int>? ids = await TtuIdbReader.readAllBookIds(ttuServerPort);
      if (ids == null) {
        debugPrint('[ttu-migration] IDB read failed, will retry next launch');
        return 0;
      }
      if (ids.isEmpty) {
        await prefs.setString(_idsKey, '[]');
        return 0;
      }
      await prefs.setString(_idsKey, jsonEncode(ids));
      allIds = ids;
    }

    int migrated = 0;
    for (final int ttuId in allIds) {
      final String flagKey = 'ttu_migrated_book_$ttuId';
      if (prefs.getBool(flagKey) == true) {
        continue;
      }

      final EpubBookRow? existing = await db.getEpubBook(ttuId);
      if (existing != null) {
        await prefs.setBool(flagKey, true);
        continue;
      }

      try {
        final Map<String, dynamic>? bookData =
            await TtuIdbReader.readBookForMigration(
          ttuBookId: ttuId,
          serverPort: ttuServerPort,
        );
        if (bookData == null) {
          debugPrint('[ttu-migration] book $ttuId: read failed, skip for now');
          continue;
        }

        final String extractDir = await EpubStorage.bookDirectory(ttuId);
        final List<dynamic> sections = bookData['sections'] as List<dynamic>;
        String elementHtml = bookData['elementHtml'] as String;

        final dynamic rawBlobs = bookData['blobsBase64'];
        if (rawBlobs is Map<String, dynamic> && rawBlobs.isNotEmpty) {
          final int written = await _writeBlobs(extractDir, rawBlobs);
          elementHtml = _rewriteBlobRefs(elementHtml);
          final num totalBytes = bookData['blobTotalBytes'] as num? ?? 0;
          debugPrint('[ttu-migration] book $ttuId: wrote $written blobs '
              '(${(totalBytes / 1024).round()} KB)');
        }

        final int actualChapters =
            _writeSectionFiles(extractDir, elementHtml, sections);

        if (bookData['coverImageBase64'] != null) {
          File(p.join(extractDir, 'cover.jpg')).writeAsBytesSync(
              base64Decode(bookData['coverImageBase64'] as String));
        }

        final String chaptersJson = jsonEncode(
          List<Map<String, Object>>.generate(
            actualChapters,
            (i) {
              final File sectionFile =
                  File(p.join(extractDir, 'section_$i.html'));
              final int chars = sectionFile.existsSync()
                  ? _countPlainTextChars(sectionFile.readAsStringSync())
                  : 0;
              return <String, Object>{
                'id': 'section-$i',
                'href': 'section_$i.html',
                'mediaType': 'text/html',
                'characters': chars,
              };
            },
          ),
        );

        final String? tocJson = _buildTocJson(sections, actualChapters);

        await db.into(db.epubBooks).insert(
              EpubBooksCompanion.insert(
                id: Value(ttuId),
                title: bookData['title'] as String? ?? t.untitled,
                epubPath: '',
                extractDir: extractDir,
                chapterCount: actualChapters,
                chaptersJson: chaptersJson,
                tocJson:
                    tocJson != null ? Value(tocJson) : const Value.absent(),
                importedAt: DateTime.now().millisecondsSinceEpoch,
              ),
              mode: InsertMode.insertOrIgnore,
            );

        await _migrateReadingProgress(db, ttuId, bookData, actualChapters);
        await _migrateBookmarks(
          db,
          ttuId,
          bookData,
          bookData['title'] as String? ?? t.untitled,
        );

        await prefs.setBool(flagKey, true);
        await prefs.setBool('ttu_migrated_blobs_$ttuId', true);
        migrated++;
        debugPrint('[ttu-migration] book $ttuId: migrated successfully');
      } catch (e, stack) {
        ErrorLogService.instance.log('TtuMigration.migrate', e, stack);
        debugPrint('[ttu-migration] book $ttuId failed: $e');
      }
    }

    return migrated;
  }

  static int _writeSectionFiles(
    String extractDir,
    String elementHtml,
    List<dynamic> sections,
  ) {
    Directory(extractDir).createSync(recursive: true);

    if (sections.isEmpty) {
      File(p.join(extractDir, 'section_0.html'))
          .writeAsStringSync(_wrapHtml(elementHtml));
      return 1;
    }

    final List<_SectionSpan> spans = <_SectionSpan>[];
    for (int i = 0; i < sections.length; i++) {
      final Map<String, dynamic> sec = sections[i] as Map<String, dynamic>;
      final String ref = sec['reference'] as String? ?? '';
      if (ref.isEmpty) {
        spans.add(const _SectionSpan(start: -1, end: -1));
        continue;
      }
      final RegExp pattern = RegExp('id=["\']${RegExp.escape(ref)}["\']');
      final RegExpMatch? match = pattern.firstMatch(elementHtml);
      if (match == null) {
        spans.add(const _SectionSpan(start: -1, end: -1));
        continue;
      }
      int tagStart = match.start;
      while (tagStart > 0 && elementHtml[tagStart] != '<') {
        tagStart--;
      }
      spans.add(_SectionSpan(start: tagStart, end: -1));
    }

    for (int i = 0; i < spans.length; i++) {
      if (spans[i].start < 0) {
        continue;
      }
      int nextStart = elementHtml.length;
      for (int j = i + 1; j < spans.length; j++) {
        if (spans[j].start >= 0) {
          nextStart = spans[j].start;
          break;
        }
      }
      spans[i] = _SectionSpan(start: spans[i].start, end: nextStart);
    }

    bool anyWritten = false;
    for (int i = 0; i < sections.length; i++) {
      if (spans[i].start >= 0 && spans[i].end > spans[i].start) {
        anyWritten = true;
        break;
      }
    }

    if (!anyWritten) {
      File(p.join(extractDir, 'section_0.html'))
          .writeAsStringSync(_wrapHtml(elementHtml));
      return 1;
    }

    for (int i = 0; i < sections.length; i++) {
      final File file = File(p.join(extractDir, 'section_$i.html'));
      if (spans[i].start >= 0 && spans[i].end > spans[i].start) {
        final String sectionHtml =
            elementHtml.substring(spans[i].start, spans[i].end);
        file.writeAsStringSync(_wrapHtml(sectionHtml));
      } else {
        file.writeAsStringSync(_wrapHtml(''));
      }
    }

    return sections.length;
  }

  static String _wrapHtml(String body) =>
      '<!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
      '</head><body>$body</body></html>';

  static Future<void> _migrateReadingProgress(
    HibikiDatabase db,
    int ttuId,
    Map<String, dynamic> bookData,
    int chapterCount,
  ) async {
    final num progress = bookData['progress'] as num? ?? 0;
    final int lastSection = bookData['lastSectionIndex'] as int? ?? -1;
    if (progress <= 0 && lastSection < 0) return;

    final int section =
        lastSection >= 0 && lastSection < chapterCount ? lastSection : 0;
    final int normOffset = (progress * 10000).round().clamp(0, 10000);

    final ReaderPositionRepository repo = ReaderPositionRepository(db);
    await repo.save(
      ttuBookId: ttuId,
      sectionIndex: section,
      normCharOffset: normOffset,
    );
    debugPrint('[ttu-migration] book $ttuId: restored progress '
        'section=$section offset=$normOffset');
  }

  static Future<void> _migrateBookmarks(
    HibikiDatabase db,
    int ttuId,
    Map<String, dynamic> bookData,
    String bookTitle,
  ) async {
    final dynamic bmRaw = bookData['bookmarkData'];
    if (bmRaw == null) return;

    final BookmarkRepository repo = BookmarkRepository(db);

    if (bmRaw is Map<String, dynamic>) {
      final Bookmark? bm = _tryParseBookmark(bmRaw, ttuId, bookTitle);
      if (bm != null) {
        await repo.addBookmark(ttuId, bm);
        debugPrint('[ttu-migration] book $ttuId: migrated 1 bookmark');
      }
    } else if (bmRaw is List) {
      int count = 0;
      for (final dynamic entry in bmRaw) {
        if (entry is Map<String, dynamic>) {
          final Bookmark? bm = _tryParseBookmark(entry, ttuId, bookTitle);
          if (bm != null) {
            await repo.addBookmark(ttuId, bm);
            count++;
          }
        }
      }
      if (count > 0) {
        debugPrint('[ttu-migration] book $ttuId: migrated $count bookmarks');
      }
    }
  }

  static Bookmark? _tryParseBookmark(
    Map<String, dynamic> raw,
    int ttuId,
    String bookTitle,
  ) {
    final num exploredChars = raw['exploredCharCount'] as num? ?? 0;
    final num progress = raw['progress'] as num? ?? 0;
    if (exploredChars <= 0 && progress <= 0) return null;

    final int sectionIndex = (raw['lastSectionIndex'] as num?)?.toInt() ?? 0;
    final int normOffset = (progress * 10000).round().clamp(0, 10000);

    return Bookmark(
      sectionIndex: sectionIndex,
      normCharOffset: normOffset,
      label: raw['label'] as String? ?? 'ttu bookmark',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['lastBookModified'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      ttuBookId: ttuId,
      bookTitle: bookTitle,
    );
  }

  /// 将 IDB blobs (key→base64) 写入 extractDir/blobs/ 磁盘。
  /// 返回成功写入的文件数。
  static Future<int> _writeBlobs(
    String extractDir,
    Map<String, dynamic> blobsBase64,
  ) async {
    final String blobDir = p.join(extractDir, 'blobs');
    final String canonBlobDir = p.canonicalize(blobDir);
    int written = 0;

    for (final MapEntry<String, dynamic> entry in blobsBase64.entries) {
      final String b64 = entry.value as String? ?? '';
      if (b64.isEmpty) continue;

      final String safeKey = _sanitizeBlobKey(entry.key);
      if (safeKey.isEmpty) continue;

      final String filePath = p.join(blobDir, safeKey);
      final String canonPath = p.canonicalize(filePath);
      if (!p.isWithin(canonBlobDir, canonPath)) {
        debugPrint('[ttu-migration] path traversal blocked: ${entry.key}');
        continue;
      }

      final File file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(b64));
      written++;
    }

    return written;
  }

  /// blob key 中替换 Windows 非法字符，防止文件创建失败。
  static String _sanitizeBlobKey(String key) {
    return key.replaceAll(RegExp(r'[<>:"|?*\\]'), '_');
  }

  /// 将 elementHtml 中 ttu 占位 src 替换为本地 blobs/ 相对路径。
  ///
  /// ttu 的占位格式：data:image/gif;ttu:KEY;base64,<1x1 gif>
  /// 替换为：blobs/KEY（sanitize 后的 key）
  static String _rewriteBlobRefs(String html) {
    return html.replaceAllMapped(
      RegExp('data:image/gif;ttu:([^;]+);base64,[A-Za-z0-9+/=]+'),
      (m) => 'blobs/${_sanitizeBlobKey(m[1]!)}',
    );
  }

  /// 为已迁移但缺失 blobs 的书补提取插画。
  /// 在正常迁移之后调用。
  static Future<int> remediateMissingBlobs(
    HibikiDatabase db,
    int ttuServerPort,
  ) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? cachedIdsJson = prefs.getString(_idsKey);
    if (cachedIdsJson == null) return 0;

    final List<int> allIds =
        (jsonDecode(cachedIdsJson) as List<dynamic>).cast<int>();

    int remediated = 0;
    for (final int ttuId in allIds) {
      final String blobFlag = 'ttu_migrated_blobs_$ttuId';
      if (prefs.getBool(blobFlag) == true) continue;

      final EpubBookRow? existing = await db.getEpubBook(ttuId);
      if (existing == null) continue;

      final Directory blobDir = Directory(p.join(existing.extractDir, 'blobs'));
      if (blobDir.existsSync()) {
        await prefs.setBool(blobFlag, true);
        continue;
      }

      try {
        final Map<String, dynamic>? bookData =
            await TtuIdbReader.readBookForMigration(
          ttuBookId: ttuId,
          serverPort: ttuServerPort,
        );
        if (bookData == null) continue;

        final dynamic rawBlobs = bookData['blobsBase64'];
        if (rawBlobs is! Map<String, dynamic> || rawBlobs.isEmpty) {
          await prefs.setBool(blobFlag, true);
          continue;
        }

        final int written = await _writeBlobs(existing.extractDir, rawBlobs);
        final String rewrittenHtml =
            _rewriteBlobRefs(bookData['elementHtml'] as String);
        final List<dynamic> sections = bookData['sections'] as List<dynamic>;
        _writeSectionFiles(existing.extractDir, rewrittenHtml, sections);

        await prefs.setBool(blobFlag, true);
        remediated++;
        debugPrint('[ttu-migration] book $ttuId: remediated $written blobs');
      } catch (e, stack) {
        ErrorLogService.instance.log('TtuMigration.remediateBlobs', e, stack);
        debugPrint('[ttu-migration] blob remediation $ttuId failed: $e');
      }
    }

    return remediated;
  }

  static String? _buildTocJson(List<dynamic> sections, int actualChapters) {
    final List<Map<String, String?>> entries = <Map<String, String?>>[];
    for (int i = 0; i < sections.length && i < actualChapters; i++) {
      final Map<String, dynamic> sec = sections[i] as Map<String, dynamic>;
      final String label = sec['label'] as String? ?? '';
      final String parentChapter = sec['parentChapter'] as String? ?? '';
      if (label.isEmpty || parentChapter.isNotEmpty) continue;
      entries.add(<String, String?>{
        'title': label,
        'href': 'section_$i.html',
      });
    }
    return entries.isNotEmpty ? jsonEncode(entries) : null;
  }

  /// 为已迁移但缺失 tocJson 的旧书补充章节标题。
  static Future<int> remediateMissingToc(
    HibikiDatabase db,
    int ttuServerPort,
  ) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? cachedIdsJson = prefs.getString(_idsKey);
    if (cachedIdsJson == null) return 0;

    final List<int> allIds =
        (jsonDecode(cachedIdsJson) as List<dynamic>).cast<int>();

    int remediated = 0;
    for (final int ttuId in allIds) {
      final EpubBookRow? existing = await db.getEpubBook(ttuId);
      if (existing == null || existing.tocJson != null) continue;

      try {
        final Map<String, dynamic>? bookData =
            await TtuIdbReader.readBookForMigration(
          ttuBookId: ttuId,
          serverPort: ttuServerPort,
        );
        if (bookData == null) continue;

        final List<dynamic> sections = bookData['sections'] as List<dynamic>;
        final String? tocJson = _buildTocJson(sections, existing.chapterCount);
        if (tocJson == null) continue;

        await (db.update(db.epubBooks)..where((tbl) => tbl.id.equals(ttuId)))
            .write(EpubBooksCompanion(tocJson: Value(tocJson)));

        remediated++;
        debugPrint('[ttu-migration] book $ttuId: remediated TOC');
      } catch (e, stack) {
        ErrorLogService.instance.log('TtuMigration.remediateToc', e, stack);
        debugPrint('[ttu-migration] TOC remediation $ttuId failed: $e');
      }
    }

    return remediated;
  }

  /// Backfill `characters` count in chaptersJson for all epub_books
  /// that are missing it. Reads HTML from extractDir on disk.
  static Future<int> remediateMissingCharacters(HibikiDatabase db) async {
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    int remediated = 0;

    for (final EpubBookRow book in books) {
      if (book.chaptersJson.isEmpty) continue;

      try {
        final List<dynamic> chapters =
            jsonDecode(book.chaptersJson) as List<dynamic>;
        if (chapters.isEmpty) continue;

        final Map<String, dynamic> first = chapters[0] as Map<String, dynamic>;
        if (first.containsKey('characters')) continue;

        final List<Map<String, Object>> updated = <Map<String, Object>>[];
        for (final dynamic ch in chapters) {
          final Map<String, dynamic> map = ch as Map<String, dynamic>;
          final String href = map['href'] as String? ?? '';
          int chars = 0;
          if (href.isNotEmpty) {
            final String filePath =
                p.canonicalize(p.join(book.extractDir, href));
            if (p.isWithin(p.canonicalize(book.extractDir), filePath)) {
              final File file = File(filePath);
              if (file.existsSync()) {
                chars = _countPlainTextChars(file.readAsStringSync());
              }
            }
          }
          updated.add(<String, Object>{
            'id': map['id'] as String? ?? '',
            'href': href,
            'mediaType': map['mediaType'] as String? ?? 'text/html',
            'characters': chars,
          });
        }

        await (db.update(db.epubBooks)..where((tbl) => tbl.id.equals(book.id)))
            .write(
                EpubBooksCompanion(chaptersJson: Value(jsonEncode(updated))));
        remediated++;
      } catch (e, stack) {
        ErrorLogService.instance.log('TtuMigration.remediateChars', e, stack);
      }
    }

    if (remediated > 0) {
      debugPrint(
          '[epub-remediate] backfilled characters for $remediated books');
    }
    return remediated;
  }

  static int _countPlainTextChars(String html) {
    final doc = html_parser.parse(html);
    doc.body?.querySelectorAll('rt, rp, rtc').forEach((el) => el.remove());
    final String raw = doc.body?.text ?? '';
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim().length;
  }
}

class _SectionSpan {
  const _SectionSpan({required this.start, required this.end});
  final int start;
  final int end;
}
