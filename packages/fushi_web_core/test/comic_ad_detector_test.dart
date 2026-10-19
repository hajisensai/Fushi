// 章末广告页识别：回归向量（旧 Dart 实现录下的输入 → 输出，见
// native/fushi_web_core/tests/vectors/comic_ad/expected.json）经 Dart → FFI → Rust 整批跑一遍，
// 必须全部对上。找不到原生库就失败（硬依赖，不 skip）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:fushi_web_core/testing.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useDevFushiWebCoreLibrary);

  final Directory? vectors = locateWebCoreVectors();
  final Map<String, Object?> expected = vectors == null
      ? const <String, Object?>{}
      : jsonDecode(
              File('${vectors.path}/comic_ad/expected.json').readAsStringSync(),
            )
            as Map<String, Object?>;

  test('vector set is present', () {
    expect(vectors, isNotNull);
    expect(
      (expected['cases']! as List<Object?>).length,
      greaterThanOrEqualTo(30),
    );
  });

  test('regression vectors: batch detect through FFI matches', () async {
    final List<Map<String, Object?>> cases =
        (expected['cases']! as List<Object?>).cast<Map<String, Object?>>();
    final List<Uint8List> images = <Uint8List>[
      for (final Map<String, Object?> c in cases)
        File('${vectors!.path}/comic_ad/inputs/${c['file']}').readAsBytesSync(),
    ];
    final List<ComicAdVerdict> got = await ComicAdDetector().detect(images);
    expect(got, hasLength(cases.length));
    final List<String> failures = <String>[
      for (int i = 0; i < cases.length; i++)
        if ((got[i] == ComicAdVerdict.ad) != cases[i]['expectedIsAd'])
          '${cases[i]['file']}: ${got[i]} want ad=${cases[i]['expectedIsAd']}',
    ];
    expect(failures, isEmpty);
  });

  test('candidate indices match the recorded Dart rule', () {
    final ComicAdDetector detector = ComicAdDetector();
    final Map<String, Object?> candidates =
        expected['candidates']! as Map<String, Object?>;
    for (final MapEntry<String, Object?> e in candidates.entries) {
      expect(
        detector.candidateIndices(int.parse(e.key)),
        (e.value! as List<Object?>).cast<int>(),
        reason: 'page count ${e.key}',
      );
    }
  });

  test('default rules come from the native library', () {
    final ComicAdRules r = ComicAdRules.defaults();
    final Map<String, Object?> rec = expected['rules']! as Map<String, Object?>;
    expect(r.tailWindow, rec['tailWindow']);
    expect(r.protectedLeadingPages, rec['protectedLeadingPages']);
    expect(r.colorfulThreshold, rec['colorfulThreshold']);
    expect(r.analysisMaxSide, 900);
  });

  test('custom rules are passed through', () async {
    final ComicAdDetector detector = ComicAdDetector(
      rules: const ComicAdRules(
        tailWindow: 2,
        protectedLeadingPages: 0,
        // 阈值拉满：没有图能算「彩色」，广告图也判正文。
        colorfulThreshold: 1.1,
        analysisMaxSide: 900,
      ),
    );
    expect(detector.candidateIndices(5), <int>[3, 4]);
    final Uint8List ad = File(
      '${vectors!.path}/comic_ad/inputs/t_poster_qr_600x900.png',
    ).readAsBytesSync();
    expect(await detector.detect(<Uint8List>[ad]), <ComicAdVerdict>[
      ComicAdVerdict.content,
    ]);
    expect(await detector.detect(const <Uint8List>[]), isEmpty);
    expect(await detector.detect(<Uint8List>[Uint8List(0)]), <ComicAdVerdict>[
      ComicAdVerdict.undecodable,
    ]);
  });
}
