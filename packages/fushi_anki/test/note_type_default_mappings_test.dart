import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 反馈 AGLC0BuaKB（iOS，韩语批量制卡 2/2 全失败「All fields are empty」）：选了非 Lapis
/// 笔记类型后映射被置成 `{}`、此后从没手配，每张卡都渲染成空卡。这里钉住：
/// ① 任意笔记类型都有非空默认映射（与学习语言无关，只看字段名）；
/// ② 已存成空映射的设置载入时自动修复；③ 用户自己配过的映射不被覆盖；
/// ④ 这类配置错误让批量制卡整批中止。
void main() {
  group('noteTypeDefaultMappings', () {
    test('Basic Front/Back：首字段词条、次字段释义', () {
      const AnkiNoteType basic = AnkiNoteType(
        id: 1,
        name: 'Basic',
        fields: <String>['Front', 'Back'],
      );
      expect(noteTypeDefaultMappings(basic), <String, String>{
        'Front': '{expression}',
        'Back': '{glossary}',
      });
    });

    test('认不出的字段名：首字段兜底词条，次字段兜底释义', () {
      const AnkiNoteType custom = AnkiNoteType(
        id: 2,
        name: '한국어 카드',
        fields: <String>['가', '나', '다'],
      );
      expect(noteTypeDefaultMappings(custom), <String, String>{
        '가': '{expression}',
        '나': '{glossary}',
      });
    });

    test('按字段名认用途（大小写、下划线、空格不敏感），同一用途只给一个字段', () {
      const AnkiNoteType vocab = AnkiNoteType(
        id: 3,
        name: 'Korean Vocab',
        fields: <String>[
          'Word',
          'Vocab',
          'reading',
          'Meaning',
          'Example_Sentence',
          'Sentence Audio',
          'Image',
        ],
      );
      expect(noteTypeDefaultMappings(vocab), <String, String>{
        'Word': '{expression}',
        'reading': '{reading}',
        'Meaning': '{glossary}',
        'Example_Sentence': '{sentence}',
        'Sentence Audio': '{sentence-audio}',
        'Image': '{card-image}',
      });
    });

    test('首字段不是词条字段名时仍兜底成词条（Anki 只看首字段判空）', () {
      const AnkiNoteType t = AnkiNoteType(
        id: 4,
        name: 'Sentence first',
        fields: <String>['Notes', 'Word'],
      );
      final Map<String, String> m = noteTypeDefaultMappings(t);
      expect(m['Word'], '{expression}');
      expect(m['Notes'], '{expression}');
    });
  });

  group('NoteTypePresets.applyDefaults（无预设）', () {
    const AnkiNoteType basic = AnkiNoteType(
      id: 1,
      name: 'Basic',
      fields: <String>['Front', 'Back'],
    );

    test('空映射补默认值，不再返回 {}', () {
      expect(
        NoteTypePresets.applyDefaults(basic, const <String, String>{}),
        isNotEmpty,
      );
    });

    test('已覆盖到该笔记类型的映射原样保留', () {
      const Map<String, String> mine = <String, String>{'Back': '{sentence}'};
      expect(NoteTypePresets.applyDefaults(basic, mine), same(mine));
    });
  });

  group('AnkiSettings.fromJson 修复存量空映射', () {
    Map<String, dynamic> json(Map<String, String> mappings) =>
        <String, dynamic>{
          'selectedDeckId': 1,
          'selectedNoteTypeId': 7,
          'availableDecks': <Map<String, dynamic>>[
            <String, dynamic>{'id': 1, 'name': 'Korean'},
          ],
          'availableNoteTypes': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 7,
              'name': 'Basic',
              'fields': <String>['Front', 'Back'],
            },
          ],
          'fieldMappings': mappings,
        };

    test('空映射载入后可制卡', () {
      final AnkiSettings s = AnkiSettings.fromJson(
        json(const <String, String>{}),
      );
      expect(s.fieldMappings['Front'], '{expression}');
      expect(s.canMineCards, isTrue);
    });

    test('留着别的笔记类型字段名的映射也修复', () {
      final AnkiSettings s = AnkiSettings.fromJson(
        json(const <String, String>{'Expression': '{expression}'}),
      );
      expect(s.fieldMappings['Front'], '{expression}');
    });

    test('用户配过的映射不动', () {
      final AnkiSettings s = AnkiSettings.fromJson(
        json(const <String, String>{'Front': '{reading}'}),
      );
      expect(s.fieldMappings, <String, String>{'Front': '{reading}'});
    });

    test('选中的笔记类型不在清单里：无从判断，不动', () {
      final Map<String, dynamic> j = json(const <String, String>{})
        ..['availableNoteTypes'] = <Object>[];
      expect(AnkiSettings.fromJson(j).fieldMappings, isEmpty);
    });
  });

  test('映射配置类错误码让批量制卡整批中止，其它错误不中止', () {
    expect(isFieldMappingConfigError(AnkiErrorCode.allFieldsEmpty), isTrue);
    expect(isFieldMappingConfigError(AnkiErrorCode.firstFieldEmpty), isTrue);
    expect(
      isFieldMappingConfigError(AnkiErrorCode.fieldMappingMismatch),
      isTrue,
    );
    expect(isFieldMappingConfigError(null), isFalse);
    expect(
      isFieldMappingConfigError(AnkiErrorCode.ankiMobileUnavailable),
      isFalse,
    );
  });
}
