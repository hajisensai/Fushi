// 记忆状态输入（铁律 A）搬进 Rust（native/fushi_fsrs/src/projection.rs `memory_input`）之后的回归门：
//
// 固定向量 test/memory/fixtures/memory_input_vectors.json.gz 由**删除前的 Dart 实现**
// （valid_logs.dart `srsCollectMemoryInput` / `srsElapsedDays` / `SrsDayContext.dayIndexOf`）生成，脚本留档
// packages/fushi_engine/test/srs/fixtures/gen_p6_vectors.dart.txt：1200 份随机历史 × 四种日界 × 三种算法
// （FSRS-6 整天、FSRS-7 / RWKV 小数天），覆盖重置、恢复照抄（含同 / 异算法的记忆状态、带 restoreOf 的
// 重置）、导入锚点（SM-2 换算 / 直接用）、学习起点、撤销、钳位。
//
// 列模式入口（排程用：内存里的 SrsCardHistory）必须与旧实现逐条一致；优化器的直读路径同一个 Rust 函数，
// 由 fushi_engine 的 srs_p6_vectors_test 钉。要真实原生库，库加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> _vectors() {
  final File f = File('test/memory/fixtures/memory_input_vectors.json.gz');
  final Map<String, Object?> root =
      jsonDecode(utf8.decode(gzip.decode(f.readAsBytesSync())))
          as Map<String, Object?>;
  return (root['vectors']! as List<Object?>).cast<Map<String, Object?>>();
}

Map<String, Object?> _json(SrsMemoryInput m) => <String, Object?>{
  'reviews': <List<num>>[
    for (final SrsFsrsReview r in m.reviews) <num>[r.rating, r.deltaDays],
  ],
  'starting': m.starting == null
      ? null
      : <double>[
          m.starting!.stability,
          m.starting!.difficulty,
          m.starting!.stabilityFast,
        ],
  'sm2': m.sm2Start == null
      ? null
      : <double>[m.sm2Start!.ease, m.sm2Start!.intervalDays],
  'complete': m.complete,
};

void main() {
  test('原生库可加载（硬依赖）', () {
    expect(FushiFsrs.instance, isNotNull, reason: 'fushi_fsrs 原生库缺失');
  });

  final List<Map<String, Object?>> vectors = _vectors();

  test('向量规模哨兵', () {
    expect(vectors, hasLength(1200));
    int sm2 = 0;
    int starting = 0;
    int complete = 0;
    for (final Map<String, Object?> v in vectors) {
      final Map<String, Object?> e =
          (v['expect']! as Map<String, Object?>)['fsrs7']!
              as Map<String, Object?>;
      if (e['sm2'] != null) sm2++;
      if (e['starting'] != null) starting++;
      if (e['complete'] == true &&
          (e['reviews']! as List<Object?>).isNotEmpty) {
        complete++;
      }
    }
    expect(sm2, greaterThan(200));
    expect(starting, greaterThan(20));
    expect(complete, greaterThan(150));
  });

  test('列模式（SrsCardHistory → Rust）与旧 Dart 实现逐条一致', () {
    int checked = 0;
    for (int i = 0; i < vectors.length; i++) {
      final Map<String, Object?> v = vectors[i];
      final Map<String, Object?> server = (v['server']! as Map)
          .cast<String, Object?>();
      final List<SrsReviewLog> logs = <SrsReviewLog>[
        for (final Object? j in v['logs']! as List<Object?>)
          SrsReviewLog.fromJson(
            (jsonDecode(j! as String) as Map).cast<String, Object?>(),
          ),
      ];
      final List<Object?> d = v['day']! as List<Object?>;
      final SrsDayContext day = SrsDayContext(
        utcOffsetMin: d[0]! as int,
        rolloverHour: d[1]! as int,
      );
      final SrsCardHistory h = SrsCardHistory(
        logs,
        serverTimeOf: (String id) => server[id] as int?,
      );
      final Map<String, Object?> expected =
          v['expect']! as Map<String, Object?>;
      for (final SrsAlgorithm a in <SrsAlgorithm>[
        SrsAlgorithm.fsrs6,
        SrsAlgorithm.fsrs7,
        SrsAlgorithm.rwkv,
      ]) {
        expect(
          _json(srsCollectMemoryInput(h, algorithm: a, day: day)),
          expected[a.wire],
          reason: 'vector $i ${a.wire}',
        );
        checked++;
      }
    }
    expect(checked, 3600);
  });

  test('锚点的 memAlg 不是字符串：用到时判坏数据（与旧 Dart 的类型转换一致）', () {
    final SrsReviewLog anchor = SrsReviewLog.fromJson(<String, Object?>{
      'id': 'a',
      'p': 'p',
      'card': 'c',
      'kind': SrsLogKind.importAnchor,
      'hlc': '1:0:A',
      'at': 0,
      'memAlg': 7,
      'res': <String, Object?>{'queue': 'review'},
    });
    expect(
      () => srsCollectMemoryInput(
        SrsCardHistory(<SrsReviewLog>[anchor]),
        algorithm: SrsAlgorithm.fsrs7,
        day: const SrsDayContext(utcOffsetMin: 0, rolloverHour: 4),
      ),
      throwsFormatException,
    );
  });
}
