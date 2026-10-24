// Anki 包导出 / 重导入 / 新格式导入在大库上的峰值内存与耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_APKG_MEM_BENCH=<笔记数>[,<媒体数>] FUSHI_SRS_APKG_MEM_PHASE=<段> \
//   dart test test/srs/apkg/srs_apkg_memory_bench_test.dart
//
// 段：prepare（生成包、导入一份库、导出一份包，全部缓存在系统临时目录 srs_mem_bench/ 下）、
// import / export / reimport / anki21b / anki21b_big（集合多 300 MB 填充，只放大解 zstd）（各在**单独一个进程**里只量这一段）。一个进程里连着量
// 几段时，前一段留在堆上的垃圾会被后一段的分配直接复用，后一段的峰值就失真了（实测两边的
// 数字会互相污染）。新格式需要 FUSHI_FSRS_LIB 指向排程内核（或 prebuilt 在默认位置）。
//
// 峰值内存：另起一个 isolate 每 2 ms 采一次进程 RSS（主 isolate 跑同步大活时它照样采），
// 报「段内 RSS 峰值 − 段开始时 RSS」。库开在临时文件上、走 createInBackground。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/srs_query_counter.dart';
import '../support/srs_test_storage.dart';
import 'apkg_test_support.dart';
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

/// 每个媒体文件的大小（随机字节，不可压缩）。
const int _mediaBytes = 512 * 1024;

