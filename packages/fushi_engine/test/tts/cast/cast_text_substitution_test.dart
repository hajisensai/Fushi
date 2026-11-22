import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

void main() {
  test('longest source wins, single pass, disabled entries ignored', () {
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution(source: '服', replacement: 'ふく'),
      CastTextSubstitution(source: 'セーラー服', replacement: 'ワンピース'),
      CastTextSubstitution(source: 'ワンピース', replacement: 'X'),
      CastTextSubstitution(source: '帽子', replacement: 'Y', enabled: false),
    ];
    expect(applyCastSubstitutions('セーラー服と服と帽子', table), 'ワンピースとふくと帽子');
  });

  test('invalid entries are reported and skipped', () {
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution(source: ' ', replacement: 'a'),
      CastTextSubstitution(source: 'A', replacement: 'b'),
      CastTextSubstitution(source: 'A', replacement: 'c'),
      CastTextSubstitution(source: 'B', replacement: 'x\ny'),
    ];
    expect(validateCastSubstitutions(table), <int, CastSubstitutionProblem>{
      0: CastSubstitutionProblem.emptySource,
      2: CastSubstitutionProblem.duplicateSource,
      3: CastSubstitutionProblem.lineBreak,
    });
    expect(applyCastSubstitutions('AB', table), 'bB');
  });

  test('series profile stores the table and rewrites spoken text', () {
    final SeriesCastProfile p = SeriesCastProfile(
      seriesKey: 'k',
      substitutions: <CastTextSubstitution>[
        const CastTextSubstitution(source: 'コート', replacement: 'ジャケット'),
      ],
    );
    final SeriesCastProfile back = SeriesCastProfile.fromJson(p.toJson())!;
    expect(back.spokenText('赤いコート'), '赤いジャケット');
    expect(back.isEmpty, isFalse);
  });

  group('人名读法（TW9ete_FHX）', () {
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution.name(
        written: '豊川祥子',
        reading: 'とがわさきこ',
        character: '豊川祥子',
      ),
      CastTextSubstitution.name(
        written: '祥子',
        reading: 'さきこ',
        character: '豊川祥子',
      ),
      CastTextSubstitution.name(written: '祥', reading: 'さき', character: '豊川祥子'),
      CastTextSubstitution(source: 'コート', replacement: 'ジャケット'),
    ];

    test('三种叫法都只改朗读，显示文字不带读法', () {
      const String line = '豊川祥子です。祥子ちゃん、祥ちゃん、コート';
      expect(
        applyCastSpokenSubstitutions(line, table),
        'とがわさきこです。さきこちゃん、さきちゃん、ジャケット',
      );
      // 显示（字幕 / 制卡 / AI 标注输入）只过普通替换。
      expect(applyCastSubstitutions(line, table), '豊川祥子です。祥子ちゃん、祥ちゃん、ジャケット');
    });

    test('单字简称只在称呼后缀前命中', () {
      expect(applyCastSpokenSubstitutions('不祥事だ', table), '不祥事だ');
      expect(applyCastSpokenSubstitutions('祥', table), '祥');
      expect(applyCastSpokenSubstitutions('祥さん', table), 'さきさん');
    });

    test('读法留空 = 待复核，不生效；停用同理', () {
      const List<CastTextSubstitution> pending = <CastTextSubstitution>[
        CastTextSubstitution.name(written: '祥子', reading: ' '),
        CastTextSubstitution.name(written: '睦', reading: 'むつみ', enabled: false),
      ];
      expect(pending.first.isPendingName, isTrue);
      expect(applyCastSpokenSubstitutions('祥子と睦ちゃん', pending), '祥子と睦ちゃん');
    });

    test('类别与角色随系列档案落盘', () {
      final SeriesCastProfile p = SeriesCastProfile(
        seriesKey: 'k',
        substitutions: List<CastTextSubstitution>.of(table),
      );
      final SeriesCastProfile back = SeriesCastProfile.fromJson(p.toJson())!;
      expect(back.substitutions.first.isName, isTrue);
      expect(back.substitutions.first.character, '豊川祥子');
      expect(back.substitutions.last.isName, isFalse);
      expect(back.spokenText('祥子ちゃん'), 'さきこちゃん');
      // 旧档案没有 k 字段：照旧当普通替换。
      final CastTextSubstitution legacy = CastTextSubstitution.fromJson(
        <String, Object?>{'s': 'A', 'r': 'B'},
      )!;
      expect(legacy.isName, isFalse);
      expect(legacy.toJson().containsKey('k'), isFalse);
    });

    test('从角色表补出待复核条目：规范名 + 别名，已有写法与旁白跳过', () {
      final List<CastTextSubstitution> added = pendingCastNameEntries(
        table: const <CastTextSubstitution>[
          CastTextSubstitution.name(written: '祥子', reading: 'さきこ'),
        ],
        roster: const <TtsCastCharacter>[
          TtsCastCharacter(name: kTtsNarrator),
          TtsCastCharacter(name: '豊川祥子', aliases: <String>['祥子', '祥ちゃん']),
          TtsCastCharacter(name: '若葉睦'),
        ],
      );
      expect(
        <String>[for (final CastTextSubstitution e in added) e.source],
        <String>['豊川祥子', '祥ちゃん', '若葉睦'],
      );
      expect(added.every((CastTextSubstitution e) => e.isPendingName), isTrue);
      expect(added[1].character, '豊川祥子');
    });
  });
}
