import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/collection_exporter.dart';

/// TODO-829 收藏句/词导出器纯函数单测。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  const String bom = '﻿';

  List<ExportSentence> sampleSentences() => <ExportSentence>[
        ExportSentence(
          text: '吾輩は猫である。',
          bookTitle: '吾輩は猫である',
          chapterLabel: '第一章',
          source: 'book',
          createdAt: DateTime(2026, 6, 20, 9, 5),
        ),
        ExportSentence(
          text: '名前はまだ無い。',
          bookTitle: '吾輩は猫である',
          source: 'audiobook',
          createdAt: DateTime(2026, 6, 21, 10, 30),
        ),
        ExportSentence(
          text: '走れメロス。',
          bookTitle: '走れメロス',
          chapterLabel: null,
          source: 'video',
          createdAt: DateTime(2026, 6, 22, 8),
        ),
      ];

  List<ExportWord> sampleWords() => <ExportWord>[
        ExportWord(
          expression: '猫',
          reading: 'ねこ',
          glossary: 'cat',
          sourceType: 'book',
          createdAt: DateTime(2026, 6, 20, 9),
        ),
        ExportWord(
          expression: '走る',
          reading: '',
          glossary: '',
          sourceType: 'video',
          createdAt: DateTime(2026, 6, 21, 9),
        ),
      ];

  group('exportFileMeta', () {
    test('extension and mime per format', () {
      expect(exportFileMeta(ExportFormat.markdown).extension, 'md');
      expect(exportFileMeta(ExportFormat.txt).extension, 'txt');
      expect(exportFileMeta(ExportFormat.csv).extension, 'csv');
      expect(exportFileMeta(ExportFormat.json).extension, 'json');
      expect(exportFileMeta(ExportFormat.json).mimeType, 'application/json');
    });
  });

  group('buildSentenceExport BOM 仅 CSV', () {
    test('only CSV carries the UTF-8 BOM', () {
      final List<ExportSentence> s = sampleSentences();
      expect(buildSentenceExport(s, format: ExportFormat.csv).startsWith(bom),
          isTrue);
      expect(
          buildSentenceExport(s, format: ExportFormat.markdown)
              .startsWith(bom),
          isFalse);
      expect(buildSentenceExport(s, format: ExportFormat.txt).startsWith(bom),
          isFalse);
      expect(buildSentenceExport(s, format: ExportFormat.json).startsWith(bom),
          isFalse);
    });

    test('csvBom:false suppresses BOM', () {
      final String csv = buildSentenceExport(
        sampleSentences(),
        format: ExportFormat.csv,
        csvBom: false,
      );
      expect(csv.startsWith(bom), isFalse);
      expect(csv.startsWith('text,'), isTrue);
    });
  });

  group('buildSentenceExport markdown', () {
    test('groups by bookTitle (not bookKey) preserving order', () {
      final String md =
          buildSentenceExport(sampleSentences(), format: ExportFormat.markdown);
      expect(md, contains('## 吾輩は猫である'));
      expect(md, contains('## 走れメロス'));
      // 吾輩は猫である 组在前。
      expect(md.indexOf('## 吾輩は猫である'), lessThan(md.indexOf('## 走れメロス')));
      // 同一本书的两句都在第一个分组下，不另起书名。
      expect('## 吾輩は猫である'.allMatches(md).length, 1);
      expect(md, contains('> 吾輩は猫である。'));
      expect(md, contains('第一章'));
    });

    test('video-source sentence keeps a non-empty, non-placeholder title', () {
      final String md =
          buildSentenceExport(sampleSentences(), format: ExportFormat.markdown);
      // video 来源句标题来自 bookTitle，非空、非占位。
      expect(md, contains('## 走れメロス'));
      expect(md, isNot(contains('## null')));
      expect(md, isNot(contains('##  '))); // 没有空标题
    });
  });

  group('null bookKey 不塌桶不丢条', () {
    test('two books with null bookKey stay in separate title groups', () {
      final List<ExportSentence> s = <ExportSentence>[
        ExportSentence(
          text: 'A 书的句子',
          bookTitle: '书 A',
          source: 'lyrics', // 歌词来源 bookKey 恒 null
          createdAt: DateTime(2026, 1, 1),
        ),
        ExportSentence(
          text: 'B 书的句子',
          bookTitle: '书 B',
          source: 'lyrics',
          createdAt: DateTime(2026, 1, 2),
        ),
      ];
      final String md = buildSentenceExport(s, format: ExportFormat.markdown);
      expect(md, contains('## 书 A'));
      expect(md, contains('## 书 B'));
      expect(md, contains('A 书的句子'));
      expect(md, contains('B 书的句子'));
      // 两条都在，没被塞进同一个 null 桶。
      final String json = buildSentenceExport(s, format: ExportFormat.json);
      final List<dynamic> decoded = jsonDecode(json) as List<dynamic>;
      expect(decoded.length, 2);
    });
  });

  group('buildSentenceExport csv', () {
    test('escapes commas, quotes and newlines (RFC4180)', () {
      final List<ExportSentence> s = <ExportSentence>[
        ExportSentence(
          text: 'a,b "c"\nd',
          bookTitle: 'Book, 1',
          source: 'book',
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final String csv =
          buildSentenceExport(s, format: ExportFormat.csv, csvBom: false);
      expect(csv, contains('"a,b ""c""\nd"'));
      expect(csv, contains('"Book, 1"'));
      // CRLF 行尾。
      expect(csv, contains('\r\n'));
    });
  });

  group('buildSentenceExport json', () {
    test('omits nullable fields and round-trips', () {
      final String json =
          buildSentenceExport(sampleSentences(), format: ExportFormat.json);
      final List<dynamic> decoded = jsonDecode(json) as List<dynamic>;
      expect(decoded.length, 3);
      final Map<String, dynamic> second = decoded[1] as Map<String, dynamic>;
      // 第二句无 chapterLabel → JSON 省略该键。
      expect(second.containsKey('chapterLabel'), isFalse);
      expect(second['text'], '名前はまだ無い。');
      expect(second['source'], 'audiobook');
    });
  });

  group('buildSentenceExport txt', () {
    test('one sentence per line, no BOM', () {
      final String txt =
          buildSentenceExport(sampleSentences(), format: ExportFormat.txt);
      final List<String> lines = const LineSplitter().convert(txt);
      expect(lines, contains('吾輩は猫である。'));
      expect(lines, contains('走れメロス。'));
      expect(lines.length, 3);
    });
  });

  group('buildWordExport', () {
    test('groups by sourceType, only CSV has BOM, json round-trips', () {
      final List<ExportWord> w = sampleWords();
      final String md = buildWordExport(w, format: ExportFormat.markdown);
      expect(md, contains('## book'));
      expect(md, contains('## video'));
      expect(md, contains('**猫**（ねこ）'));
      // reading 为空时不带括号。
      expect(md, contains('**走る**'));
      expect(md, isNot(contains('**走る**（')));

      expect(buildWordExport(w, format: ExportFormat.csv).startsWith(bom),
          isTrue);
      expect(buildWordExport(w, format: ExportFormat.json).startsWith(bom),
          isFalse);

      final List<dynamic> decoded =
          jsonDecode(buildWordExport(w, format: ExportFormat.json))
              as List<dynamic>;
      expect(decoded.length, 2);
      expect((decoded[0] as Map<String, dynamic>)['expression'], '猫');
    });
  });

  group('empty collections', () {
    test('empty sentence list yields title-only / empty content', () {
      expect(buildSentenceExport(<ExportSentence>[], format: ExportFormat.txt),
          isEmpty);
      final String json =
          buildSentenceExport(<ExportSentence>[], format: ExportFormat.json);
      expect(jsonDecode(json), isEmpty);
      final String csv = buildSentenceExport(
        <ExportSentence>[],
        format: ExportFormat.csv,
        csvBom: false,
      );
      // 仅表头。
      expect(const LineSplitter().convert(csv).length, 1);
    });
  });
}
