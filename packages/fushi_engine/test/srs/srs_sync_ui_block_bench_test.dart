// 同步 / 媒体引用在大库上对调用 isolate 的单段阻塞（手动跑；默认跳过）。
//
// FUSHI_SRS_SYNC_BLOCK_BENCH=<笔记数> flutter test test/srs/srs_sync_ui_block_bench_test.dart
//
// 反馈 OMWOurRQKb：导入约 1.2 万张卡后复习模块开着整个 app 主线程卡死（看门狗 ≥10 s）。
// 「单段阻塞」= 调用 isolate 上最长一次不让出事件循环的时长（1 ms 周期计时器两次触发的最大间隔），
// UI 卡不卡看的是它，不是总耗时。库开在临时文件上、走 createInBackground（与 app 同一种连接）。
// 每条笔记两张卡、每卡 3 条日志，第二个字段是约 1.5 KB 的释义 HTML（带图片与音频引用）。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
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
import 'support/srs_event_loop_probe.dart';

Uint8List syncBenchApkg(int notes) {
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
            guid: 'syncb-$i',
            mid: kBasic,
            fields: <String>[
              '語$i<img src="pic$i.png">',
              '$gloss<p>例文その$i。</p>[sound:snd$i.mp3]',
            ],
            tags: <String>['bench'],
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
      ],
    ),
    'media': '{}'.codeUnits,
  });
}

/// 大库：临时文件 + 后台 isolate 连接（与 app 相同），导入 [notes] 条笔记。
Future<SrsDbStore> openSyncBenchStore(int notes, {int Function()? now}) async {
  final Directory tmp = Directory.systemTemp.createTempSync('srs_syncb_');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });
  final TestSrs srs = await openTestSrsAt('${tmp.path}/b.db', inline: false);
  final SrsDbStore store = await SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: '01928c3e-0000-7000-8000-0000000b10c4',
    deviceId: 'bench',
    engine: const FakeFsrsEngine(),
    trustedClock: now == null
        ? null
        : SrsTrustedClock(wallClockMs: now, monotonicMs: now, bootId: 'bench'),
    fallbackRolloverHour: () => 4,
  );
  await importAnkiPackage(
    store: store,
    bytes: syncBenchApkg(notes),
    storeMedia: (String name, Uint8List b) async => name,
    options: kFullOptions,
    zstdDecompress: (Uint8List b) => null,
  );
  return store;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_SYNC_BLOCK_BENCH'];

  test(
    '同步 / 快照 / 媒体引用的单段阻塞',
    () async {
      final int notes = int.parse(n!);
      int t = DateTime.utc(2026, 10, 23, 12).millisecondsSinceEpoch;
      final SrsDbStore store = await openSyncBenchStore(notes, now: () => t);
      final MemoryDir dir = MemoryDir(() => t);
      final List<String> lines = <String>[];
      Future<T> step<T>(String label, Future<T> Function() run) async {
        final (T v, EventLoopBlock b) = await measureEventLoopBlock(run);
        lines.add('$label: $b');
        return v;
      }

      final ({int notes, int cards, int reviews}) c = await store
          .backupCounts();
      lines.add('notes=${c.notes} cards=${c.cards} reviews=${c.reviews}');

      final List<SrsEvent> pending = await step(
        'unpublishedEvents',
        store.unpublishedEvents,
      );
      lines.add('  pending=${pending.length}');
      final List<SrsEvent> all = await step('exportAll', store.exportAll);
      final Map<String, int> times = await step(
        'exportServerTimes',
        store.exportServerTimes,
      );
      final Uint8List bytes = await step(
        'SrsSnapshot.encode',
        () async => SrsSnapshot(
          writerId: 'w',
          maxOwnBatch: 1,
          vv: const <String, int>{'w': 1},
          serverTimes: times,
          events: all,
        ).encode(),
      );
      lines.add('  snapshotBytes=${bytes.length}');
      await step('SrsSnapshot.decode', () async => SrsSnapshot.decode(bytes));
      await step('allNoteViews', store.allNoteViews);

      await step('srsReferencedMedia', () => srsReferencedMedia(store));
      await step('srsAllMediaReferences', () => srsAllMediaReferences(store));
      await step(
        'syncOnce#1 (freeze+upload)',
        () => SrsSyncEngine(
          directoryKey: 'bench',
          directory: dir,
          replica: store,
        ).syncOnce(),
      );
      t += 1000;
      final SrsSyncReport r2 = await step(
        'syncOnce#2 (snapshot)',
        () => SrsSyncEngine(
          directoryKey: 'bench',
          directory: dir,
          replica: store,
          options: const SrsSyncOptions(snapshotEveryBatches: 1),
        ).syncOnce(),
      );
      lines.add('  snapshotWritten=${r2.snapshotWritten}');
      await step('allNoteViews (after sync)', store.allNoteViews);
      await step(
        'srsReferencedMedia (after sync)',
        () => srsReferencedMedia(store),
      );
      t += 1000;
      await step(
        'syncOnce#3 (idle)',
        () => SrsSyncEngine(
          directoryKey: 'bench',
          directory: dir,
          replica: store,
        ).syncOnce(),
      );
      // ignore: avoid_print
      print('BENCH notes=$notes\n  ${lines.join('\n  ')}');
    },
    skip: n == null ? 'set FUSHI_SRS_SYNC_BLOCK_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
