// 浏览快照在较大规模上的装载耗时与内存（手动跑；默认跳过）。
//
// FUSHI_SRS_BROWSE_BENCH=<笔记数> dart test test/srs/srs_browse_bench_test.dart
//
// 库开在临时文件上、走 createInBackground（与 app 同一种连接）。每条笔记两张卡，第二个字段是
// 约 1.5 KB 的释义 HTML（接近真实挖词卡的体量）。RSS 含后台 drift isolate，只看差值。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
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
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

Uint8List _apkg(int notes) {
  final int base = ms(2025, 1, 1);
  final String gloss =
      '<div class="gloss"><ol>${'<li><span class="pos">名</span>意味の説明 meaning text</li>' * 24}</ol></div>';
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
            guid: 'browse-$i',
            mid: kBasic,
            fields: <String>['語$i', '$gloss<p>例文その$i。</p>'],
            tags: <String>['bench', if (i.isEven) 'even'],
            cards: <FxCard>[
              for (int ord = 0; ord < 2; ord++)
                FxCard(
                  id: (base + i) * 2 + ord,
                  ord: ord,
                  did: ord == 0 ? kDeckJp : kDeckLang,
                  type: 2,
                  queue: 2,
                  due: 30 + i % 50,
                  ivl: 10,
                  factor: 2500,
                  reps: 3,
                  revlog: <FxRevlog>[
                    FxRevlog(
                      base + i * 1000 + ord * 100,
                      type: 0,
                      ease: 3,
                      ivl: -600,
                    ),
                  ],
                ),
            ],
          ),
      ],
    ),
    'media': '{}'.codeUnits,
  });
}

int _rssMb() => ProcessInfo.currentRss >> 20;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_BROWSE_BENCH'];

  test(
    '浏览快照装载 / 搜索 / 排序',
    () async {
      final int notes = int.parse(n!);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_browse_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/b.db',
        interceptor: CountingInterceptor(),
        inline: false,
      );
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: '01928c3e-0000-7000-8000-0000000be4c7',
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      await importAnkiPackage(
        store: store,
        bytes: _apkg(notes),
        storeMedia: (String name, Uint8List b) async => name,
        options: kFullOptions,
        zstdDecompress: (Uint8List b) => null,
      );
      final List<String> lines = <String>[];
      final int rss0 = _rssMb();
      final Stopwatch sw = Stopwatch()..start();
      final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(store);
      lines.add(
        'load=${sw.elapsedMilliseconds}ms cards=${snap.cards.length} '
        'rss+${_rssMb() - rss0}MB',
      );
      Future<void> step(String label, Future<int> Function() run) async {
        sw.reset();
        final int hits = await run();
        lines.add(
          '$label=${sw.elapsedMilliseconds}ms hits=$hits '
          'rss+${_rssMb() - rss0}MB',
        );
      }

      await step('query("")', () async => (await snap.query()).length);
      await step('query(tag:even is:due)', () async {
        await snap.prepare('tag:even is:due');
        return (await snap.query(query: 'tag:even is:due')).length;
      });
      await step('query(Back:*例文その12*)', () async {
        await snap.prepare('Back:*例文その12*');
        return (await snap.query(query: 'Back:*例文その12*')).length;
      });
      await step('query(例文その123)', () async {
        await snap.prepare('例文その123');
        return (await snap.query(query: '例文その123')).length;
      });
      await step('query(edited:1)', () async {
        await snap.prepare('edited:1');
        return (await snap.query(query: 'edited:1')).length;
      });
      await step(
        'sort(modified)',
        () async => (await snap.query(
          sort: const SrsBrowseSort(column: SrsBrowseSortColumn.modified),
        )).length,
      );
      await step(
        'sort(field Back)',
        () async => (await snap.query(
          sort: const SrsBrowseSort(
            column: SrsBrowseSortColumn.field,
            fieldName: 'Back',
          ),
        )).length,
      );
      snap.dispose();
      // ignore: avoid_print
      print('BENCH notes=$notes\n  ${lines.join('\n  ')}');
    },
    skip: n == null ? 'set FUSHI_SRS_BROWSE_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
