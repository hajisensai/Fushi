// RWKV 排程接入：日志 → 回放行的转换规则、服务的增量追加 / 后台重建 / 快照缓存 / 自动下载失败、
// store 的 RWKV-Instant 排队（按此刻的 R 选复习卡、不看到期日、同日间隔守卫、计数同口径）。
// 后端用替身（真库 + 真权重的端到端在 packages/fushi_rwkv 的测试里）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000aa';
const int kDay = 86400000;

/// 记录收到的命令；查询按卡的数字 id 给 [r]（没设的给 [defaultR]）。快照 = 已回放的卡（JSON）。
class _FakeBackend implements SrsRwkvBackend {
  final List<int> replayedCards = <int>[];
  final Map<int, double> r = <int, double>{};
  double defaultR = 0.5;
  int resets = 0;
  int restores = 0;
  int queries = 0;
  bool closed = false;

  void setR(String cardId, double value) =>
      r[SrsIds.ankiNumericIds(<String>[cardId]).single] = value;

  @override
  Future<void> replay(RwkvRows rows) async {
    for (int i = 0; i < rows.length; i++) {
      replayedCards.add(rows.cardIdAt(i));
    }
  }

  @override
  Future<Float32List> query(RwkvRows rows) async {
    queries++;
    return Float32List.fromList(<double>[
      for (int i = 0; i < rows.length; i++) r[rows.cardIdAt(i)] ?? defaultR,
    ]);
  }

  @override
  Future<Uint8List> snapshot() async =>
      Uint8List.fromList(utf8.encode(jsonEncode(replayedCards)));

  @override
  Future<void> restore(Uint8List snapshot) async {
    restores++;
    replayedCards
      ..clear()
      ..addAll(
        (jsonDecode(utf8.decode(snapshot)) as List<Object?>).cast<int>(),
      );
  }

  @override
  Future<void> reset() async {
    resets++;
    replayedCards.clear();
  }

  @override
  Future<void> close() async => closed = true;
}

class _Fixture {
  _Fixture._(this.store, this.dir, this.clock);

  final SrsDbStore store;
  final Directory dir;
  final List<int> clock;

  static Future<_Fixture> create() async {
    final List<int> clock = <int>[
      DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch,
    ];
    final SrsStorage srsStorage = await openTestSrsStorage();
    final SrsDbStore store = await SrsDbStore.open(
      db: srsStorage.db,
      core: srsStorage.core,
      profileUid: kProfile,
      deviceId: 'dev',
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => clock[0],
        monotonicMs: () => clock[0],
        bootId: 'b',
      ),
    );
    return _Fixture._(
      store,
      Directory.systemTemp.createTempSync('srs_rwkv'),
      clock,
    );
  }

  void advance(int ms) => clock[0] += ms;

  Future<List<String>> cards(int n) async {
    final List<String> out = <String>[];
    for (int i = 0; i < n; i++) {
      final String noteId = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): 'w$i',
        },
      );
      out.add((await store.cardsOfNote(noteId)).single.id);
    }
    return out;
  }

  /// 新卡答 Easy 直接毕业成复习卡（假引擎：间隔 6 天）。
  Future<void> graduate(List<String> cards) async {
    for (final String c in cards) {
      await store.answer(c, 4);
      advance(1000);
    }
  }

  Future<void> useAlgorithm(SrsAlgorithm algorithm) async {
    await store.editFields(
      SrsEntityKind.deck,
      store.defaultDeckId,
      <String, Object?>{
        SrsFieldKeys.deckAlgorithm: <String, Object?>{
          'alg': algorithm.wire,
          'auto': false,
        },
      },
    );
  }

  /// 权重「已就绪」：替身后端不读它，只要长度与校验标记对得上。没就绪时下载一律失败（不碰网络）。
  SrsRwkvModels models({bool ready = true}) {
    final Directory modelDir = Directory('${dir.path}/models')
      ..createSync(recursive: true);
    final SrsRwkvModels models = SrsRwkvModels(
      dir: modelDir,
      createClient: () =>
          throw const SocketException('network disabled in tests'),
    );
    if (ready) {
      final File weights = models.weightsFile
        ..writeAsBytesSync(Uint8List(kSrsRwkvSmallWeightsBytes));
      File(
        '${weights.path}.verified',
      ).writeAsStringSync(kSrsRwkvSmallWeightsSha256);
    }
    return models;
  }

  SrsRwkvService service(_FakeBackend backend, {bool ready = true}) =>
      SrsRwkvService(
        store: store,
        models: models(ready: ready),
        snapshotDir: Directory('${dir.path}/state'),
        openBackend: (File weights) async => backend,
      );

  Future<int> reviewCount() async =>
      (await store.deckSummary(store.defaultDeckId))!.reviewCount;
}

