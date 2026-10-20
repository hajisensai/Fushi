// RWKV 排程接入：日志 → 回放行的转换规则、服务的增量追加 / 后台重建 / 快照缓存、store 的
// preview / answer 走 RWKV 间隔。后端用替身（真库 + 真权重的端到端在 packages/fushi_rwkv 的测试里）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_history.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000aa';
const int kDay = 86400000;

/// 记录收到的命令；排程永远给 [days]。快照 = 已回放条数（JSON）。
class _FakeBackend implements SrsRwkvBackend {
  final List<int> replayedCards = <int>[];
  int resets = 0;
  int restores = 0;
  int intervalCalls = 0;
  List<int> days = <int>[1, 4, 9, 20];
  bool closed = false;

  @override
  Future<void> replay(RwkvRows rows) async {
    for (int i = 0; i < rows.length; i++) {
      replayedCards.add(rows.cardIdAt(i));
    }
  }

  @override
  Future<RwkvIntervals> nextIntervals(
    RwkvRows answer, {
    required double targetRetention,
    required int maxIntervalDays,
  }) async {
    intervalCalls++;
    return RwkvIntervals(days, <double>[0.8, 0.8, 0.8, 0.8]);
  }

  @override
  Future<Uint8List> snapshot() async =>
      Uint8List.fromList(utf8.encode(jsonEncode(replayedCards)));

  @override
  Future<void> restore(Uint8List snapshot) async {
    restores++;
    replayedCards
      ..clear()
      ..addAll((jsonDecode(utf8.decode(snapshot)) as List<Object?>).cast<int>());
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
    final List<int> clock = <int>[DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch];
    final SrsDbStore store = await SrsDbStore.open(
      db: FushiDatabase.forTesting(NativeDatabase.memory()),
      profileUid: kProfile,
      deviceId: 'dev',
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => clock[0],
        monotonicMs: () => clock[0],
        bootId: 'b',
      ),
    );
    return _Fixture._(store, Directory.systemTemp.createTempSync('srs_rwkv'), clock);
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

  Future<void> useRwkv() async {
    await store.editFields(SrsEntityKind.deck, store.defaultDeckId, <String, Object?>{
      SrsFieldKeys.deckAlgorithm: <String, Object?>{'alg': 'rwkv', 'auto': false},
    });
  }

  /// 权重「已就绪」：替身后端不读它，只要长度与校验标记对得上。
  SrsRwkvModels models({bool ready = true}) {
    final Directory modelDir = Directory('${dir.path}/models')..createSync(recursive: true);
    final SrsRwkvModels models = SrsRwkvModels(dir: modelDir);
    if (ready) {
      final File weights = models.weightsFile(SrsRwkvModelChoice.small)
        ..writeAsBytesSync(Uint8List(kSrsRwkvSmallWeightsBytes));
      File('${weights.path}.verified').writeAsStringSync(kSrsRwkvSmallWeightsSha256);
    }
    return models;
  }

  SrsRwkvService service(_FakeBackend backend, {bool ready = true}) => SrsRwkvService(
    store: store,
    models: models(ready: ready),
    choice: SrsRwkvModelChoice.small,
    snapshotDir: Directory('${dir.path}/state'),
    openBackend: (File weights, SrsRwkvModelChoice choice) async => backend,
  );
}

Future<void> _settled(SrsRwkvService service) async {
  for (int i = 0; i < 500; i++) {
    if (service.status.phase == SrsRwkvPhase.ready) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('RWKV service did not become ready: ${service.status.phase} ${service.status.error}');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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
      final Map<String, SrsCardHistory> h = await f.store.histories(cards);
      SrsRwkvCard card(int i) => SrsRwkvCard(
        cardId: 10 + i,
        noteId: 20 + i,
        deckId: 1,
        presetId: 1,
        history: h[cards[i]]!,
      );
      final (RwkvRows rows, int? lastAt) = srsRwkvReplayRows(<SrsRwkvCard>[card(0), card(1)], day);
      expect(rows.length, 4);
      expect(<int>[for (int i = 0; i < 4; i++) rows.cardIdAt(i)], <int>[10, 11, 10, 10]);
      expect(lastAt, f.clock[0]);
      final ByteData b = ByteData.sublistView(rows.bytes);
      int field(int row, int index) => b.getInt64(row * 80 + 8 * index, Endian.little);
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

      // 撤销卡 0 最后一条：保留评分少一条，「追加最后一条」不再成立。
      final SrsReviewLog last = h[cards[0]]!.effectiveRatings.last;
      expect(srsRwkvAppendRow(card(0), last, day), isNotNull);
      expect(await f.store.undo(cards[0], last.id), isTrue);
      final SrsCardHistory undone = await f.store.history(cards[0]);
      expect(srsRwkvKeptRatings(undone), hasLength(2));
      expect(
        srsRwkvAppendRow(
          SrsRwkvCard(cardId: 10, noteId: 20, deckId: 1, presetId: 1, history: undone),
          last,
          day,
        ),
        isNull,
      );
    });
  });

  group('服务', () {
    test('启动全量回放；作答用 RWKV 间隔并只追加这一条；撤销触发后台重建；快照命中', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(3);
      await f.useRwkv();
      for (final String c in cards) {
        await f.store.answer(c, 3);
        f.advance(1000);
      }
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      await service.start();
      await _settled(service);
      expect(backend.resets, 1);
      expect(backend.replayedCards, hasLength(3));

      f.advance(kDay * 2);
      final SrsAnswerPreview preview = await f.store.preview(cards[0]);
      expect(preview.algorithm, SrsAlgorithm.rwkv);
      expect(preview.rwkvUnavailable, isFalse);
      expect(backend.intervalCalls, 1);

      final SrsReviewLog log = await f.store.answer(cards[0], 3);
      expect(log.algorithm, 'rwkv');
      await service.refresh();
      expect(backend.resets, 1, reason: 'a new answer is appended, not a rebuild');
      expect(backend.replayedCards, hasLength(4));

      // 撤销改写了历史：后台重建，回到 3 条。
      expect(await f.store.undo(cards[0], log.id), isTrue);
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

    test('权重没下载：RWKV 牌组这一次按 FSRS-7 排并标出来', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(1);
      await f.useRwkv();
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend, ready: false);
      f.store.rwkv = service;
      final SrsAnswerPreview preview = await f.store.preview(cards.single);
      expect(preview.algorithm, SrsAlgorithm.fsrs7);
      expect(preview.rwkvUnavailable, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.status.phase, SrsRwkvPhase.needsModel);
      final SrsReviewLog log = await f.store.answer(cards.single, 3);
      expect(log.algorithm, 'fsrs7');
      expect(backend.intervalCalls, 0);
      await service.close();
    });

    test('FSRS 牌组不碰 RWKV', () async {
      final _Fixture f = await _Fixture.create();
      final List<String> cards = await f.cards(1);
      final _FakeBackend backend = _FakeBackend();
      final SrsRwkvService service = f.service(backend);
      f.store.rwkv = service;
      final SrsAnswerPreview preview = await f.store.preview(cards.single);
      expect(preview.algorithm, SrsAlgorithm.fsrs7);
      expect(preview.rwkvUnavailable, isFalse);
      expect(backend.intervalCalls, 0);
      await service.close();
    });
  });
}
