// 确定性 ID 的哈希（uuidV5 = SHA-1、hash53 = SHA-256）改走 native/fushi_compute 后的回归向量。
//
// 向量由删除前的纯 Dart 实现（package:crypto，2026-10-18）生成：这些 ID 已经落在用户库与
// 同步数据里，任何一位变化都等于让所有确定性 ID 重生成。
@TestOn('vm')
library;

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const List<(String, String, String)> _uuidV5Vectors =
    <(String, String, String)>[
      (srsNamespace, '', '10f2066b-d110-5bf8-a178-8e017801cd32'),
      (srsNamespace, 'p1/note/abc', 'a1eec7b7-1e92-53eb-b73d-86bfd1f114bb'),
      (
        '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
        'www.example.com',
        '2ed6657d-e927-568b-95e1-2665a8aea6a2',
      ),
      (srsNamespace, '日本語/デッキ::子', 'e4ac62ec-c843-59ee-829f-4a2c5ef17780'),
      (
        '0190a5c1-1234-7abc-8def-0123456789ab',
        'anki-revlog/1700000000123',
        '62e5507f-ce79-56e7-9d91-7e2b0e769c68',
      ),
    ];

const List<(String, int)> _hash53Vectors = <(String, int)>[
  ('', 1038781907532828),
  ('a', 2981330388917181),
  ('anki-id/6f1c8a2e-4b7d-5e3f-9a10-2d4c6e8f0b13', 8975190264340323),
  ('fushi/builtin-notetype/lapis', 863107405324239),
  ('日本語', 6598216217218767),
];

void main() {
  test('uuidV5 matches the frozen Dart-era vectors (single and batch)', () {
    for (final (String ns, String name, String id) in _uuidV5Vectors) {
      expect(uuidV5(ns, name), id, reason: '$ns / $name');
    }
    expect(
      uuidV5Batch(<(String, String)>[
        for (final (String ns, String name, _) in _uuidV5Vectors) (ns, name),
      ]),
      <String>[for (final (_, _, String id) in _uuidV5Vectors) id],
    );
    expect(uuidV5Batch(const <(String, String)>[]), isEmpty);
  });

  test('hash53 matches the frozen Dart-era vectors (single and batch)', () {
    for (final (String input, int value) in _hash53Vectors) {
      expect(hash53(input), value, reason: input);
    }
    expect(
      hash53Batch(<String>[for (final (String s, _) in _hash53Vectors) s]),
      <int>[for (final (_, int v) in _hash53Vectors) v],
    );
  });

  test('batch helpers equal their single-item rules', () {
    const String card = '0190a5c1-1234-7abc-8def-0123456789ab';
    final List<int> revlogs = <int>[1700000000123, 1700000000456, 1];
    expect(SrsIds.importedRevlogs(card, revlogs), <String>[
      for (final int r in revlogs) SrsIds.importedRevlog(card, r),
    ]);
    expect(SrsIds.importedRevlogs(card, const <int>[]), isEmpty);
    final List<String> ids = <String>[card, srsNamespace, '', '日本語', '\uD800'];
    expect(SrsIds.ankiNumericIds(ids), <int>[
      for (final String id in ids) SrsIds.ankiNumericId(id),
    ]);
    expect(hash53Batch(ids), <int>[for (final String id in ids) hash53(id)]);
    expect(hash53Batch(const <String>[]), isEmpty);
  });
}
