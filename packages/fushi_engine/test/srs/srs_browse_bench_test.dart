// 浏览页在较大规模上的耗时与内存（手动跑；默认跳过）。
//
// 合成库：FUSHI_SRS_BROWSE_BENCH=<笔记数> dart test test/srs/srs_browse_bench_test.dart
// 真库副本：FUSHI_SRS_BROWSE_BENCH_DB=<srs.db 副本> dart test test/srs/srs_browse_bench_test.dart
//   （会写一次旗标再改回去；别指向在用的库）
//
// 合成库开在临时文件上、走 createInBackground（与 app 同一种连接）。每条笔记两张卡，第二个字段是
// 约 1.5 KB 的释义 HTML（接近真实挖词卡的体量）。量的是浏览页的真实调用序列：打开（查询 + 取首屏
// 一页行）、改旗标后的刷新、预览返回（没写入）、搜索、排序。RSS 含后台 drift isolate 与原生会话；
// peak 是进程峰值。
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
  final String? dbPath = Platform.environment['FUSHI_SRS_BROWSE_BENCH_DB'];

  test(
    '浏览页：打开 / 改旗标刷新 / 预览返回 / 搜索 / 排序',
    () async {
      final SrsDbStore store;
      final List<String> searches;
      if (dbPath != null) {
        final TestSrs srs = await openTestSrsAt(dbPath, inline: false);
        final String profileUid =
            (await srs.db
                    .customSelect(
                      'SELECT profile_uid FROM srs_cards_cache LIMIT 1',
                    )
                    .getSingle())
                .read<String>('profile_uid');
        store = await SrsDbStore.open(
          db: srs.db,
          core: srs.core,
          profileUid: profileUid,
          deviceId: 'bench',
          engine: const FakeFsrsEngine(),
        );
        searches = <String>['is:due', 'の', 'tag:*', 'edited:7'];
      } else {
        final int notes = int.parse(n!);
        final Directory tmp = Directory.systemTemp.createTempSync(
          'srs_browse_',
        );
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
        store = await SrsDbStore.open(
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
        searches = <String>[
          'tag:even is:due',
          'Back:*例文その12*',
          '例文その123',
          'edited:1',
        ];
      }
      final List<String> fields = srsBrowseFieldNames(await store.noteTypes());
      final String sortField = fields.length > 1 ? fields[1] : fields.first;
      final List<String> lines = <String>[];
      final int rss0 = _rssMb();
      final Stopwatch sw = Stopwatch();
      Future<SrsBrowseResult> step(
        String label,
        Future<SrsBrowseResult> Function() run,
      ) async {
        sw
          ..reset()
          ..start();
        final SrsBrowseResult r = await run();
        // 浏览页每次重算都取首屏那一页。
        await r.ensure(0, kSrsBrowsePage);
        lines.add(
          '${label.padRight(28)} ${sw.elapsedMilliseconds.toString().padLeft(6)}ms '
          'hits=${r.length} rss+${_rssMb() - rss0}MB '
          'peak=${ProcessInfo.maxRss >> 20}MB',
        );
        return r;
      }

      final SrsBrowseSession session = SrsBrowseSession(store);
      final SrsBrowseResult opened = await step(
        'open (query "")',
        session.query,
      );
      await step('requery "" (no write)', session.query);
      await step('preview return (reuse)', () => session.query(reuse: true));
      final String card = (await opened.rows(0, 1)).single.cardId;
      final int flag0 = (await opened.rows(0, 1)).single.flag;
      await store.setFlag(card, flag0 == 3 ? 4 : 3);
      await step('flag change -> refresh', session.query);
      await store.setFlag(card, flag0);
      await step('flag back -> refresh', session.query);
      for (final String q in searches) {
        await step('search $q', () => session.query(query: q));
      }
      await step(
        'sort(modified)',
        () => session.query(
          sort: const SrsBrowseSort(column: SrsBrowseSortColumn.modified),
        ),
      );
      await step(
        'sort(field $sortField)',
        () => session.query(
          sort: SrsBrowseSort(
            column: SrsBrowseSortColumn.field,
            fieldName: sortField,
          ),
        ),
      );
      await step('notes mode', () => session.query(mode: SrsBrowseMode.notes));
      await session.close();
      // ignore: avoid_print
      print('BENCH ${dbPath ?? 'notes=$n'}\n  ${lines.join('\n  ')}');
    },
    skip: n == null && dbPath == null
        ? 'set FUSHI_SRS_BROWSE_BENCH or FUSHI_SRS_BROWSE_BENCH_DB'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
