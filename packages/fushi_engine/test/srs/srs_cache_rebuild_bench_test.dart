// 卡片缓存物化（复习日志 → 排程状态）的端到端墙钟耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_CACHE_BENCH=<笔记数> [FUSHI_SRS_CACHE_BENCH_REVS=<每卡日志数，默认 10>] \
//   dart test test/srs/srs_cache_rebuild_bench_test.dart
//
// 库开在临时文件上、走 createInBackground（与 app 同一种连接：语句经后台 isolate 往返）。
// 计的是调用方看到的整段耗时（读库 + 跨 isolate 搬运 + FFI + 写缓存），不只量内核。
// 设计与验收口径见 docs/specs/2026-10-23-srs-rust-core.md「第一阶段」。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
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

/// [notes] 条 Basic (and reversed) 笔记，每张卡 [revs] 条 revlog。
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
                        ease: 3,
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_CACHE_BENCH'];

  test(
    '卡片缓存物化耗时',
    () async {
      final int notes = int.parse(n!);
      final int revs = int.parse(
        Platform.environment['FUSHI_SRS_CACHE_BENCH_REVS'] ?? '10',
      );
      final Directory tmp = Directory.systemTemp.createTempSync('srs_cache_');
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.createInBackground(File('${tmp.path}/b.db')),
      );
      addTearDown(() async {
        await db.close();
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        profileUid: '01928c3e-0000-7000-8000-0000000be4c7',
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
      final List<String> cards = <String>[
        for (final SrsCardCacheRow c in await store.allCardRows()) c.id,
      ];
      final Stopwatch sw = Stopwatch();
      Future<int> timed(Future<void> Function() body) async {
        sw
          ..reset()
          ..start();
        await body();
        return sw.elapsedMilliseconds;
      }

      for (int round = 0; round < 3; round++) {
        final int rebuild = await timed(store.rebuildCaches);
        final int hist = await timed(() => store.histories(cards));
        // 单卡交互：改一张卡的旗标 = 一次事件落库 + 一次单卡缓存刷新。
        final int flag = await timed(
          () => store.setFlag(cards[round], round + 1),
        );
        // ignore: avoid_print
        print(
          'BENCH round=$round notes=$notes cards=${cards.length} '
          'revs/card=$revs rebuildCaches=${rebuild}ms '
          'histories(all)=${hist}ms setFlag(1 card)=${flag}ms',
        );
      }
    },
    skip: n == null ? 'set FUSHI_SRS_CACHE_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
