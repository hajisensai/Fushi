// P6（统计 / 优化器训练集 / RWKV 回放行的取数收编进 Rust）之后的端到端回归门：
//
// 固定向量 test/srs/fixtures/p6_vectors.json.gz 由**删除前的 Dart 实现**生成（脚本留档
// test/srs/fixtures/gen_p6_vectors.dart.txt）：1200 份随机历史，期望值是旧的 `srsPrepareOptimization`
// 循环体（逐卡训练条目）、`SrsRwkvReplayBuilder` / `srsRwkvKeptRatings` / `SrsRwkvLastRating.of` /
// `srsRwkvAddNowRow`（回放行字节、此刻行字节）、`srsStatsFromHistory` + `SrsCardHistory.state.memory`
// （统计投影；现由 Rust `history::stats_from_json` 经 `ffsrs_store_stat_projection` 产出）。
//
// 这里把向量日志（落库原文 + 服务器时刻）写进真实的 srs.db，经 `ffsrs_store_*` 直读命令取回，解包后
// 与旧实现逐条比较——走的就是生产路径（SQL → 选取 → 投影 → 字节布局 → Dart 解包）。要真实原生库。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> _load(String path) {
  final Map<String, Object?> root =
      jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())))
          as Map<String, Object?>;
  return (root['vectors']! as List<Object?>).cast<Map<String, Object?>>();
}

String _hex(Uint8List b) =>
    <String>[for (final int x in b) x.toRadixString(16).padLeft(2, '0')].join();

SrsDayContext _day(Map<String, Object?> v) {
  final List<Object?> d = v['day']! as List<Object?>;
  return SrsDayContext(utcOffsetMin: d[0]! as int, rolloverHour: d[1]! as int);
}

List<int> _ids(int i) => <int>[1000 + i, 2000 + i, 7, 9];

/// `SrsCore.statProjection` 的一行（9 列，见其文档）→ [SrsStatProjection]，归属卡 [owner]。
SrsStatProjection _projectionOf(List<Object?> r, String owner) =>
    SrsStatProjection(
      logId: r[1]! as String,
      cardId: owner,
      occurredAt: r[2]! as int,
      utcOffsetMin: r[3]! as int,
      rating: r[4] as int?,
      kind: SrsStatReviewKind.values[r[5]! as int],
      durationMs: r[6]! as int,
      prevDueDay: r[7] as int?,
      maturityDelta: r[8]! as int,
    );

