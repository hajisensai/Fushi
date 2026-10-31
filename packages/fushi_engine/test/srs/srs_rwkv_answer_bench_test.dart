// 手动基准：真库（后台 isolate 连接）+ 真 RWKV worker（小模型 int4）上「作答一次 → 出下一张」与
// 「撤销 → 出下一张」的端到端耗时（含 FFI、isolate 往返、SQL）。默认跳过：
//   FUSHI_SRS_RWKV_BENCH=<笔记数>（每条两张卡）dart test test/srs/srs_rwkv_answer_bench_test.dart
// 对比分数表整表重查频率：再加 FUSHI_SRS_RWKV_REQUERY=<每几题重查一次>；
// FUSHI_SRS_RWKV_THINK_MS=<毫秒> 模拟每题之间看卡的工夫。
// 权重：native/fushi_rwkv/model/sm56_weights.int8.bin（native/fushi_rwkv/fetch_model.*）。
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';

class _Worker implements SrsRwkvBackend {
  _Worker(this.worker);
  final RwkvWorker worker;
  @override
  Future<void> replay(RwkvRows rows) => worker.replay(rows);
  @override
  Future<Float32List> query(RwkvRows rows) => worker.query(rows);
  @override
  Future<Uint8List> snapshot() => worker.snapshot();
  @override
  Future<void> restore(Uint8List snapshot) => worker.restore(snapshot);
  @override
  Future<void> reset() => worker.reset();
  @override
  Future<void> close() => worker.close();
  @override
  Future<bool> append(RwkvRows rows, List<int> tags, List<int> ats) =>
      worker.append(rows, tags, ats);
  @override
  Future<bool> unappend(int tag) => worker.unappend(tag);
  @override
  Future<int?> rewindFrom(int atMs, int floorMs) =>
      worker.rewindFrom(atMs, floorMs);
  @override
  Future<void> clearScores() => worker.clearScores();
  @override
  Future<RwkvScoreLookup> lookupScores(
    Int64List cardIds,
    Uint64List versions,
  ) => worker.lookupScores(cardIds, versions);
  @override
  Future<Float32List> updateScores(
    RwkvRows rows,
    Uint64List versions,
    Int64List anchorsMs,
  ) => worker.updateScores(rows, versions, anchorsMs);
  @override
  Future<int> requeryScores(int today, int nowMs) =>
      worker.requeryScores(today, nowMs);
  @override
  Future<int> removeScores(Int64List cardIds) => worker.removeScores(cardIds);
}

String _weights() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final File f = File(
      '${dir.path}/native/fushi_rwkv/model/$kSrsRwkvSmallWeightsName',
    );
    if (f.existsSync()) return f.path;
    dir = dir.parent;
  }
  throw StateError('weights missing: run native/fushi_rwkv/fetch_model.*');
}

