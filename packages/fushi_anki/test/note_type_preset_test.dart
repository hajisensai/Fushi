import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 官方 Senren v5.1.0（https://brenoaqua.github.io/Senren/）笔记类型的字段表。
const List<String> _senrenFields = <String>[
  'word',
  'reading',
  'sentence',
  'sentenceFurigana',
  'sentenceTranslation',
  'sentenceCard',
  'audioCard',
  'notes',
  'hint',
  'selectionText',
  'definition',
  'wordAudio',
  'sentenceAudio',
  'picture',
  'glossary',
  'pitchAccents',
  'pitchPositions',
  'pitchCategories',
  'frequencies',
  'freqSort',
  'miscInfo',
  'dictionaryPreference',
];

const AnkiNoteType _senren = AnkiNoteType(
  id: 7,
  name: 'Senren',
  fields: _senrenFields,
);

final AnkiNoteType _lapis = AnkiNoteType(
  id: 1,
  name: 'Lapis',
  fields: LapisNoteType.fields,
);

/// 用户自建的普通词汇卡：碰巧也叫 word / sentence / wordAudio，但不是 Senren。
const AnkiNoteType _homemade = AnkiNoteType(
  id: 3,
  name: 'My vocab',
  fields: <String>['word', 'sentence', 'wordAudio', 'meaning'],
);

const AnkiNoteType _basic = AnkiNoteType(
  id: 9,
  name: 'Basic',
  fields: <String>['Front', 'Back'],
);

void main() {
  group('Senren 识别', () {
    test('按名字认，也按 Senren 特有字段组合认出改过名的副本', () {
      expect(SenrenPreset.matches(_senren), isTrue);
      expect(
        SenrenPreset.matches(
          const AnkiNoteType(id: 8, name: 'Copy', fields: _senrenFields),
        ),
        isTrue,
      );
      expect(SenrenPreset.matches(_basic), isFalse);
      expect(
        LapisPreset.matches(_senren),
        isFalse,
        reason: 'Senren must not be claimed by the Lapis matcher',
      );
    });

    test('只有 word / sentence / wordAudio 的自建笔记类型不算 Senren', () {
      expect(SenrenPreset.matches(_homemade), isFalse);
      expect(NoteTypePresets.of(_homemade), isNull);
      expect(NoteTypePresets.hasPreset(_homemade), isFalse);
      // 不被套 Senren 映射：走按字段名推导的通用默认映射。
      final Map<String, String> m = NoteTypePresets.applyDefaults(
        _homemade,
        const <String, String>{},
      );
      expect(m, noteTypeDefaultMappings(_homemade));
      // 选卡时也不被当成预设优先选中。
      expect(
        NoteTypePresets.preferred(<AnkiNoteType>[_basic, _homemade]),
        isNull,
      );
    });
  });

  group('Senren 映射', () {
    test('applyDefaults 给每个有占位符的 Senren 字段补上默认值', () {
      final Map<String, String> m = NoteTypePresets.applyDefaults(
        _senren,
        const <String, String>{},
      );
      expect(m, SenrenPreset.defaultFieldMappings);
      expect(m['word'], '{expression}');
      expect(m['wordAudio'], '{audio}');
      expect(m['sentenceAudio'], '{sentence-audio}');
      expect(m['picture'], '{card-image}');
      expect(m['pitchPositions'], '{pitch-accent-positions}');
      expect(m['freqSort'], '{frequency-harmonic-rank}');
      for (final String empty in <String>[
        'sentenceFurigana',
        'sentenceTranslation',
        'sentenceCard',
        'audioCard',
        'notes',
        'hint',
        'pitchAccents',
        'dictionaryPreference',
      ]) {
        expect(m.containsKey(empty), isFalse, reason: empty);
      }
      // 映射表只引用 Senren 真实存在的字段。
      expect(
        _senrenFields.toSet().containsAll(
          SenrenPreset.defaultFieldMappings.keys,
        ),
        isTrue,
      );
    });

    test('用户映射优先于预设', () {
      final Map<String, String> m = NoteTypePresets.applyDefaults(
        _senren,
        const <String, String>{'word': '{reading}'},
      );
      expect(m['word'], '{reading}');
      expect(m['wordAudio'], '{audio}');
    });
  });

  group('注册表分派', () {
    test('of / hasPreset 覆盖 Lapis 与 Senren，不覆盖普通笔记类型', () {
      expect(NoteTypePresets.of(_lapis), same(NoteTypePresets.lapis));
      expect(NoteTypePresets.of(_senren), same(NoteTypePresets.senren));
      expect(NoteTypePresets.hasPreset(_basic), isFalse);
    });

    test('nameHasPreset 只看名字关键字', () {
      expect(NoteTypePresets.nameHasPreset('Lapis v1.6'), isTrue);
      expect(NoteTypePresets.nameHasPreset('Senren'), isTrue);
      expect(NoteTypePresets.nameHasPreset('Basic'), isFalse);
      expect(NoteTypePresets.nameHasPreset(null), isFalse);
    });

    test('默认选卡按优先级：Lapis 先于 Senren，与列表顺序无关', () {
      expect(
        NoteTypePresets.preferred(<AnkiNoteType>[_basic, _senren, _lapis]),
        same(_lapis),
      );
      expect(
        NoteTypePresets.preferred(<AnkiNoteType>[_basic, _homemade, _senren]),
        same(_senren),
      );
    });
  });

  group('Lapis 行为不变', () {
    test('Lapis 映射 == LapisNoteType.defaultFieldMappings', () {
      final Map<String, String> m = NoteTypePresets.applyDefaults(
        _lapis,
        const <String, String>{},
      );
      expect(m, LapisPreset.defaultMappings(_lapis));
      expect(m['Expression'], '{expression}');
      expect(SenrenPreset.matches(_lapis), isFalse);
    });
  });
}