/// [notes] 条 Basic (and reversed) 笔记的集合 SQLite；前 [media] 条笔记各引用一个媒体。
Uint8List _collection(int notes, int media) {
  final int base = ms(2025, 1, 1);
  return buildLegacyCollection(
    crtSecs: crtSecs,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
    models: legacyModels(),
    decks: legacyDecks(),
    dconf: legacyDconf(),
    notes: <FxNote>[
      for (int i = 0; i < notes; i++)
        FxNote(
          id: base + i,
          guid: 'mem-$i',
          mid: kBasic,
          fields: <String>[
            '語$i',
            '例文その$i。' * 4 + (i < media ? '<img src="m$i.bin">' : ''),
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
    ],
  );
}

/// 把 [collection] 与 [media] 个随机媒体写成 .apkg 文件。
File _writePackage(
  Directory dir,
  String name,
  String collectionEntry,
  Uint8List collection,
  int media,
) {
  final Random rnd = Random(7);
  final Map<String, List<int>> entries = <String, List<int>>{
    collectionEntry: collection,
    'media':
        '{${<String>[for (int i = 0; i < media; i++) '"$i":"m$i.bin"'].join(',')}}'
            .codeUnits,
    for (int i = 0; i < media; i++)
      '$i': Uint8List.fromList(
        List<int>.generate(_mediaBytes, (_) => rnd.nextInt(256)),
      ),
  };
  final File f = File('${dir.path}/$name')..writeAsBytesSync(zipOf(entries));
  return f;
}

/// 另一个 isolate 里的 RSS 采样器。
class _RssSampler {
  _RssSampler._(this._isolate, this._commands, this._replies);

  final Isolate _isolate;
  final SendPort _commands;
  final StreamIterator<Object?> _replies;

  static Future<_RssSampler> start() async {
    final ReceivePort rp = ReceivePort();
    final Isolate iso = await Isolate.spawn(_run, rp.sendPort);
    final StreamIterator<Object?> it = StreamIterator<Object?>(rp);
    await it.moveNext();
    return _RssSampler._(iso, it.current! as SendPort, it);
  }

  static void _run(SendPort out) {
    final ReceivePort cmd = ReceivePort();
    out.send(cmd.sendPort);
    int peak = ProcessInfo.currentRss;
    final Timer t = Timer.periodic(const Duration(milliseconds: 2), (_) {
      peak = max(peak, ProcessInfo.currentRss);
    });
    cmd.listen((Object? m) {
      if (m == 'reset') {
        peak = ProcessInfo.currentRss;
        out.send(peak);
      } else if (m == 'peak') {
        out.send(max(peak, ProcessInfo.currentRss));
      } else {
        t.cancel();
        cmd.close();
      }
    });
  }

  Future<int> _ask(String what) async {
    _commands.send(what);
    await _replies.moveNext();
    return _replies.current! as int;
  }

  /// 量一段：返回 (耗时 ms, 段内 RSS 峰值增量 MB)。
  Future<(int, double)> measure(Future<void> Function() body) async {
    final int start = await _ask('reset');
    final Stopwatch sw = Stopwatch()..start();
    await body();
    final int ms = sw.elapsedMilliseconds;
    final int peak = await _ask('peak');
    return (ms, (peak - start) / (1024 * 1024));
  }

  Future<void> stop() async {
    _commands.send('stop');
    await _replies.cancel();
    _isolate.kill();
  }
}

Future<SrsDbStore> _openStore(
  Directory tmp,
  String name,
  CountingInterceptor? c,
) async {
  final TestSrs srs = await openTestSrsAt(
    '${tmp.path}/$name.db',
    interceptor: c,
    inline: false,
  );
  return SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: '01928c3e-0000-7000-8000-00000000e3e3',
    deviceId: 'bench',
    engine: const FakeFsrsEngine(),
    fallbackRolloverHour: () => 4,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? spec = Platform.environment['FUSHI_SRS_APKG_MEM_BENCH'];
  final String phase =
      Platform.environment['FUSHI_SRS_APKG_MEM_PHASE'] ?? 'prepare';

  test(
    '导出 / 重导入 / 新格式导入的峰值内存与耗时',
    () async {
      final List<int> parts = spec!.split(',').map(int.parse).toList();
      final int notes = parts[0];
      final int media = parts.length > 1 ? parts[1] : 0;
      final Directory cache = Directory(
        '${Directory.systemTemp.path}/srs_mem_bench/${notes}_$media',
      );
      final File legacy = File('${cache.path}/legacy.apkg');
      final File latest = File('${cache.path}/latest.apkg');
      final File latestBig = File('${cache.path}/latest_big.apkg');
      final File exported = File('${cache.path}/exported.apkg');
      final File imported = File('${cache.path}/imported.db');
      final Directory tmp = Directory.systemTemp.createTempSync('srs_mem_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final Directory mediaDir = Directory('${tmp.path}/media')..createSync();
      final Directory storedMedia = Directory('${cache.path}/media');
      Future<String> storeMedia(String name, Uint8List b) async {
        File('${mediaDir.path}/$name').writeAsBytesSync(b);
        return name;
      }

      Future<Uint8List?> loadMedia(String name) async {
        final File f = File('${storedMedia.path}/$name');
        return f.existsSync() ? f.readAsBytesSync() : null;
      }

      if (phase == 'prepare') {
        cache.createSync(recursive: true);
        final Uint8List col = _collection(notes, media);
        _writePackage(cache, 'legacy.apkg', 'collection.anki21', col, media);
        _writePackage(
          cache,
          'latest.apkg',
          'collection.anki21b',
          zstdRawFrame(col),
          0,
        );
        // 大集合的新格式包：集合里多一张导入器不读的填充表（300 MB），只放大「解 zstd」这一步。
        _writePackage(
          cache,
          'latest_big.apkg',
          'collection.anki21b',
          zstdRawFrame(
            patchSqlite(col, (Database db) {
              db.execute('CREATE TABLE pad (b BLOB)');
              for (int i = 0; i < 300; i++) {
                db.execute('INSERT INTO pad VALUES (randomblob(1048576))');
              }
            }),
          ),
          0,
        );
        storedMedia.createSync();
        final SrsDbStore s = await _openStore(cache, 'imported', null);
        await importAnkiPackageFile(
          store: s,
          file: legacy,
          storeMedia: (String name, Uint8List b) async {
            File('${storedMedia.path}/$name').writeAsBytesSync(b);
            return name;
          },
          options: kFullOptions,
        );
        await exportAnkiPackageFile(
          store: s,
          file: exported,
          loadMedia: loadMedia,
        );
        // ignore: avoid_print
        print('MEMBENCH prepared ${cache.path}');
        return;
      }

      // 已导入的库每段各用一份拷贝（重导入会改它）。
      Future<SrsDbStore> copyOfImported(CountingInterceptor c) async {
        imported.copySync('${tmp.path}/a.db');
        return _openStore(tmp, 'a', c);
      }

      final CountingInterceptor counter = CountingInterceptor();
      final SrsDbStore store = switch (phase) {
        'import' ||
        'anki21b' ||
        'anki21b_big' => await _openStore(tmp, 'a', counter),
        _ => await copyOfImported(counter),
      };
      counter.reset();
      final _RssSampler rss = await _RssSampler.start();
      addTearDown(rss.stop);
      String extra = '';
      final (int ms, double mb) = await rss.measure(() async {
        switch (phase) {
          case 'import':
          case 'anki21b':
          case 'anki21b_big':
          case 'reimport':
            final SrsImportReport r = await importAnkiPackageFile(
              store: store,
              file: switch (phase) {
                'import' => legacy,
                'anki21b' => latest,
                'anki21b_big' => latestBig,
                _ => exported,
              },
              storeMedia: storeMedia,
              options: kFullOptions,
            );
            extra =
                'added=${r.notesAdded} updated=${r.notesUpdated} '
                'skipped=${r.notesSkipped}';
          case 'export':
            await exportAnkiPackageFile(
              store: store,
              file: File('${tmp.path}/out.apkg'),
              loadMedia: loadMedia,
            );
          default:
            fail('unknown phase $phase');
        }
      });
      // ignore: avoid_print
      print(
        'MEMBENCH notes=$notes media=$media $phase ${ms}ms '
        '+${mb.toStringAsFixed(1)}MB $extra statements: ${counter.summary()}',
      );
    },
    skip: spec == null ? 'set FUSHI_SRS_APKG_MEM_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}
