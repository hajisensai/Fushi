// 卡片历史选取搬进 Rust（native/fushi_fsrs/src/history.rs）之后的回归门：
//
// 固定向量 test/history/fixtures/history_vectors.json.gz 由**删除前的 Dart 实现**生成
// （test/history/fixtures/gen_history_vectors.dart.txt，在 329a739431 上运行）：1500 份随机历史
// （撤销 / 撤销不存在的日志 / 等价导入 ±1 秒边界 / handOff / 不认识的 kind / 同 ID 重复 / 服务器
// 时刻钳位 / 代理对 writerId），两条入口都必须与旧实现逐条一致：
// - 列模式（SrsCardHistory 的构造，内存里的 SrsReviewLog）：all / effective / revoked /
//   equivalentImports / lastEffective / scheduler / state / effectiveRatings；
// - 落库形态（srsHistoryStatesFromJson，canonical JSON 原文）：state 与 lastEffective。
//
// 要真实原生库（FUSHI_FSRS_LIB，缺省本仓 prebuilt/）；库加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> _vectors() {
  final File f = File('test/history/fixtures/history_vectors.json.gz');
  final Map<String, Object?> root =
      jsonDecode(utf8.decode(gzip.decode(f.readAsBytesSync())))
          as Map<String, Object?>;
  return (root['vectors']! as List<Object?>).cast<Map<String, Object?>>();
}

int? Function(String)? _serverOf(Map<String, Object?> v) {
  final Map<String, Object?>? s = (v['server'] as Map?)
      ?.cast<String, Object?>();
  return s == null ? null : (String id) => s[id] as int?;
}

List<SrsReviewLog> _logsOf(Map<String, Object?> v) => <SrsReviewLog>[
  for (final Object? j in v['logs']! as List<Object?>)
    SrsReviewLog.fromJson(
      (jsonDecode(j! as String) as Map).cast<String, Object?>(),
    ),
];

List<String> _ids(Iterable<SrsReviewLog> logs) => <String>[
  for (final SrsReviewLog l in logs) l.id,
];

void main() {
  test('原生库可加载（硬依赖）', () {
    expect(FushiFsrs.instance, isNotNull, reason: 'fushi_fsrs 原生库缺失');
  });

  final List<Map<String, Object?>> vectors = _vectors();

  test('向量规模哨兵', () {
    expect(vectors, hasLength(1500));
    int logs = 0;
    int eq = 0;
    int revoked = 0;
    for (final Map<String, Object?> v in vectors) {
      logs += (v['logs']! as List<Object?>).length;
      final Map<String, Object?> e = v['expect']! as Map<String, Object?>;
      if ((e['equivalentImports']! as List<Object?>).isNotEmpty) eq++;
      if ((e['revoked']! as List<Object?>).isNotEmpty) revoked++;
    }
    expect(logs, greaterThan(9000));
    expect(eq, greaterThan(200));
    expect(revoked, greaterThan(500));
  });

  test('列模式（SrsCardHistory，逐份 + 整批）与旧实现逐条一致', () {
    final List<SrsHistoryInput> inputs = <SrsHistoryInput>[
      for (final Map<String, Object?> v in vectors) (_logsOf(v), _serverOf(v)),
    ];
    final List<SrsCardHistory> batch = SrsCardHistory.many(inputs);
    for (int i = 0; i < vectors.length; i++) {
      final Map<String, Object?> e =
          vectors[i]['expect']! as Map<String, Object?>;
      for (final SrsCardHistory h in <SrsCardHistory>[
        batch[i],
        SrsCardHistory(inputs[i].$1, serverTimeOf: inputs[i].$2),
      ]) {
        final String at = 'vector $i';
        expect(_ids(h.all), e['all'], reason: at);
        expect(_ids(h.effective), e['effective'], reason: at);
        expect(h.revoked.toList()..sort(), e['revoked'], reason: at);
        expect(
          h.equivalentImports.toList()..sort(),
          e['equivalentImports'],
          reason: at,
        );
        expect(h.lastEffective?.id, e['lastEffective'], reason: at);
        expect(h.scheduler, e['scheduler'], reason: at);
        expect(
          srsCanonicalJson(h.state.toJson()),
          srsCanonicalJson(e['state']),
          reason: at,
        );
        expect(_ids(h.effectiveRatings), e['effectiveRatings'], reason: at);
      }
    }
  });

  test('落库形态（srsHistoryStatesFromJson）与旧实现逐条一致', () {
    final List<SrsStoredHistory> stored = <SrsStoredHistory>[
      for (final Map<String, Object?> v in vectors)
        <(Uint8List, int?)>[
          for (final Object? j in v['logs']! as List<Object?>)
            (
              utf8.encode(j! as String),
              _serverOf(
                v,
              )?.call((jsonDecode(j as String) as Map)['id']! as String),
            ),
        ],
    ];
    final List<SrsHistoryState> states = srsHistoryStatesFromJson(stored);
    for (int i = 0; i < vectors.length; i++) {
      final Map<String, Object?> e =
          vectors[i]['expect']! as Map<String, Object?>;
      expect(states[i].lastLogId, e['lastEffective'], reason: 'vector $i');
      expect(
        srsCanonicalJson(states[i].result.toJson()),
        srsCanonicalJson(e['state']),
        reason: 'vector $i',
      );
    }
  });

  test('落库形态的坏数据与 SrsReviewLog.fromJson 同样判错', () {
    Uint8List b(String s) => utf8.encode(s);
    for (final String bad in <String>[
      '{"id":"x"}',
      '{"id":"x","p":"p","card":"c","kind":"review","hlc":"nohlc","at":1}',
      '{"id":"x","p":"p","card":"c","kind":"review","hlc":"1:0:A","at":1,"rating":3.5}',
      '{"id":"x","p":"p","card":"c","kind":"review","hlc":"1:0:A","at":1,"res":{"dueDay":"x"}}',
      'not json',
    ]) {
      expect(
        () => srsHistoryStatesFromJson(<SrsStoredHistory>[
          <(Uint8List, int?)>[(b(bad), null)],
        ]),
        throwsFormatException,
        reason: bad,
      );
      expect(
        () => SrsReviewLog.fromJson(
          (jsonDecode(bad) as Map).cast<String, Object?>(),
        ),
        throwsA(anything),
        reason: bad,
      );
    }
  });
}