void main() {
  final List<Map<String, Object?>> vectors = _load(
    'test/srs/fixtures/p6_vectors.json.gz',
  );
  // 同一批历史的记忆状态输入（训练集序列 = 完整历史的评审）。
  final List<Map<String, Object?>> memory = _load(
    '../fushi_srs/test/memory/fixtures/memory_input_vectors.json.gz',
  );
  late SrsCore core;
  late Directory dir;

  setUpAll(() {
    expect(FushiFsrs.instance, isNotNull, reason: 'fushi_fsrs 原生库缺失');
    dir = Directory.systemTemp.createTempSync('srs_p6_vectors_');
    core = SrsCore.open('${dir.path}/srs.db')..legacyMarkNone();
    // 第 i 份历史 = profile `p$i` 的卡 `v$i`（每份一个 profile：全量回放 / 统计按 profile 扫）。
    final List<(int, List<Object?>)> apps = <(int, List<Object?>)>[];
    for (int i = 0; i < vectors.length; i++) {
      final Map<String, Object?> server = (vectors[i]['server']! as Map)
          .cast<String, Object?>();
      for (final Object? j in vectors[i]['logs']! as List<Object?>) {
        final Map<String, Object?> l = (jsonDecode(j! as String) as Map)
            .cast<String, Object?>();
        apps.add((0, <Object?>[l['id'], 'p$i', 'v$i', l['kind'], l['at'], j]));
        if (server[l['id']] case final int st) {
          apps.add((1, <Object?>[l['id'], 'p$i', st]));
        }
      }
    }
    core.execBatch(<String>[
      'INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, '
          "review_type, origin, duration_ms, json) VALUES (srs_id(?), srs_id(?), srs_id(?), ?, NULL, ?, 'r', 'fushi', 0, ?)",
      'INSERT INTO srs_event_local (event_id, profile_uid, server_time) VALUES (srs_id(?), srs_id(?), ?)',
    ], apps);
  });

  tearDownAll(() {
    core.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });

  /// 按日界分组（一个命令一个日界）。
  Map<SrsDayContext, List<int>> byDay() {
    final Map<SrsDayContext, List<int>> out = <SrsDayContext, List<int>>{};
    for (int i = 0; i < vectors.length; i++) {
      final SrsDayContext d = _day(vectors[i]);
      out
          .putIfAbsent(
            out.keys.firstWhere(
              (SrsDayContext k) =>
                  k.utcOffsetMin == d.utcOffsetMin &&
                  k.rolloverHour == d.rolloverHour,
              orElse: () => d,
            ),
            () => <int>[],
          )
          .add(i);
    }
    return out;
  }

  test('向量规模哨兵', () {
    expect(vectors, hasLength(1200));
    expect(memory, hasLength(1200));
    int rows = 0;
    int reviews = 0;
    int items = 0;
    for (final Map<String, Object?> v in vectors) {
      rows +=
          ((v['rwkv']! as Map<String, Object?>)['rows']! as String).length ~/
          160;
      reviews +=
          ((v['stats']! as Map<String, Object?>)['reviews']! as List<Object?>)
              .length;
      items +=
          ((v['optimizer']! as Map<String, Object?>)['fsrs7'] as List<Object?>?)
              ?.length ??
          0;
    }
    expect(rows, greaterThan(1500));
    expect(reviews, greaterThan(3500));
    expect(items, greaterThan(200));
  });

  test('优化器训练集（ffsrs_store_optimizer_items）与旧 Dart 实现逐条一致', () {
    int checked = 0;
    for (final MapEntry<SrsDayContext, List<int>> e in byDay().entries) {
      final List<int> group = e.value;
      for (final SrsAlgorithm alg in <SrsAlgorithm>[
        SrsAlgorithm.fsrs6,
        SrsAlgorithm.fsrs7,
      ]) {
        final SrsTrainingSet set = SrsTrainingSet(
          core.optimizerItems(
            <List<String>>[
              for (final int i in group) <String>['v$i'],
            ],
            group,
            algorithm: srsProjectionAlgorithmCode(alg),
            utcOffsetMin: e.key.utcOffsetMin,
            rolloverHour: e.key.rolloverHour,
          ),
        );
        // 旧实现：逐卡 (时刻, 前缀长度)，全部按时刻稳定排序。
        final List<(int, int, int)> expected = <(int, int, int)>[];
        for (final int i in group) {
          final List<Object?>? items =
              (vectors[i]['optimizer']! as Map<String, Object?>)[alg.wire]
                  as List<Object?>?;
          for (final Object? it in items ?? const <Object?>[]) {
            final List<Object?> x = it! as List<Object?>;
            expected.add((x[0]! as int, i, x[1]! as int));
          }
        }
        final List<int> order =
            List<int>.generate(expected.length, (int k) => k)
              ..sort((int a, int b) {
                final int c = expected[a].$1.compareTo(expected[b].$1);
                return c != 0 ? c : a.compareTo(b);
              });
        expect(set.itemCount, expected.length);
        final SrsFsrsTrainingSet fsrs = set.fsrs;
        expect(fsrs.length, expected.length);
        for (int k = 0; k < order.length; k++) {
          final (int _, int card, int len) = expected[order[k]];
          expect(
            fsrs.cardIds![fsrs.itemCards[k]],
            card,
            reason: '${alg.wire} item $k',
          );
          final List<SrsFsrsReview> item = fsrs.item(k);
          expect(item, hasLength(len));
          // 序列 = 这张卡完整历史的记忆状态输入评审。
          final List<Object?> full =
              ((memory[card]['expect']! as Map<String, Object?>)[alg.wire]!
                      as Map<String, Object?>)['reviews']!
                  as List<Object?>;
          for (int r = 0; r < len; r++) {
            final List<Object?> want = full[r]! as List<Object?>;
            expect(item[r].rating, want[0]);
            // 打包训练集的间隔是 f32（与 SrsFsrsTrainingSetBuilder 同精度）。
            expect(
              item[r].deltaDays,
              Float32List.fromList(<double>[(want[1]! as num).toDouble()])[0],
            );
          }
          checked++;
        }
      }
    }
    expect(checked, greaterThan(400));
  });

  test('RWKV 逐卡 / 全量回放 / 此刻行与旧 Dart 实现逐字节一致', () {
    int rows = 0;
    for (final MapEntry<SrsDayContext, List<int>> e in byDay().entries) {
      final List<int> group = e.value;
      final List<SrsRwkvCardRows> cards = srsDecodeRwkvCards(
        core.rwkvCards(
          <List<String>>[
            for (final int i in group) <String>['v$i'],
          ],
          <int>[for (final int i in group) ..._ids(i)],
          utcOffsetMin: e.key.utcOffsetMin,
          rolloverHour: e.key.rolloverHour,
        ),
      );
      for (int k = 0; k < group.length; k++) {
        final int i = group[k];
        final Map<String, Object?> want =
            vectors[i]['rwkv']! as Map<String, Object?>;
        final SrsRwkvCardRows c = cards[k];
        expect(c.keptIds, want['kept'], reason: 'vector $i kept');
        expect(c.effectiveRatings, want['effectiveRatings']);
        final List<Object?>? last = want['last'] as List<Object?>?;
        expect(
          c.last == null
              ? null
              : <Object?>[c.last!.at, c.last!.rating, c.last!.reviewType],
          last,
        );
        // 全量回放（一份历史一个 profile）：按时刻排好序的行与 lastAt。
        final SrsRwkvReplay replay = srsDecodeRwkvReplay(
          core.rwkvReplay(
            'p$i',
            <List<String>>[
              <String>['v$i'],
            ],
            _ids(i),
            utcOffsetMin: e.key.utcOffsetMin,
            rolloverHour: e.key.rolloverHour,
            since: 0,
          ),
        );
        expect(_hex(replay.rows.bytes), want['rows'], reason: 'vector $i rows');
        expect(replay.lastAt, want['lastAt']);
        expect(replay.count, (vectors[i]['logs']! as List<Object?>).length);
        expect(replay.strays, isEmpty);
        rows += replay.rows.length;
        // 此刻行：四个队列。
        final Map<String, Object?> now = (want['now']! as Map)
            .cast<String, Object?>();
        for (final SrsQueue q in SrsQueue.values) {
          final RwkvRows r = srsRwkvNowRows(
            <SrsRwkvNowCard>[
              (
                cardId: 1000 + i,
                noteId: 2000 + i,
                deckId: 7,
                presetId: 9,
                last: c.last,
                queue: q,
              ),
            ],
            nowMs: want['nowMs']! as int,
            day: e.key,
          );
          expect(_hex(r.bytes), now[q.wire], reason: 'vector $i now ${q.wire}');
        }
      }
    }
    expect(rows, greaterThan(1500));
  });

  test('统计页取数（ffsrs_store_stat_projection）+ 投影与旧 Dart 实现逐条一致', () {
    int checked = 0;
    for (int i = 0; i < vectors.length; i++) {
      final Map<String, Object?> want =
          vectors[i]['stats']! as Map<String, Object?>;
      final (int _, List<List<Object?>> rows) = srsDecodeRows(
        core.statProjection(<List<String>>[
          <String>['v$i'],
        ]),
      );
      expect(rows.every((List<Object?> r) => r[0] == 0), isTrue);
      final ({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
      got = srsStatsFromProjection(<SrsStatProjection>[
        for (final List<Object?> r in rows) _projectionOf(r, 'v$i'),
      ], _day(vectors[i]));
      // 期望的 cardId 是向量日志 JSON 里的 card 字段；库里按 card_id 列分组（生产里两者相同）。
      expect(
        <List<Object?>>[
          for (final SrsStatReview r in got.reviews)
            <Object?>[
              r.at,
              r.day,
              r.hour,
              r.rating,
              r.kind.name,
              r.durationMs,
              r.early,
            ],
        ],
        <List<Object?>>[
          for (final Object? r in want['reviews']! as List<Object?>)
            (r! as List<Object?>).sublist(1),
        ],
        reason: 'vector $i reviews',
      );
      expect(
        <List<Object?>>[
          for (final SrsStatMaturityEvent m in got.maturity)
            <Object?>[m.day, m.delta],
        ],
        <List<Object?>>[
          for (final Object? m in want['maturity']! as List<Object?>)
            (m! as List<Object?>).sublist(1),
        ],
        reason: 'vector $i maturity',
      );
      // 记忆状态 = 同一份历史经 ffsrs_store_history_states 选取后最后一条有效结果的记忆。
      final SrsMemory? mem = srsDecodeHistoryStates(
        core.historyStates(<List<String>>[
          <String>['v$i'],
        ]),
        1,
      ).single.result.memory;
      expect(
        mem == null
            ? null
            : <double>[mem.stability, mem.difficulty, mem.stabilityFast],
        want['memory'],
        reason: 'vector $i memory',
      );
      if ((vectors[i]['logs']! as List<Object?>).isEmpty) {
        expect(want['reviews'], isEmpty);
        continue;
      }
      checked++;
    }
    expect(checked, greaterThan(1000));
  });
}
