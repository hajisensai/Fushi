// ffc_text_align_positions 回归测试：冻结向量 test/fixtures/text_align_positions_vectors.json
// 由删除前的纯 Dart 实现（fushi_audio `CueSentenceResegmenter._alignPositions`，2026-10-18）
// 对 support/align_vector_inputs.dart 生成的输入算出。全是整数运算，逐值一致：每组比整段
// 映射拼接后的 SHA-256，另比逐对校验和（定位是哪一对不一致），edge 组比全量映射。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'support/align_vector_inputs.dart';

int _checksum(List<int> map) {
  int s = 0;
  for (int i = 0; i < map.length; i++) {
    s = (s + map[i] * (i + 1)) & 0x7fffffff;
  }
  return s;
}

void main() {
  final Map<String, Object?> fixture =
      jsonDecode(
            File(
              'test/fixtures/text_align_positions_vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final Map<String, Map<String, Object?>> want = <String, Map<String, Object?>>{
    for (final Object? e in fixture['cases']! as List<Object?>)
      (e! as Map<String, Object?>)['id']! as String: e as Map<String, Object?>,
  };
  final FushiComputeText text = FushiComputeText.instance;

  for (final AlignCase c in alignCases()) {
    test('冻结向量：${c.id}（${c.pairs.length} 对，一次调用）', () {
      final Map<String, Object?> w = want[c.id]!;
      final List<Int32List> maps = text.alignPositions(
        <String>[for (final (String a, String _) in c.pairs) a],
        <String>[for (final (String _, String b) in c.pairs) b],
        maxCells: c.maxCells,
      );
      expect(maps.length, c.pairs.length);
      for (int k = 0; k < maps.length; k++) {
        expect(maps[k].length, c.pairs[k].$1.length + 1, reason: 'pair $k');
      }
      expect(<int>[
        for (final Int32List m in maps) _checksum(m),
      ], w['checksums']);
      final List<int> all = <int>[for (final Int32List m in maps) ...m];
      expect(all.length, w['totalLength']);
      expect(
        ffcSha256Bytes(Int32List.fromList(all).buffer.asUint8List()),
        w['sha256'],
      );
      final Object? full = w['maps'];
      if (full is List<Object?>) {
        expect(<List<int>>[for (final Int32List m in maps) m.toList()], full);
      }
    });
  }

  test('用例集与夹具一致', () {
    expect(want.keys, unorderedEquals(alignCases().map((AlignCase c) => c.id)));
  });

  test('空批 / a 与 b 数量不等', () {
    expect(text.alignPositions(<String>[], <String>[], maxCells: 1), isEmpty);
    expect(
      () => text.alignPositions(<String>['a'], <String>[], maxCells: 1),
      throwsArgumentError,
    );
  });
}