Future<void> _settled(SrsRwkvService s) async {
  while (s.status.phase != SrsRwkvPhase.ready) {
    if (s.status.phase == SrsRwkvPhase.failed) {
      fail('RWKV failed: ${s.status.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final int? notes = int.tryParse(
    Platform.environment['FUSHI_SRS_RWKV_BENCH'] ?? '',
  );
  test(
    'RWKV 作答 / 撤销端到端耗时',
    () async {
      final BulkFixture f = await BulkFixture.open(
        notes: notes!,
        background: true,
      );
      final SrsDbStore store = f.store;
      final String weights = _weights();
      final Directory tmp = Directory.systemTemp.createTempSync('rwkv_bench');
      final SrsRwkvModels models = SrsRwkvModels(dir: tmp);
      File(weights).copySync(models.weightsFile.path);
      File(
        '${models.weightsFile.path}.verified',
      ).writeAsStringSync(kSrsRwkvSmallWeightsSha256);
      final SrsRwkvService service = SrsRwkvService(
        store: store,
        models: models,
        snapshotDir: Directory('${tmp.path}/state'),
        openBackend: (File _) async => _Worker(
          await RwkvWorker.spawn(
            modelPath: weights,
            precision: RwkvPrecision.int4,
          ),
        ),
      );
      // FUSHI_SRS_RWKV_REQUERY=<N>：牌组设置「每答几题刷新」（缺省 1，同上游）。
      final int? refreshEvery = int.tryParse(
        Platform.environment['FUSHI_SRS_RWKV_REQUERY'] ?? '',
      );
      if (refreshEvery != null) {
        final SrsDeckTree tree = await store.deckTree();
        await store.editFields(
          SrsEntityKind.deck,
          tree.paramsOwner(await deckId(store, 'Lang')).id,
          <String, Object?>{
            SrsFieldKeys.deckRwkvQueue: SrsRwkvQueueSettings(
              refreshEvery: refreshEvery,
            ).toValue(),
          },
        );
      }
      store.rwkv = service;
      final Stopwatch sw = Stopwatch()..start();
      await service.start();
      await _settled(service);
      print('cold rebuild: ${sw.elapsedMilliseconds} ms');
      final String deck = await deckId(store, 'Lang');
      sw.reset();
      await store.nextCard(deck);
      final List<String> pool = <String>[
        for (final r
            in await store.db
                .customSelect(
                  "SELECT id FROM srs_cards_cache WHERE queue = 'review' ORDER BY id LIMIT 8",
                )
                .get())
          r.read<String>('id'),
      ];
      final int reviewCards =
          (await store.db
                  .customSelect(
                    "SELECT COUNT(*) AS c FROM srs_cards_cache WHERE queue = 'review'",
                  )
                  .getSingle())
              .read<int>('c');
      print('review cards (RWKV candidates): $reviewCards');
      print('first nextCard (full score build): ${sw.elapsedMilliseconds} ms');
      final int thinkMs =
          int.tryParse(Platform.environment['FUSHI_SRS_RWKV_THINK_MS'] ?? '') ??
          0;
      final List<SrsReviewLog> logs = <SrsReviewLog>[];
      final List<int> answerMs = <int>[];
      for (int i = 0; i < 8; i++) {
        sw.reset();
        final SrsReviewLog log = await store.answer(pool[i], 3);
        final int tAnswer = sw.elapsedMilliseconds;
        await service.refresh();
        final int tAppend = sw.elapsedMilliseconds;
        await store.deckSummary(deck);
        final int tCounts = sw.elapsedMilliseconds;
        await store.nextCard(deck);
        answerMs.add(sw.elapsedMilliseconds);
        print(
          '  answer $tAnswer, +append ${tAppend - tAnswer}, '
          '+counts ${tCounts - tAppend}, +nextCard ${sw.elapsedMilliseconds - tCounts}',
        );
        logs.add(log);
        // 模拟看卡的工夫（FUSHI_SRS_RWKV_THINK_MS）：后台整表重查在这段时间里跑完。
        await Future<void>.delayed(Duration(milliseconds: thinkMs));
      }
      print('answer+counts+nextCard ms: $answerMs');
      final List<int> undoMs = <int>[];
      final List<bool> readyAfter = <bool>[];
      for (int i = logs.length - 1; i >= logs.length - 3; i--) {
        sw.reset();
        expect(await store.undo(logs[i].cardId, logs[i].id), isTrue);
        await store.deckSummary(deck);
        await store.nextCard(deck);
        final SrsAnswerPreview p = await store.preview(logs[i].cardId);
        undoMs.add(sw.elapsedMilliseconds);
        readyAfter.add(p.algorithm == SrsAlgorithm.rwkv && service.ready);
      }
      print('undo+counts+nextCard ms: $undoMs; rwkv ready after: $readyAfter');
      await service.close();
    },
    skip: notes == null ? 'set FUSHI_SRS_RWKV_BENCH=<notes>' : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
