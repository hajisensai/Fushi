import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
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
}
