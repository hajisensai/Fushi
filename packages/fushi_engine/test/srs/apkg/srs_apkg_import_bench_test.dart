// Anki 包导入在较大规模上的耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_IMPORT_BENCH=<笔记数> dart test test/srs/apkg/srs_apkg_import_bench_test.dart
//
// 库开在临时文件上、走 createInBackground（与 app 同一种连接：语句经后台 isolate 往返）。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';

import '../support/srs_query_counter.dart';
import 'apkg_test_support.dart';
import '../support/srs_test_storage.dart';
import 'srs_apkg_import_test.dart'
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

/// [notes] 条 Basic (and reversed) 笔记：两张卡分在两个牌组，每张卡 3 条 revlog。
Uint8List benchApkg(int notes) {
  final int base = ms(2025, 1, 1);
  final List<FxNote> list = <FxNote>[
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
              reps: 3,
              revlog: <FxRevlog>[
                for (int k = 0; k < 3; k++)
                  FxRevlog(
                    base + i * 1000 + ord * 100 + k * 10 + 86400000 * k,
                    type: k == 0 ? 0 : 1,
                    ease: 3,
                    ivl: k == 0 ? -600 : 3 * k,
                  ),
              ],
            ),
        ],
      ),
  ];
  return zipOf(<String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: crtSecs,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
      models: legacyModels(),
      decks: legacyDecks(),
      dconf: legacyDconf(),
      notes: list,
    ),
    'media': '{"0":"a.png","1":"_font.woff"}'.codeUnits,
    '0': <int>[1, 2, 3],
    '1': <int>[4, 5],
  });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_IMPORT_BENCH'];

  test(
    '导入耗时',
    () async {
      final int notes = int.parse(n!);
      final CountingInterceptor counter = CountingInterceptor();
      final Uint8List bytes = benchApkg(notes);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_bench_');
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        interceptor: counter,
        inline: false,
      );
      addTearDown(() async {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      const String uid = '01928c3e-0000-7000-8000-0000000be4c5';
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      final Stopwatch sw = Stopwatch()..start();
      final SrsImportReport r = await importAnkiPackage(
        store: store,
        bytes: bytes,
        storeMedia: (String name, Uint8List b) async => name,
        options: kFullOptions,
        zstdDecompress: (Uint8List b) => null,
      );
      final int importMs = sw.elapsedMilliseconds;
      final String stmts = counter.summary();
      sw.reset();
      final List<SrsDeckSummary> decks = await store.deckSummaries();
      final int summariesMs = sw.elapsedMilliseconds;
      sw.reset();
      final int conflicts = (await store.syncConflicts()).length;
      final int conflictsMs = sw.elapsedMilliseconds;
      sw.reset();
      await store.createDeck('New');
      final int createMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BENCH notes=$notes added=${r.notesAdded} cards=${r.cardsAdded} '
        'logs=${r.reviewLogsImported} import=${importMs}ms '
        'deckSummaries=${summariesMs}ms(${decks.length}) '
        'syncConflicts=${conflictsMs}ms($conflicts) createDeck=${createMs}ms '
        'import statements: $stmts',
      );
    },
    skip: n == null ? 'set FUSHI_SRS_IMPORT_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
