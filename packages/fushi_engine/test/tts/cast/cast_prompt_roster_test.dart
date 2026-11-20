import 'dart:convert';

import 'package:fushi_engine/tts/cast/cast_prompt_roster.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

void main() {
  test(
    'projects free text once, keeps enum fields and stored characters intact',
    () {
      const TtsCastCharacter original = TtsCastCharacter(
        name: '旧名',
        aliases: <String>['旧名さん'],
        gender: 'female',
        age: 'teen',
        description: '旧名はセーラー服のfemale',
      );
      const List<CastTextSubstitution> table = <CastTextSubstitution>[
        CastTextSubstitution(source: '旧名', replacement: '新名'),
        CastTextSubstitution(source: 'セーラー服', replacement: '制服'),
        CastTextSubstitution(source: '服', replacement: 'ふく'),
        CastTextSubstitution(source: 'female', replacement: '人物'),
      ];
      final String before = jsonEncode(original.toJson());
      final CastPromptRoster view = CastPromptRoster(
        roster: <TtsCastCharacter>[original],
        substitutions: table,
      );
      final TtsCastCharacter projected = view.characters.single;
      expect(projected.name, '新名');
      expect(projected.aliases, <String>['新名さん']);
      expect(projected.description, '新名は制服の人物');
      expect(projected.gender, 'female');
      expect(projected.age, 'teen');
      expect(view.speakerFor('旧名さん'), '新名');
      expect(view.canonicalName('新名さん'), '旧名');
      expect(view.restoreSpeaker('新名'), '旧名');
      expect(jsonEncode(original.toJson()), before);
      expect(view.restoreCharacter(projected)!.name, '旧名');
      expect(view.restoreCharacter(projected)!.aliases, isEmpty);
    },
  );

  test('colliding names get distinct stable request IDs and never merge', () {
    const List<TtsCastCharacter> roster = <TtsCastCharacter>[
      TtsCastCharacter(name: '甲'),
      TtsCastCharacter(name: '乙'),
    ];
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution(source: '甲', replacement: '同名'),
      CastTextSubstitution(source: '乙', replacement: '同名'),
    ];
    final CastPromptRoster a = CastPromptRoster(
      roster: roster,
      substitutions: table,
    );
    final CastPromptRoster b = CastPromptRoster(
      roster: <TtsCastCharacter>[
        const TtsCastCharacter(name: '新人'),
        ...roster.reversed,
      ],
      substitutions: table,
    );
    expect(
      a.characters.map((TtsCastCharacter c) => c.name).toSet(),
      hasLength(2),
    );
    for (final TtsCastCharacter c in roster) {
      final String id = a.speakerFor(c.name);
      expect(id, startsWith('_cast_'));
      expect(id.length, lessThanOrEqualTo(40));
      expect(b.speakerFor(c.name), id);
      expect(a.canonicalName(id), c.name);
    }
    expect(a.restoreName('同名'), isNull);
    expect(a.restoreSpeaker('同名'), kTtsUnknown);
  });

  test(
    'empty and reserved projected names keep the original identity via IDs',
    () {
      final CastPromptRoster view = CastPromptRoster(
        roster: const <TtsCastCharacter>[
          TtsCastCharacter(name: '甲'),
          TtsCastCharacter(name: '乙'),
        ],
        substitutions: const <CastTextSubstitution>[
          CastTextSubstitution(source: '甲', replacement: ''),
          CastTextSubstitution(source: '乙', replacement: 'UNKNOWN'),
        ],
      );
      for (final String name in <String>['甲', '乙']) {
        expect(view.speakerFor(name), startsWith('_cast_'));
        expect(view.restoreSpeaker(view.speakerFor(name)), name);
      }
      expect(view.speakerFor(kTtsNarrator), kTtsNarrator);
      expect(view.speakerFor(kTtsUnknown), kTtsUnknown);
    },
  );

  test(
    'ambiguous aliases are omitted and cannot silently choose another voice',
    () {
      final CastPromptRoster view = CastPromptRoster(
        roster: const <TtsCastCharacter>[
          TtsCastCharacter(name: 'Alice', aliases: <String>['甲さん']),
          TtsCastCharacter(name: 'Bob', aliases: <String>['乙さん']),
        ],
        substitutions: const <CastTextSubstitution>[
          CastTextSubstitution(source: '甲', replacement: '同じ'),
          CastTextSubstitution(source: '乙', replacement: '同じ'),
        ],
      );
      expect(
        view.characters.every((TtsCastCharacter c) => c.aliases.isEmpty),
        isTrue,
      );
      expect(view.restoreSpeaker('同じさん'), kTtsUnknown);
      expect(view.speakerFor('甲さん'), 'Alice');
      expect(view.speakerFor('乙さん'), 'Bob');
    },
  );

  test(
    'new characters survive but unknown temporary IDs are never persisted',
    () {
      final CastPromptRoster view = CastPromptRoster(
        roster: const <TtsCastCharacter>[],
      );
      expect(
        view.restoreCharacter(const TtsCastCharacter(name: '新人'))!.name,
        '新人',
      );
      expect(
        view.restoreCharacter(const TtsCastCharacter(name: '_cast_missing')),
        isNull,
      );
    },
  );
}
