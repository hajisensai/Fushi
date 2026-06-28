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
          buildSentenceExport(s, format: ExportFormat.markdown).startsWith(bom),
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

      expect(
          buildWordExport(w, format: ExportFormat.csv).startsWith(bom), isTrue);
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

  List<ExportMinedSentence> sampleMined() => <ExportMinedSentence>[
        ExportMinedSentence(
          sentence: '吾輩は猫である。',
          expression: '猫',
          reading: 'ねこ',
          glossary: 'cat',
          bookTitle: '吾輩は猫である',
          source: 'book',
          createdAt: DateTime(2026, 6, 20, 9, 5),
        ),
        ExportMinedSentence(
          sentence: 'カンマ, と "引用" を含む',
          expression: '引用',
          reading: 'いんよう',
          glossary: 'quote',
          bookTitle: '吾輩は猫である',
          source: 'book',
          createdAt: DateTime(2026, 6, 21, 10, 30),
        ),
      ];

  group('buildMinedExport', () {
    test('BOM 仅 CSV 带，其它格式不带', () {
      final List<ExportMinedSentence> m = sampleMined();
      expect(buildMinedExport(m, format: ExportFormat.csv).startsWith(bom),
          isTrue);
      expect(
          buildMinedExport(m, format: ExportFormat.csv, csvBom: false)
              .startsWith(bom),
          isFalse);
      expect(buildMinedExport(m, format: ExportFormat.json).startsWith(bom),
          isFalse);
      expect(buildMinedExport(m, format: ExportFormat.markdown).startsWith(bom),
          isFalse);
      expect(buildMinedExport(m, format: ExportFormat.txt).startsWith(bom),
          isFalse);
    });

    test('csv 表头 + 逗号/引号字段转义', () {
      final String csv = buildMinedExport(
        sampleMined(),
        format: ExportFormat.csv,
        csvBom: false,
      );
      final List<String> lines = const LineSplitter().convert(csv);
      expect(
          lines.first, 'sentence,expression,reading,glossary,source,createdAt');
      // 含逗号与引号的整句必须被双引号包裹且内部引号翻倍。
      expect(csv, contains('"カンマ, と ""引用"" を含む"'));
    });

    test('json 含 sentence + expression/reading/glossary', () {
      final String json =
          buildMinedExport(sampleMined(), format: ExportFormat.json);
      final List<dynamic> list = jsonDecode(json) as List<dynamic>;
      expect(list, hasLength(2));
      final Map<String, dynamic> first = list.first as Map<String, dynamic>;
      expect(first['sentence'], '吾輩は猫である。');
      expect(first['expression'], '猫');
      expect(first['reading'], 'ねこ');
      expect(first['glossary'], 'cat');
      expect(first['source'], 'book');
    });

    test('markdown 按 bookTitle 分组并含整句引用块', () {
      final String md =
          buildMinedExport(sampleMined(), format: ExportFormat.markdown);
      expect(md, contains('## 吾輩は猫である'));
      expect(md, contains('> 吾輩は猫である。'));
      expect(md, contains('**猫**（ねこ）'));
    });

    test('空列表', () {
      expect(
          buildMinedExport(<ExportMinedSentence>[], format: ExportFormat.txt),
          isEmpty);
      expect(
          jsonDecode(buildMinedExport(<ExportMinedSentence>[],
              format: ExportFormat.json)),
          isEmpty);
      final String csv = buildMinedExport(
        <ExportMinedSentence>[],
        format: ExportFormat.csv,
        csvBom: false,
      );
      expect(const LineSplitter().convert(csv).length, 1);
    });

    test('documentTitle 空时调用方回退占位（bookTitle 恒非空）', () {
      // 载体的 bookTitle 是 required 非空：模拟调用方对空 documentTitle 的回退。
      final ExportMinedSentence m = ExportMinedSentence(
        sentence: 's',
        expression: 'e',
        reading: '',
        glossary: '',
        bookTitle: t.collection_export_mined_title,
        createdAt: DateTime(2026, 6, 20),
      );
      final String md = buildMinedExport(<ExportMinedSentence>[m],
          format: ExportFormat.markdown);
      expect(md, contains('## ${t.collection_export_mined_title}'));
    });
  });

  group('TODO-914 dedupeMinedBySentence / dedupeSentences / combined', () {
    ExportMinedSentence mined({
      required String sentence,
      required String expression,
      String reading = '',
      String glossary = 'gloss',
      String bookTitle = 'Book',
      String? source = 'book',
      DateTime? createdAt,
    }) =>
        ExportMinedSentence(
          sentence: sentence,
          expression: expression,
          reading: reading,
          glossary: glossary,
          bookTitle: bookTitle,
          source: source,
          createdAt: createdAt ?? DateTime(2026, 6, 20, 9, 0),
        );

    test('same sentence with two words → one group with two words', () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: '彼は本を読んだ。', expression: '本', reading: 'ほん'),
          mined(sentence: '彼は本を読んだ。', expression: '読む', reading: 'よむ'),
        ],
      );
      expect(groups, hasLength(1));
      expect(groups.first.words, hasLength(2));
      expect(groups.first.words.map((ExportMinedWord w) => w.expression),
          <String>['本', '読む']);
      expect(groups.first.sentence, '彼は本を読んだ。');
    });

    test('full-width period vs half-width period judged same sentence', () {
      // 全角句号「。」vs 半角句号「.」——归一后判同句聚合。
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: '本。', expression: '本'),
          mined(sentence: '本.', expression: 'ほん'),
        ],
      );
      expect(groups, hasLength(1), reason: '全角。与半角. 应归一为同句');
      expect(groups.first.words, hasLength(2));
    });

    test('leading/trailing whitespace + full-width space folded → same sentence',
        () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: '本 を読む', expression: 'a'),
          // 全角空格 U+3000 + 首尾空白：折叠后与上句归一相同。
          mined(sentence: '  本　を読む  ', expression: 'b'),
        ],
      );
      expect(groups, hasLength(1));
    });

    test('empty-sentence rows do NOT collapse into one bucket', () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: '', expression: '猫', glossary: 'cat'),
          mined(sentence: '', expression: '犬', glossary: 'dog'),
        ],
      );
      expect(groups, hasLength(2), reason: '空句行按词三元组各自成组，不塌成一桶');
    });

    test('createdAt takes the latest within a group', () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(
              sentence: '同じ。',
              expression: 'a',
              createdAt: DateTime(2026, 6, 20)),
          mined(
              sentence: '同じ。',
              expression: 'b',
              createdAt: DateTime(2026, 6, 25)),
        ],
      );
      expect(groups, hasLength(1));
      expect(groups.first.createdAt, DateTime(2026, 6, 25));
    });

    test('word triple dedupe within a group keeps first occurrence', () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: '同じ。', expression: '本', reading: 'ほん', glossary: 'g'),
          mined(sentence: '同じ。', expression: '本', reading: 'ほん', glossary: 'g'),
          mined(sentence: '同じ。', expression: '本', reading: 'ほん', glossary: 'h'),
        ],
      );
      expect(groups.first.words, hasLength(2),
          reason: '完全相同三元组去重，glossary 不同保留');
    });

    test('dedupeSentences removes duplicate text by normalized key', () {
      final List<ExportSentence> rows = dedupeSentences(<ExportSentence>[
        ExportSentence(
            text: '同じ文。',
            bookTitle: 'B',
            createdAt: DateTime(2026, 6, 20)),
        ExportSentence(
            text: '  同じ文。 ',
            bookTitle: 'B',
            createdAt: DateTime(2026, 6, 21)),
        ExportSentence(
            text: '別の文。',
            bookTitle: 'B',
            createdAt: DateTime(2026, 6, 22)),
      ]);
      expect(rows, hasLength(2));
      expect(rows.first.createdAt, DateTime(2026, 6, 20),
          reason: '保留首现');
    });

    test('buildMinedGroupedExport json carries words array', () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: '彼は本を読んだ。', expression: '本', reading: 'ほん'),
          mined(sentence: '彼は本を読んだ。', expression: '読む', reading: 'よむ'),
        ],
      );
      final String jsonStr =
          buildMinedGroupedExport(groups, format: ExportFormat.json);
      final List<dynamic> parsed = jsonDecode(jsonStr) as List<dynamic>;
      expect(parsed, hasLength(1));
      final Map<String, dynamic> obj = parsed.first as Map<String, dynamic>;
      expect(obj['sentence'], '彼は本を読んだ。');
      expect((obj['words'] as List<dynamic>), hasLength(2));
    });

    test('buildMinedGroupedExport csv repeats sentence per word + BOM', () {
      final List<ExportMinedSentenceGroup> groups = dedupeMinedBySentence(
        <ExportMinedSentence>[
          mined(sentence: 'S。', expression: 'a'),
          mined(sentence: 'S。', expression: 'b'),
        ],
      );
      final String csv =
          buildMinedGroupedExport(groups, format: ExportFormat.csv);
      expect(csv.startsWith(bom), isTrue);
      // 一词一行 → sentence 列出现两次。
      final RegExp re = RegExp(r'S。');
      expect(re.allMatches(csv).length, 2);
    });

    test('buildCombinedExport json has both mined and favorites keys', () {
      final List<ExportMinedSentenceGroup> mineds = dedupeMinedBySentence(
        <ExportMinedSentence>[mined(sentence: 'M。', expression: '本')],
      );
      final List<ExportSentence> favs = <ExportSentence>[
        ExportSentence(
            text: 'F。', bookTitle: 'B', createdAt: DateTime(2026, 6, 20)),
      ];
      final String jsonStr = buildCombinedExport(
        mined: mineds,
        favorites: favs,
        format: ExportFormat.json,
      );
      final Map<String, dynamic> obj =
          jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(obj.containsKey('mined'), isTrue);
      expect(obj.containsKey('favorites'), isTrue);
      expect((obj['mined'] as List<dynamic>), hasLength(1));
      expect((obj['favorites'] as List<dynamic>), hasLength(1));
    });

    test('buildCombinedExport markdown shows both section titles', () {
      final String md = buildCombinedExport(
        mined: dedupeMinedBySentence(
            <ExportMinedSentence>[mined(sentence: 'M。', expression: '本')]),
        favorites: <ExportSentence>[
          ExportSentence(
              text: 'F。', bookTitle: 'B', createdAt: DateTime(2026, 6, 20)),
        ],
        format: ExportFormat.markdown,
      );
      expect(md, contains('# ${t.collection_export_mined_title}'));
      expect(md, contains('# ${t.collection_export_sentences_title}'));
    });

    test('buildCombinedExport csv has kind column distinguishing segments', () {
      final String csv = buildCombinedExport(
        mined: dedupeMinedBySentence(
            <ExportMinedSentence>[mined(sentence: 'M。', expression: '本')]),
        favorites: <ExportSentence>[
          ExportSentence(
              text: 'F。', bookTitle: 'B', createdAt: DateTime(2026, 6, 20)),
        ],
        format: ExportFormat.csv,
      );
      expect(csv, contains('kind,'));
      expect(csv, contains('mined,'));
      expect(csv, contains('favorite,'));
    });

    // 段间不互消：同一句既制卡又收藏 → 两段各出现一次。
    test('combined export does NOT cross-dedupe between segments', () {
      final String jsonStr = buildCombinedExport(
        mined: dedupeMinedBySentence(
            <ExportMinedSentence>[mined(sentence: '共有。', expression: '本')]),
        favorites: <ExportSentence>[
          ExportSentence(
              text: '共有。', bookTitle: 'B', createdAt: DateTime(2026, 6, 20)),
        ],
        format: ExportFormat.json,
      );
      final Map<String, dynamic> obj =
          jsonDecode(jsonStr) as Map<String, dynamic>;
      expect((obj['mined'] as List<dynamic>), hasLength(1));
      expect((obj['favorites'] as List<dynamic>), hasLength(1),
          reason: '段间不互消，收藏段仍保留同句');
    });
  });

}
