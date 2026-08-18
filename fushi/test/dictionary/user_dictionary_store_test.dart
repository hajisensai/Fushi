import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/dictionary/user_dictionary_store.dart';

void main() {
  group('decodeUserDictionaryEntries', () {
    test('空串与坏 JSON 回空列表（容错，不抛）', () {
      expect(decodeUserDictionaryEntries(''), isEmpty);
      expect(decodeUserDictionaryEntries('not json {'), isEmpty);
      expect(decodeUserDictionaryEntries('{"a":1}'), isEmpty);
    });

    test('缺字段与空词头条目被剔除', () {
      final String raw = jsonEncode(<Object>[
        <String, String>{'expression': '空穂', 'reading': 'うつぼ'},
        <String, String>{'reading': '孤儿读音'},
        <String, String>{'expression': ''},
      ]);
      final List<UserDictionaryEntry> entries =
          decodeUserDictionaryEntries(raw);
      expect(entries, hasLength(1));
      expect(entries.first.expression, '空穂');
      expect(entries.first.reading, 'うつぼ');
      expect(entries.first.meaning, '');
    });
  });

  group('encodeUserDictionaryEntries', () {
    test('空列表编码为空串（与「从未用过」同形）', () {
      expect(encodeUserDictionaryEntries(<UserDictionaryEntry>[]), '');
    });

    test('编码/解码往返无损', () {
      final List<UserDictionaryEntry> entries = <UserDictionaryEntry>[
        const UserDictionaryEntry(
          expression: '手向け',
          reading: 'たむけ',
          meaning: '饯别；供奉\n第二行释义',
        ),
        const UserDictionaryEntry(expression: 'のみ'),
      ];
      final List<UserDictionaryEntry> decoded =
          decodeUserDictionaryEntries(encodeUserDictionaryEntries(entries));
      expect(decoded, hasLength(2));
      expect(decoded[0].expression, '手向け');
      expect(decoded[0].reading, 'たむけ');
      expect(decoded[0].meaning, '饯别；供奉\n第二行释义');
      expect(decoded[1].expression, 'のみ');
      expect(decoded[1].reading, '');
      expect(decoded[1].meaning, '');
    });
  });

  group('userDictionaryGlossaryLines', () {
    test('按行拆分并剔除空白行', () {
      expect(
        userDictionaryGlossaryLines('一行\n\n  二行  \n'),
        <String>['一行', '二行'],
      );
    });

    test('全空回退整段原文（词条至少一条 glossary）', () {
      expect(userDictionaryGlossaryLines(''), <String>['']);
    });
  });

  group('buildUserDictionaryZipBytes', () {
    test('产出标准 Yomitan 包：index.json + term_bank_1.json 逐字段对齐', () {
      final List<int> bytes = buildUserDictionaryZipBytes(
        entries: <UserDictionaryEntry>[
          const UserDictionaryEntry(
            expression: '手向け',
            reading: 'たむけ',
            meaning: '饯别\n供奉',
          ),
          const UserDictionaryEntry(expression: 'テスト', meaning: '测试'),
        ],
        revision: 'user-123',
      );

      final Archive archive = ZipDecoder().decodeBytes(bytes);
      final Map<String, ArchiveFile> files = <String, ArchiveFile>{
        for (final ArchiveFile f in archive.files) f.name: f,
      };
      expect(
          files.keys, containsAll(<String>['index.json', 'term_bank_1.json']));

      final Map<String, dynamic> index = jsonDecode(
        utf8.decode(files['index.json']!.content as List<int>),
      ) as Map<String, dynamic>;
      expect(index['title'], userDictionaryTitle);
      expect(index['format'], 3);
      expect(index['revision'], 'user-123');
      expect(index['sequenced'], false);

      final List<dynamic> terms = jsonDecode(
        utf8.decode(files['term_bank_1.json']!.content as List<int>),
      ) as List<dynamic>;
      expect(terms, hasLength(2));
      final List<dynamic> first = terms[0] as List<dynamic>;
      expect(first[0], '手向け');
      expect(first[1], 'たむけ');
      // rules 必须为空串：用户词条不参与去屈折（BUG-729 的活用误命中形状）。
      expect(first[3], '');
      expect(first[5], <String>['饯别', '供奉']);
      expect(first[6], 0);
      final List<dynamic> second = terms[1] as List<dynamic>;
      expect(second[0], 'テスト');
      expect(second[1], '');
      expect(second[5], <String>['测试']);
      expect(second[6], 1);
    });
  });
}
