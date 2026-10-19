import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 标题归一化 / 分词 / 相似度原生实现的代表样本。期望值（含相似度的 f64 位模式）由搬迁前
/// 的 Dart `TitleNormalizer` 冻结；大规模摘要对拍见
/// packages/fushi_engine/test/media/video/anidb_native_parity_test.dart。
void main() {
  String bits(double v) {
    final ByteData data = ByteData(8)..setFloat64(0, v);
    return data.getUint64(0).toRadixString(16).padLeft(16, '0');
  }

  test('normalize', () {
    expect(TitleScoreNative.normalize('ＡＢＣ１２３：Ｒｅ'), 'abc123 re');
    expect(TitleScoreNative.normalize('無職転生　　２'), '无职转生 2');
    expect(TitleScoreNative.normalize('  【推しの子】  第２期 '), '推しの子 第2期');
    expect(TitleScoreNative.normalize('☆★♪'), '');
    expect(TitleScoreNative.normalize('A～B'), 'a b');
    // `\s` 不含 U+0085，trim() 含：中间保留、两端去掉。
    expect(TitleScoreNative.normalize('\u0085x\u0085y\u0085'), 'x\u0085y');
    expect(TitleScoreNative.normalize('İSTANBUL ΣΑΣ'), 'istanbul σασ');
    expect(TitleScoreNative.normalize('\uD800a'), '\uD800a');
    expect(TitleScoreNative.normalizeAll(<String>['Ａ', '', '戰鬥']), <String>[
      'a',
      '',
      '战斗',
    ]);
  });

  test('tokens', () {
    expect(TitleScoreNative.tokens('无职转生'), <String>['无职', '职转', '转生']);
    expect(TitleScoreNative.tokens('a 生 b'), <String>['a', '生', 'b']);
    expect(TitleScoreNative.tokens('re zero ⅱ'), <String>['re', 'zero', 'ⅱ']);
    expect(TitleScoreNative.tokens(''), isEmpty);
  });

  test('similarity matches frozen Dart bit patterns', () {
    const List<(String, String, String)> cases = <(String, String, String)>[
      ('kirepapa', 'galaxy angel aa', '3fc1111111111110'),
      ('gg bond movie 3', 'gg bondmovie 3 2nd season', '3fe0a3d70a3d70a4'),
      ('kudan', 'kudan', '3ff0000000000000'),
      ('\uD800俯ぺ 个 😀僅モ 乜りm僇 傏', 'ᢸᴏ u bd♛ɟᠽいᕑ僅', '3fc6969696969698'),
      (
        'cazadores de duendes 2 housekishou richard shi no nazo kantei '
            'rushuna wystrzałowa wojowniczka',
        'someone s gaze summer s puke is winter s delight',
        '3fce4791e4791e48',
      ),
      ('', '', '3ff0000000000000'),
      ('', 'a', '0000000000000000'),
    ];
    for (final (String a, String b, String expected) in cases) {
      expect(bits(TitleScoreNative.similarityNormalized(a, b)), expected);
    }
    final List<String> candidates = <String>[
      for (final (String, String, String) c in cases) c.$2,
    ];
    final Float64List batch = TitleScoreNative.similarityNormalizedBatch(
      'kirepapa',
      candidates,
    );
    final Float64List matrix = TitleScoreNative.similarityNormalizedMatrix(
      <String>['kirepapa', 'kudan'],
      candidates,
    );
    for (int i = 0; i < candidates.length; i++) {
      final double single = TitleScoreNative.similarityNormalized(
        'kirepapa',
        candidates[i],
      );
      expect(bits(batch[i]), bits(single));
      expect(bits(matrix[i]), bits(single));
      expect(
        bits(matrix[candidates.length + i]),
        bits(TitleScoreNative.similarityNormalized('kudan', candidates[i])),
      );
    }
    expect(TitleScoreNative.similarity('無職転生', '无职转生'), 1.0);
  });
}
