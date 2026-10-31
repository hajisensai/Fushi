// AnkiConnect 查重规范形的回归门：固定向量（test/search/fixtures/search_parity_vectors.json.gz 的 `dupeNorm`）由
// **删除前的 Dart 实现**生成（test/search/fixtures/gen_search_parity.dart.txt，在 efb95b0aef 上运行），Rust 版
// （`ffsrs_search_dupe_norm_batch`）必须逐串一致。
//
// 同一份 fixture 里的搜索命中位图以前经 Dart 整批求值包装 `SrsSearchCorpus` 对拍；那层包装生产不再用、已删
// （L-5），那批输入输出连同 anki_search_test / search_engine_differences_test 的求值用例一起录成
// native/fushi_fsrs/tests/fixtures/search_kernel_vectors.json.zst，由 Rust 测试
// `search::tests::kernel_vectors_from_the_dart_search_tests` 直接对拍内核。
//
// 要真实原生库（FUSHI_FSRS_LIB，缺省本仓 prebuilt/）；库加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

void main() {
  final FushiFsrs lib = requireSearchLibrary();
  final Map<String, Object?> fixture =
      (jsonDecode(
                utf8.decode(
                  gzip.decode(
                    File(
                      'test/search/fixtures/search_parity_vectors.json.gz',
                    ).readAsBytesSync(),
                  ),
                ),
              )
              as Map)
          .cast<String, Object?>();

  test('固定向量：AnkiConnect 查重规范形逐串一致', () {
    final List<Object?> dupes = fixture['dupeNorm']! as List<Object?>;
    final List<String> inputs = <String>[
      for (final Object? d in dupes)
        (d! as Map<Object?, Object?>)['in']! as String,
    ];
    final List<String> got = srsDupeNormBatch(inputs, library: lib);
    for (int i = 0; i < dupes.length; i++) {
      expect(
        got[i],
        (dupes[i]! as Map<Object?, Object?>)['out'],
        reason: jsonEncode(inputs[i]),
      );
    }
    expect(dupes.length, greaterThanOrEqualTo(1000));
  });
}
