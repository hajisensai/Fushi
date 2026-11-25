// P6（统计 / 优化器训练集 / RWKV 回放行的取数收编进 Rust）之后的端到端回归门：
//
// 固定向量 test/srs/fixtures/p6_vectors.json.gz 由**删除前的 Dart 实现**生成（脚本留档
// test/srs/fixtures/gen_p6_vectors.dart.txt）：1200 份随机历史，期望值是旧的 `srsPrepareOptimization`
// 循环体（逐卡训练条目）、`SrsRwkvReplayBuilder` / `srsRwkvKeptRatings` / `SrsRwkvLastRating.of` /
// `srsRwkvAddNowRow`（回放行字节、此刻行字节）、`srsStatsFromHistory` + `SrsCardHistory.state.memory`
// （统计投影；现由 Rust `history::stats_from_json` 经 `ffsrs_store_stat_projection` 产出）。
//
// 向量日志（落库原文 + 服务器时刻）在冻结的协议 3 库 test/srs/fixtures/p6_vectors.db.gz 里：换代之前（集成分支
// pr/srs-gen4-switch 合入 S1 前最后一个协议 3 提交 5ad47c2edb）的本测试在 setUpAll 灌完 1200 份历史后，逐个
// profile 发 `identity` 与 `migrate`（把投影里的日志收进操作日志），再 `snapshotInto(stripDeviceLocal: false)` 并
// gzip（与 srs_stats_vectors.db.gz 同一种造法；那一版的 4 条用例在生成时同样全绿）。这里把它走一遍换代迁移再经
// 新代的 `ffsrs_store_*` 直读命令取回，解包后与旧实现逐条比较——走的就是生产路径（迁移 → 新代读 → 选取 → 投影 →
// 字节布局 → Dart 解包）。要真实原生库。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

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

/// `SrsCore.statProjection` 的行（9 列，见其文档）按 [day] 的日界读成统计复习 `[at, day, hour, rating, kind, ms, early]`
/// 与成熟变化 `[day, delta]`（读方口径；生产里由内核 store/stats.rs 的 `View::build` 做同一件事）。
({List<List<Object?>> reviews, List<List<Object?>> maturity}) _readProjection(
  List<List<Object?>> rows,
  SrsDayContext day,
) {
  const List<String> kinds = <String>[
    'newCard',
    'learn',
    'young',
    'mature',
    'relearn',
    'filtered',
  ];
  final List<List<Object?>> reviews = <List<Object?>>[];
  final List<List<Object?>> maturity = <List<Object?>>[];
  for (final List<Object?> r in rows) {
    final int at = r[2]! as int;
    final int dayIndex = day.dayIndexOf(at);
    final int? rating = r[4] as int?;
    final int? prevDue = r[7] as int?;
    if (rating != null) {
      reviews.add(<Object?>[
        at,
        dayIndex,
        ((at + (r[3]! as int) * 60000) % 86400000) ~/ 3600000,
        rating,
        kinds[r[5]! as int],
        r[6]! as int,
        prevDue != null && prevDue > dayIndex,
      ]);
    }
    final int delta = r[8]! as int;
    if (delta != 0) maturity.add(<Object?>[dayIndex, delta]);
  }
  return (reviews: reviews, maturity: maturity);
}

void main() {
  final List<Map<String, Object?>> vectors = _load(
    'test/srs/fixtures/p6_vectors.json.gz',
  );
  // 同一批历史的记忆状态输入（训练集序列 = 完整历史的评审）。
  final List<Map<String, Object?>> memory = _load(
    '../fushi_srs/test/memory/fixtures/memory_input_vectors.json.gz',
  );
  late SrsCore core;

  setUpAll(() async {
    expect(FushiFsrs.instance, isNotNull, reason: 'fushi_fsrs 原生库缺失');
    // 协议 3 冻结库：第 i 份历史 = profile `p$i` 的卡 `v$i`（每份一个 profile），日志与服务器时刻灌进
    // srs_review_logs / srs_event_local、经 `migrate` 收进操作日志后整库快照（生成方法见文件头）。放进库目录当
    // 封存旧库、走换代迁移（每个 profile 一份 srsCacheConfigFor）再开新代库——用户升级的同一条路。
    final TestSrs srs = await openMigratedTestSrs(
      gzip.decode(File('test/srs/fixtures/p6_vectors.db.gz').readAsBytesSync()),
      prefix: 'srs_p6_vectors_',
    );
    core = srs.core;
  });

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
    for (int i = 0; i < vectors.length; i++) {
      final SrsDayContext day = _day(vectors[i]);
      // 新代按 profile 取数：一份历史一个 profile，一条命令只问一个 profile。
      final List<int> group = <int>[i];
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
            utcOffsetMin: day.utcOffsetMin,
            rolloverHour: day.rolloverHour,
            profile: 'p$i',
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
    for (int i0 = 0; i0 < vectors.length; i0++) {
      final SrsDayContext day = _day(vectors[i0]);
      final List<int> group = <int>[i0];
      final List<SrsRwkvCardRows> cards = srsDecodeRwkvCards(
        core.rwkvCards(
          <List<String>>[
            for (final int i in group) <String>['v$i'],
          ],
          <int>[for (final int i in group) ..._ids(i)],
          utcOffsetMin: day.utcOffsetMin,
          rolloverHour: day.rolloverHour,
          profile: 'p$i0',
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
          core
              .rwkvReplay(
                'p$i',
                <List<String>>[
                  <String>['v$i'],
                ],
                _ids(i),
                utcOffsetMin: day.utcOffsetMin,
                rolloverHour: day.rolloverHour,
                since: 0,
              )
              .materialize()
              .asUint8List(),
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
            day: day,
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
        ], profile: 'p$i'),
      );
      expect(rows.every((List<Object?> r) => r[0] == 0), isTrue);
      final ({List<List<Object?>> reviews, List<List<Object?>> maturity}) got =
          _readProjection(rows, _day(vectors[i]));
      // 期望的 cardId 是向量日志 JSON 里的 card 字段；库里按 card_id 列分组（生产里两者相同）。
      expect(got.reviews, <List<Object?>>[
        for (final Object? r in want['reviews']! as List<Object?>)
          (r! as List<Object?>).sublist(1),
      ], reason: 'vector $i reviews');
      expect(got.maturity, <List<Object?>>[
        for (final Object? m in want['maturity']! as List<Object?>)
          (m! as List<Object?>).sublist(1),
      ], reason: 'vector $i maturity');
      // 记忆状态 = 同一份历史经 ffsrs_store_history_states 选取后最后一条有效结果的记忆。
      final SrsMemory? mem = srsDecodeHistoryStates(
        core.historyStates(<List<String>>[
          <String>['v$i'],
        ], profile: 'p$i'),
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
