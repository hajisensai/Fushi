// P6（统计 / 优化器训练集 / RWKV 全量回放的取数收编进 Rust）的端到端墙钟耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_P6_BENCH=<笔记数> [FUSHI_SRS_P6_BENCH_REVS=<每卡日志数，默认 10>] \
//   dart test test/srs/srs_p6_projection_bench_test.dart
//
// 库开在临时文件上、Drift 走后台 isolate（与 app 同一种连接）。计的是调用方看到的整段耗时：
// - 优化器：每个参数归属牌组一次 `srsPrepareOptimization`，再把训练集送进后台 isolate 数一遍条目
//   （生产里 `SrsIsolateOptimizationJob` 就是这样把输入交给拟合的，跨 isolate 的拷贝算在内）；
// - RWKV：`SrsRwkvService.rebuild()` 一次全量回放（后端是只收行的替身，不跑模型）；
// - 统计页：`loadSrsStats` 一次。
// 设计与口径见 docs/specs/2026-10-23-srs-rust-store.md §7。
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_optimizer.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';
import 'apkg/srs_apkg_import_test.dart'
    show
        crtSecs,
        kBasic,
        kDeckJp,
        kDeckLang,
        kFullOptions,
        legacyDconf,
        legacyDecks,
        legacyModels,
        ms;

/// [notes] 条 Basic (and reversed) 笔记，每张卡 [revs] 条 revlog（第一条学习、之后复习）。
Uint8List _apkg(int notes, int revs) {
  final int base = ms(2025, 1, 1);
  return zipOf(<String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: crtSecs,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
      models: legacyModels(),
      decks: legacyDecks(),
      dconf: legacyDconf(),
      notes: <FxNote>[
        for (int i = 0; i < notes; i++)
          FxNote(
            id: base + i,
            guid: 'bench-$i',
            mid: kBasic,
            fields: <String>['語$i', '例文その$i。' * 4],
            tags: <String>['bench'],
            cards: <FxCard>[
              for (int ord = 0; ord < 2; ord++)
                FxCard(
                  id: (base + i) * 2 + ord,
                  ord: ord,
                  did: ord == 0 ? kDeckJp : kDeckLang,
                  type: 2,
                  queue: 2,
                  due: 30,
                  ivl: 10,
                  factor: 2500,
                  reps: revs,
                  revlog: <FxRevlog>[
                    for (int k = 0; k < revs; k++)
                      FxRevlog(
                        base + i * 1000 + ord * 100 + k + 86400000 * k,
                        type: k == 0 ? 0 : 1,
                        ease: k % 7 == 3 ? 1 : 3,
                        ivl: k == 0 ? -600 : 3 * k,
                      ),
                  ],
                ),
            ],
          ),
      ],
    ),
  });
}

/// 把训练集送进后台 isolate 数一遍（闭包只捕获输入本身）。
Future<int> _itemsInIsolate(SrsOptimizationInput input) =>
    Isolate.run<int>(() => input.items.length);

/// 只收行、不跑模型的后端。
class _CountingBackend implements SrsRwkvBackend {
  int rows = 0;

  @override
  Future<void> replay(RwkvRows r) async => rows += r.length;

  @override
  Future<bool> append(RwkvRows r, List<int> tags, List<int> ats) async {
    rows += r.length;
    return true;
  }

  @override
  Future<int?> rewindFrom(int atMs, int floorMs) async => null;

  @override
  Future<bool> unappend(int tag) async => false;

  @override
  Future<Float32List> query(RwkvRows r) async => Float32List(r.length);

  @override
  Future<void> clearScores() async {}

  @override
  Future<RwkvScoreLookup> lookupScores(
    Int64List cardIds,
    Uint64List versions,
  ) async => RwkvScoreLookup(
    Float32List(cardIds.length)..fillRange(0, cardIds.length, double.nan),
    Uint8List(cardIds.length),
  );

  @override
  Future<Float32List> updateScores(
    RwkvRows r,
    Uint64List versions,
    Int64List anchorsMs,
  ) async => Float32List(r.length);

  @override
  Future<int> requeryScores(int today, int nowMs) async => 0;

  @override
  Future<int> removeScores(Int64List cardIds) async => 0;

  @override
  Future<Uint8List> snapshot() async => Uint8List(0);

  @override
  Future<void> restore(Uint8List snapshot) async {}

  @override
  Future<void> reset() async => rows = 0;

  @override
  Future<void> close() async {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_P6_BENCH'];

  test(
    'P6 取数端到端耗时',
    () async {
      final int notes = int.parse(n!);
      final int revs = int.parse(
        Platform.environment['FUSHI_SRS_P6_BENCH_REVS'] ?? '10',
      );
      final Directory tmp = Directory.systemTemp.createTempSync('srs_p6_');
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        inline: false,
      );
      addTearDown(() async {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: '01928c3e-0000-7000-8000-0000000be4c8',
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      await importAnkiPackage(
        store: store,
        bytes: _apkg(notes, revs),
        storeMedia: (String name, Uint8List b) async => name,
        options: kFullOptions,
        zstdDecompress: (Uint8List b) => null,
      );
      final SrsDeckTree tree = await store.deckTree();
      final List<String> owners = <String>[
        for (final SrsDeckView d in tree.decks)
          if (tree.paramsOwner(d.id).id == d.id) d.id,
      ];
      final Directory modelDir = Directory('${tmp.path}/models')..createSync();
      final SrsRwkvModels models = SrsRwkvModels(
        dir: modelDir,
        createClient: () => throw const SocketException('offline'),
      );
      final File weights = models.weightsFile
        ..writeAsBytesSync(Uint8List(kSrsRwkvSmallWeightsBytes));
      File(
        '${weights.path}.verified',
      ).writeAsStringSync(kSrsRwkvSmallWeightsSha256);
      final _CountingBackend backend = _CountingBackend();
      final SrsRwkvService rwkv = SrsRwkvService(
        store: store,
        models: models,
        snapshotDir: Directory('${tmp.path}/state'),
        openBackend: (File w) async => backend,
      );
      await rwkv.start();
      addTearDown(rwkv.close);

      final Stopwatch sw = Stopwatch();
      Future<int> timed(Future<void> Function() body) async {
        sw
          ..reset()
          ..start();
        await body();
        return sw.elapsedMilliseconds;
      }

      for (int round = 0; round < 3; round++) {
        int items = 0;
        final int optimize = await timed(() async {
          for (final String deckId in owners) {
            final SrsOptimizationInput? input = await srsPrepareOptimization(
              store,
              deckId,
            );
            if (input == null) continue;
            items += await _itemsInIsolate(input);
          }
        });
        final int replay = await timed(rwkv.rebuild);
        int reviews = 0;
        final int stats = await timed(() async {
          reviews = (await loadSrsStats(store)).data.reviews.length;
        });
        // ignore: avoid_print
        print(
          'BENCH round=$round notes=$notes revs/card=$revs '
          'prepareOptimization+isolate=${optimize}ms (items=$items) '
          'rwkvRebuild=${replay}ms (rows=${backend.rows}) '
          'loadSrsStats=${stats}ms (reviews=$reviews)',
        );
      }
    },
    skip: n == null ? 'set FUSHI_SRS_P6_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