Future<void> _settled(SrsRwkvService service) async {
  for (int i = 0; i < 500; i++) {
    if (service.status.phase == SrsRwkvPhase.ready) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail(
    'RWKV service did not become ready: ${service.status.phase} ${service.status.error}',
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('默认算法是 RWKV（Instant）', () async {
    expect(srsDefaultAlgorithm, SrsAlgorithm.rwkv);
    final _Fixture f = await _Fixture.create();
    final SrsSchedulingConfig config = await f.store.schedulingConfigFor(
      f.store.defaultDeckId,
    );
    expect(config.algorithm, SrsAlgorithm.rwkv);
    // 记忆状态与存下的到期日仍由 FSRS-7 维护。
    expect(config.algorithm.memoryAlgorithm, SrsAlgorithm.fsrs7);
  });

  group('日志 → 回放行', () {
    test('按时间排序、card_type 与 elapsed 按上游规则；重置之前的丢弃', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(2);
      await f.store.answer(cards[0], 3); // 学习起点
      f.advance(60000);
      await f.store.answer(cards[1], 1);
      f.advance(kDay);
      await f.store.answer(cards[0], 3);
      f.advance(kDay * 3);
      await f.store.answer(cards[0], 3);
      final SrsDayContext day = await f.store.dayContext();
      List<int> ids(int i) => <int>[10 + i, 20 + i, 1, 1];
      final SrsRwkvReplay replay = await f.store.rwkvReplay(
        cards,
        <int>[...ids(0), ...ids(1)],
        day,
        since: 0,
      );
      final RwkvRows rows = replay.rows;
      expect(rows.length, 4);
      expect(
        <int>[for (int i = 0; i < 4; i++) rows.cardIdAt(i)],
        <int>[10, 11, 10, 10],
      );
      expect(replay.lastAt, f.clock[0]);
      expect(replay.count, 4);
      expect(replay.strays, isEmpty);
      final ByteData b = ByteData.sublistView(rows.bytes);
      int field(int row, int index) =>
          b.getInt64(row * 80 + 8 * index, Endian.little);
      // 第一条：学习序列起点 card_type 0，elapsed -1。
      expect(field(0, 5), 0);
      expect(field(0, 7), -1);
      expect(field(0, 8), -1);
      // 卡 0 的第三条：距上一条 3 天 / 3*86400 秒。
      expect(field(3, 7), 3);
      expect(field(3, 8), 3 * 86400);
      // day_offset 单调不减。
      for (int i = 1; i < 4; i++) {
        expect(field(i, 6), greaterThanOrEqualTo(field(i - 1, 6)));
      }

      // 「此刻」的查询行：间隔从最后一条保留评分算，ease 0。
      final SrsRwkvCardRows card0 = (await f.store.rwkvCardRows(
        <String>[cards[0]],
        ids(0),
        day,
      )).single;
      f.advance(kDay * 2);
      final RwkvRows now = srsRwkvNowRows(
        <SrsRwkvNowCard>[
          (
            cardId: 10,
            noteId: 20,
            deckId: 1,
            presetId: 1,
            last: card0.last,
            queue: SrsQueue.review,
          ),
        ],
        nowMs: f.clock[0],
        day: day,
      );
      final ByteData nb = ByteData.sublistView(now.bytes);
      expect(nb.getInt64(7 * 8, Endian.little), 2);
      expect(nb.getInt64(8 * 8, Endian.little), 2 * 86400);
      expect(now.easeAt(0), 0);

      // 撤销卡 0 最后一条：保留评分少一条，「追加最后一条」不再成立。
      final String last = card0.keptIds.last;
      expect(card0.appendRows(<String>[last]), isNotNull);
      expect(await f.store.undo(cards[0], last), isTrue);
      final SrsRwkvCardRows undone = (await f.store.rwkvCardRows(
        <String>[cards[0]],
        ids(0),
        day,
      )).single;
      expect(undone.keptIds, hasLength(2));
      expect(undone.appendRows(<String>[last]), isNull);
    });
  });

  group('服务', () {
    test('启动全量回放；作答只追加这一条；撤销触发后台重建；快照命中', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(3);
      await f.graduate(cards);
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      await service.start();
      await _settled(service);
      expect(backend.resets, 1);
      expect(backend.replayedCards, hasLength(3));

      f.advance(kDay);
      final String? next = await f.store.nextCard(f.store.defaultDeckId);
      expect(next, isNotNull);
      expect(backend.queries, greaterThan(0));
      final SrsAnswerPreview preview = await f.store.preview(next!);
      // 这次是按 R 进的队：日志记 rwkv（统计据此区分）；间隔与记忆状态仍是 FSRS-7 算的。
      expect(preview.algorithm, SrsAlgorithm.rwkv);
      expect(preview.rwkvUnavailable, isFalse);
      expect(preview.params, hasLength(SrsAlgorithm.fsrs7.paramCount));

      final SrsReviewLog log = await f.store.answer(next, 3);
      expect(log.algorithm, 'rwkv');
      await service.refresh();
      expect(
        backend.resets,
        1,
        reason: 'a new answer is appended, not a rebuild',
      );
      expect(backend.replayedCards, hasLength(4));

      // 撤销改写了历史：后台重建，回到 3 条。
      expect(await f.store.undo(next, log.id), isTrue);
      expect(await service.refresh(), isFalse);
      await _settled(service);
      expect(backend.resets, 2);
      expect(backend.replayedCards, hasLength(3));

      // 关闭存快照；新服务从快照恢复，不重建。
      await service.close();
      expect(backend.closed, isTrue);
      final _FakeBackend second = _FakeBackend();
      final SrsRwkvService again = f.service(second);
      await again.start();
      await _settled(again);
      expect(second.restores, 1);
      expect(second.resets, 0);
      expect(second.replayedCards, hasLength(3));
      await again.close();
    });

    test('两次对齐之间同一张卡答了两次（学习步「重来」后再答）：照样追加，不全量重建', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(2);
      await f.graduate(cards);
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      await service.start();
      await _settled(service);
      expect(backend.resets, 1);
      expect(backend.replayedCards, hasLength(2));

      f.advance(kDay);
      await f.store.answer(cards[0], 1);
      f.advance(60000);
      await f.store.answer(cards[0], 3);
      f.advance(1000);
      await f.store.answer(cards[1], 3);
      expect(await service.refresh(), isTrue);
      expect(backend.resets, 1, reason: '只追加新的三条');
      expect(service.status.phase, SrsRwkvPhase.ready);
      expect(backend.replayedCards, hasLength(5));
      await service.close();
    });

    test('全量重建读历史途中用户还在答题：不重复回放、对齐时也不再触发第二次重建', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(3);
      await f.graduate(cards);
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      bool answered = false;
      service.debugAfterRebuildFingerprint = () async {
        if (answered) return;
        answered = true;
        // 记下指纹之后、读历史之前答了两张卡（先 0 后 1）。
        f.advance(kDay);
        await f.store.answer(cards[0], 3);
        f.advance(1000);
        await f.store.answer(cards[1], 3);
      };
      await service.start();
      await _settled(service);
      expect(backend.resets, 1);
      expect(backend.replayedCards, hasLength(5), reason: '3 次毕业 + 2 次作答，各一次');

      expect(await service.refresh(), isTrue);
      expect(backend.resets, 1, reason: '不因「比已回放的最后一条更早」再重建');
      expect(backend.replayedCards, hasLength(5), reason: '不把已回放的再追加一遍');

      f.advance(1000);
      await f.store.answer(cards[2], 3);
      expect(await service.refresh(), isTrue);
      expect(backend.replayedCards, hasLength(6));
      await service.close();
    });

    test('权重没下载、下载失败：按存下的到期日排队并标出来，不碰网络', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(1);
      await f.graduate(cards);
      final _FakeBackend backend = _FakeBackend()..defaultR = 0.1;
      final SrsRwkvService service = f.service(backend, ready: false);
      f.store.rwkv = service;
      final SrsAnswerPreview preview = await f.store.preview(cards.single);
      // 没按 R 排：日志记 FSRS-7。
      expect(preview.algorithm, SrsAlgorithm.fsrs7);
      expect(preview.rwkvUnavailable, isTrue);
      // 还没到 FSRS 的到期日：照到期日排就没有复习卡（RWKV 的 R 再低也用不上）。
      f.advance(kDay);
      expect(await f.store.nextCard(f.store.defaultDeckId), isNull);
      for (int i = 0; i < 500; i++) {
        if (service.status.phase == SrsRwkvPhase.failed) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.status.phase, SrsRwkvPhase.failed);
      expect(backend.queries, 0);
      // 过了 FSRS 的到期日（6 天，带 fuzz）就照常出。
      f.advance(kDay * 10);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards.single);
      await service.close();
    });

    test('FSRS 牌组不碰 RWKV', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(1);
      await f.useAlgorithm(SrsAlgorithm.fsrs7);
      await f.graduate(cards);
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      await service.start();
      final SrsAnswerPreview preview = await f.store.preview(cards.single);
      expect(preview.algorithm, SrsAlgorithm.fsrs7);
      expect(preview.rwkvUnavailable, isFalse);
      f.advance(kDay * 10); // 过了 FSRS 的到期日（6 天，带 fuzz）
      expect(await f.store.nextCard(f.store.defaultDeckId), cards.single);
      expect(backend.queries, 0);
      await service.close();
    });
  });

  group('RWKV-Instant 排队', () {
    late _Fixture f;
    late List<String> cards;
    late _FakeBackend backend;
    late SrsRwkvService service;

    setUp(() async {
      f = await _Fixture.create();
      cards = await f.cards(8);
      await f.graduate(cards); // 都是复习卡，FSRS 的到期日在 6 天后
      backend = _FakeBackend()..defaultR = 0.95;
      service = f.service(backend);
      f.store.rwkv = service;
      await service.start();
      await _settled(service);
    });

    tearDown(() => service.close());

    test('不看到期日：没到期但 R ≤ 目标的按 R 升序出，计数同口径', () async {
      f.advance(kDay);
      backend
        ..setR(cards[0], 0.9)
        ..setR(cards[1], 0.6)
        ..setR(cards[2], 0.7);
      expect(await f.reviewCount(), 2);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[1]);
      expect(
        await f.store.nextCard(
          f.store.defaultDeckId,
          exclude: <String>{cards[1]},
        ),
        cards[2],
      );
    });

    test('到期了但 R 高于目标：不出', () async {
      f.advance(kDay * 30); // FSRS 早就到期
      expect(await f.reviewCount(), 0);
      expect(await f.store.nextCard(f.store.defaultDeckId), isNull);
      // 只有一张合格时只出它：别的卡按到期日早就该复习、FSRS 的 R 还更低，也不出。
      f.advance(31000);
      backend.setR(cards[3], 0.7);
      expect(await f.reviewCount(), 1);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[3]);
      expect(
        await f.store.nextCard(
          f.store.defaultDeckId,
          exclude: <String>{cards[3]},
        ),
        isNull,
      );
      // 目标保留率是牌组设置：调高到 0.97，R 0.95 的卡全部合格。
      await f.store.editFields(
        SrsEntityKind.deck,
        f.store.defaultDeckId,
        <String, Object?>{SrsFieldKeys.deckRetention: 0.97},
      );
      expect(await f.reviewCount(), cards.length);
    });

    test('同日重复的间隔守卫：30 秒且别的卡答过 5 次后才再出', () async {
      f.advance(kDay);
      backend.setR(cards[0], 0.1);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[0]);
      await f.store.answer(cards[0], 3); // 仍是复习卡，R 仍最低
      await service.refresh();
      for (int i = 1; i <= 5; i++) {
        backend.setR(cards[i], 0.5);
      }
      f.advance(40000);
      // 30 秒过了，但别的卡还没答够 5 次。
      expect(await f.store.nextCard(f.store.defaultDeckId), isNot(cards[0]));
      for (int i = 1; i <= 5; i++) {
        await f.store.answer(cards[i], 3);
        f.advance(1000);
      }
      await service.refresh();
      f.advance(31000);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[0]);
    });

    test('同日重复的间隔守卫可调：0 次 / 10 秒时 10 秒后就再出', () async {
      await f.store.editFields(
        SrsEntityKind.deck,
        f.store.defaultDeckId,
        <String, Object?>{
          SrsFieldKeys.deckRwkvQueue: const SrsRwkvQueueSettings(
            repeatMinReviews: 0,
            repeatMinSeconds: 10,
          ).toValue(),
        },
      );
      f.advance(kDay);
      backend.setR(cards[0], 0.1);
      await f.store.answer(cards[0], 3);
      await service.refresh();
      f.advance(5000);
      expect(await f.store.nextCard(f.store.defaultDeckId), isNull);
      f.advance(6000);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[0]);
    });

    test('每天最少复习数：R 都高于目标时按 R 升序补足，今天复习过的算进去', () async {
      f.advance(kDay);
      backend
        ..setR(cards[2], 0.85)
        ..setR(cards[5], 0.82);
      // 默认 0 = 不启用：R 全高于 0.8，不出。
      expect(await f.reviewCount(), 0);
      await f.store.editFields(
        SrsEntityKind.deck,
        f.store.defaultDeckId,
        <String, Object?>{
          SrsFieldKeys.deckRwkvQueue: const SrsRwkvQueueSettings(
            minReviewsPerDay: 3,
          ).toValue(),
        },
      );
      expect(await f.reviewCount(), 3);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[5]);
      await f.store.answer(cards[5], 3);
      await service.refresh();
      f.advance(1000);
      // 今天已复习 1 张：只再补 2 张；刚答的那张被间隔守卫挡住。
      expect(await f.reviewCount(), 2);
      expect(await f.store.nextCard(f.store.defaultDeckId), cards[2]);
    });

    test('手动重建：重置后按全部历史重新回放，回到就绪', () async {
      final int resetsBefore = backend.resets;
      backend.replayedCards.clear();
      await service.rebuild();
      expect(service.status.phase, SrsRwkvPhase.ready);
      expect(backend.resets, resetsBefore + 1);
      expect(backend.replayedCards, isNotEmpty);
    });
  });

  group('统计 / 浏览 / 词状态：按 R 排队的卡不按到期日解读', () {
    test('未来到期不计、可提取度用 RWKV；`is:due` 与出卡同口径；词状态不写天数', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(3);
      await f.graduate(cards);
      final _FakeBackend backend = _FakeBackend()..defaultR = 0.95;
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      await service.start();
      await _settled(service);
      f.advance(kDay);
      backend.setR(cards[0], 0.42);

      final SrsStatsBundle stats = await loadSrsStats(f.store);
      final SrsFutureDue due = stats.data.futureDue(30);
      expect(due.byRecall, 3);
      expect(due.total, 0);
      expect(due.overdue, 0);
      expect(due.dailyLoad, 0);
      final SrsStatCard c0 = stats.data.cards.firstWhere(
        (SrsStatCard c) => c.id == cards[0],
      );
      expect(c0.byRecall, isTrue);
      expect(c0.retrievability, closeTo(0.42, 1e-6));

      final SrsBrowseSnapshot browse = await SrsBrowseSnapshot.load(f.store);
      final Map<String, SrsCardSearchSubject> byId =
          <String, SrsCardSearchSubject>{
            for (final SrsCardSearchSubject c in browse.cards) c.card.id: c,
          };
      expect(byId[cards[0]]!.isDue, isTrue);
      expect(byId[cards[1]]!.isDue, isFalse);
      expect(byId[cards[0]]!.dueInDays, isNull);
      browse.dispose();

      final Map<String, SrsTermStatus> term = await f.store.lookupTermStatus(
        const <SrsTermQuery>[SrsTermQuery('w0', null)],
      );
      expect(term['w0']!.byRecall, isTrue);

      // RWKV 用不了：照旧按存下的到期日（排队也是），统计也照旧。
      await service.close();
      final SrsFutureDue fallback = (await loadSrsStats(
        f.store,
      )).data.futureDue(30);
      expect(fallback.byRecall, 0);
      expect(fallback.total, 3);
    });
  });
}
