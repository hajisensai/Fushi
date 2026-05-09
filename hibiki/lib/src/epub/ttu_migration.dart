import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_reader.dart';

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
      final List<int>? ids =
          await TtuIdbReader.readAllBookIds(ttuServerPort);
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
        final List<dynamic> sections =
            bookData['sections'] as List<dynamic>;
        final String elementHtml = bookData['elementHtml'] as String;

        _writeSectionFiles(extractDir, elementHtml, sections);

        if (bookData['coverImageBase64'] != null) {
          File(p.join(extractDir, 'cover.jpg')).writeAsBytesSync(
              base64Decode(bookData['coverImageBase64'] as String));
        }

        final String chaptersJson = jsonEncode(
          List<Map<String, Object>>.generate(
            sections.length,
            (i) => <String, Object>{
              'id': 'section-$i',
              'href': 'section_$i.html',
              'mediaType': 'text/html',
            },
          ),
        );

        await db.into(db.epubBooks).insert(
              EpubBooksCompanion.insert(
                id: Value(ttuId),
                title: bookData['title'] as String? ?? 'Untitled',
                epubPath: '',
                extractDir: extractDir,
                chapterCount: sections.length,
                chaptersJson: chaptersJson,
                importedAt: DateTime.now().millisecondsSinceEpoch,
              ),
              mode: InsertMode.insertOrIgnore,
            );

        await prefs.setBool(flagKey, true);
        migrated++;
        debugPrint('[ttu-migration] book $ttuId: migrated successfully');
      } catch (e) {
        debugPrint('[ttu-migration] book $ttuId failed: $e');
      }
    }

    return migrated;
  }

  static void _writeSectionFiles(
    String extractDir,
    String elementHtml,
    List<dynamic> sections,
  ) {
    Directory(extractDir).createSync(recursive: true);

    if (sections.isEmpty) {
      File(p.join(extractDir, 'section_0.html'))
          .writeAsStringSync(_wrapHtml(elementHtml));
      return;
    }

    final List<_SectionSpan> spans = <_SectionSpan>[];
    for (int i = 0; i < sections.length; i++) {
      final Map<String, dynamic> sec =
          sections[i] as Map<String, dynamic>;
      final String ref = sec['reference'] as String? ?? '';
      if (ref.isEmpty) {
        spans.add(const _SectionSpan(start: -1, end: -1));
        continue;
      }
      final RegExp pattern =
          RegExp('id=["\']${RegExp.escape(ref)}["\']');
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
      final File file = File(p.join(extractDir, 'section_$i.html'));
      if (spans[i].start >= 0 && spans[i].end > spans[i].start) {
        final String sectionHtml =
            elementHtml.substring(spans[i].start, spans[i].end);
        file.writeAsStringSync(_wrapHtml(sectionHtml));
        anyWritten = true;
      } else {
        file.writeAsStringSync(_wrapHtml(''));
      }
    }

    if (!anyWritten) {
      File(p.join(extractDir, 'section_0.html'))
          .writeAsStringSync(_wrapHtml(elementHtml));
    }
  }

  static String _wrapHtml(String body) =>
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      ' <body>$body</body></html>';
}

class _SectionSpan {
  const _SectionSpan({required this.start, required this.end});
  final int start;
  final int end;
}
