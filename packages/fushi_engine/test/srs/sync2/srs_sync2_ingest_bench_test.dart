// 收段端到端测量（默认跳过）。分两个进程跑，峰值 RSS 才只算收段那一侧：
//   1. `FUSHI_SRS_INGEST_BENCH=<笔记数> FUSHI_SRS_INGEST_BENCH_DIR=<空目录>`：设备 A 写一批带长字段的笔记、发段，
//      位置上的文件落进目录；
//   2. 同样的环境变量再跑一次（目录已有文件）：新设备 B 一轮同步收下全部段，量这一轮的墙钟耗时（含 FFI、跨
//      isolate 拷贝、缓存刷新）与进程峰值 RSS 相对开库后的增量。Windows 上另报峰值私有提交（`PeakPagedMemorySize64`）：
//      峰值 RSS（工作集）把 SQLite mmap 进来的库文件页也算进去（srs.db 开 256 MiB mmap），那部分是可回收的
//      文件页；私有提交才是收段真正占住的堆。同一轮里另起一路循环作答 B 自己的一张卡，报每次作答的等待时间
//      （收段的解码 / 验签在写锁外时，作答只等锁内的投递）。
// `FUSHI_SRS_INGEST_BENCH_FRESH=1`：B 是新装的设备（开库后什么都没写，只有内置身份记录）——第一次同步走新设备
// 收段通道（BUG-4478），输出里的 `channel=` 是内核有没有把这一轮放上通道。缺省 B 先建一条自己的笔记并在收段期间
// 循环作答（有自己数据的设备，逐条投递）。
// 收段那一轮另打三行 `INGEST_TRACE`：一轮各步骤的起始时刻（[srsSync2Round] 的 `onStep`）、[SrsSync2Host] 各入口的
// 次数 / 用时、内核命令账本（[SrsOpLedger]，每条 `core:<op>` 的次数 / 总用时 / 最长一次 / 交回字节）与位置读写的次数 /
// 字节。内核命令的用时是从 UI isolate 发出到拿回结果（含排队、跨 isolate 往返、编解码）；「一轮墙钟 − 各入口用时」
// 是这一轮在 Dart 侧自己花掉的。
// 只用来出 PR 里的前后对比数字。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

/// 收哪个 profile：缺省是本文件自己造数据用的那个；`FUSHI_SRS_INGEST_BENCH_PROFILE` 换成别处造好的数据的 profile
/// （例如内核 `ingest_mem_bench.rs` 用 `SRS_BENCH_OUT` 落盘的「每卡若干次复习」合成数据，目录 `<out>/<profile>/v3`）。
final String kProfile =
    Platform.environment['FUSHI_SRS_INGEST_BENCH_PROFILE'] ??
    '01928c3e-0000-7000-8000-0000000000ef';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final int notes =
      int.tryParse(Platform.environment['FUSHI_SRS_INGEST_BENCH'] ?? '') ?? 0;
  final String dirPath =
      Platform.environment['FUSHI_SRS_INGEST_BENCH_DIR'] ?? '';
  // 两次作答之间隔多久（毫秒，默认 20 = 持续抢锁的压力；0 = 收段期间不作答，量没人等锁时的墙钟）。
  final int answerGapMs =
      int.tryParse(
        Platform.environment['FUSHI_SRS_INGEST_BENCH_ANSWER_MS'] ?? '',
      ) ??
      20;
  final bool fresh =
      Platform.environment['FUSHI_SRS_INGEST_BENCH_FRESH'] == '1';

  test(
    'ingest bench',
    () async {
      Future<SrsDbStore> device(String id) async {
        final SrsStorage st = await openTestSrsStorage();
        return SrsDbStore.open(
          db: st.db,
          core: st.core,
          profileUid: kProfile,
          deviceId: id,
          engine: FfiFsrsEngine.tryCreate(),
        );
      }

      Future<SrsSync2Report> round(
        SrsSync2Host s,
        SrsLocationStore loc, {
        SrsSyncStepCallback? onStep,
      }) => srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        onStep: onStep,
      );

      final _TracedLocation loc = _TracedLocation();
      final Directory dir = Directory(dirPath)..createSync(recursive: true);
      final List<File> saved = <File>[
        for (final FileSystemEntity f in dir.listSync(recursive: true))
          if (f is File) f,
      ];
      if (saved.isNotEmpty) {
        for (final File f in saved) {
          final String rel = f.path
              .substring(dir.path.length + 1)
              .replaceAll(Platform.pathSeparator, '/');
          loc.files[rel] = f.readAsBytesSync();
        }
        final SrsDbStore b = await device('B');
        String? card;
        if (!fresh) {
          final String own = await b.createNote(
            noteTypeId: b.lapisNoteTypeId,
            fieldsById: <String, String>{
              srsLapisFieldId(kProfile, 'Expression'): '自分',
            },
          );
          card = (await b.cardsOfNote(own)).single.id;
          await b.answer(card, 3);
        }
        bool channel = false;
        b.debugOnIngestSlice = () => channel = channel || b.debugChannelLive;
        final int priv0 = _peakPrivateBytes();
        final int rss0 = ProcessInfo.maxRss;
        final Stopwatch sw = Stopwatch()..start();
        bool ingesting = true;
        final List<int> waits = <int>[];
        final Future<void> answering = () async {
          final String? mine = card;
          while (ingesting && answerGapMs > 0 && mine != null) {
            final Stopwatch one = Stopwatch()..start();
            await b.answer(mine, 3);
            waits.add(one.elapsedMilliseconds);
            await Future<void>.delayed(Duration(milliseconds: answerGapMs));
          }
        }();
        final _TracedHost traced = _TracedHost(b);
        final List<String> steps = <String>[];
        final Map<String, ({int count, int totalUs, int maxUs, int bytes})>
        before = SrsOpLedger.debugWindow();
        loc.reset();
        final SrsSync2Report r = await round(
          traced,
          loc,
          onStep: (String step) => steps.add(
            '${step.replaceAll(' ', '_')}@${sw.elapsedMilliseconds}',
          ),
        );
        sw.stop();
        final Map<String, ({int count, int totalUs, int maxUs, int bytes})>
        after = SrsOpLedger.debugWindow();
        ingesting = false;
        await answering;
        waits.sort();
        final int rss1 = ProcessInfo.maxRss;
        final int priv1 = _peakPrivateBytes();
        expect(r.error, isNull);
        expect(r.applied, greaterThan(0));
        // ignore: avoid_print
        print(
          'INGEST_BENCH notes=$notes fresh=$fresh channel=$channel '
          'applied=${r.applied} '
          'ms=${sw.elapsedMilliseconds} '
          'maxRssBeforeMiB=${rss0 >> 20} maxRssAfterMiB=${rss1 >> 20} '
          'peakDeltaMiB=${(rss1 - rss0) >> 20} '
          'peakPrivateDeltaMiB=${priv0 < 0 ? 'n/a' : (priv1 - priv0) >> 20} '
          'answers=${waits.length} '
          'answerP50Ms=${waits.isEmpty ? 0 : waits[waits.length ~/ 2]} '
          'answerP90Ms=${waits.isEmpty ? 0 : waits[waits.length * 9 ~/ 10]} '
          'answerMaxMs=${waits.isEmpty ? 0 : waits.last}',
        );
        // ignore: avoid_print
        print(
          'INGEST_TRACE steps ${steps.join(' ')} end@${sw.elapsedMilliseconds}',
        );
        // ignore: avoid_print
        print(
          'INGEST_TRACE host ${traced.summary()} | location ${loc.summary()}',
        );
        final List<String> core = <String>[
          for (final MapEntry<
                String,
                ({int count, int totalUs, int maxUs, int bytes})
              >
              e
              in after.entries)
            if (e.value.count > (before[e.key]?.count ?? 0))
              '${e.key} ${e.value.count - (before[e.key]?.count ?? 0)}x '
                  '${((e.value.totalUs - (before[e.key]?.totalUs ?? 0)) / 1000).round()}ms '
                  'max=${(e.value.maxUs / 1000).round()}ms '
                  'out=${(e.value.bytes - (before[e.key]?.bytes ?? 0)) >> 10}KiB',
        ];
        // ignore: avoid_print
        print('INGEST_TRACE core ${core.join('; ')}');
        return;
      }
      final SrsDbStore a = await device('A');
      final String filler = List<String>.filled(400, '日本語の例文。').join();
      final List<SrsEventDraft> drafts = <SrsEventDraft>[];
      for (int i = 0; i < notes; i++) {
        drafts.addAll(
          a.newNoteDrafts(
            noteTypeId: a.lapisNoteTypeId,
            guid: 'bench-$i',
            fieldsById: <String, String>{
              srsLapisFieldId(kProfile, 'Expression'): '語$i',
              srsLapisFieldId(kProfile, 'Sentence'): '$filler$i',
            },
          ),
        );
      }
      await a.importDrafts(drafts);
      final SrsSync2Report up = await round(a, loc);
      expect(up.error, isNull);

      for (final MapEntry<String, Uint8List> f in loc.files.entries) {
        File('${dir.path}/${f.key}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(f.value);
      }
      // ignore: avoid_print
      print('INGEST_BENCH seeded ${loc.files.length} files');
    },
    skip: notes <= 0 || dirPath.isEmpty
        ? 'set FUSHI_SRS_INGEST_BENCH=<notes> and FUSHI_SRS_INGEST_BENCH_DIR to run'
        : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// 位置读写的次数 / 用时 / 字节（内存位置本身几乎不花时间：这里量的是基准装置里「位置」这一项的下限）。
final class _TracedLocation extends SrsMemoryLocationStore {
  final Stopwatch _clock = Stopwatch()..start();
  int lists = 0;
  int gets = 0;
  int puts = 0;
  int getBytes = 0;
  int putBytes = 0;
  int us = 0;

  void reset() {
    lists = gets = puts = getBytes = putBytes = us = 0;
  }

  String summary() =>
      'list=${lists}x get=${gets}x/${getBytes >> 10}KiB '
      'put=${puts}x/${putBytes >> 10}KiB ${(us / 1000).round()}ms';

  @override
  Future<List<SrsLocationEntry>> list(String dir) async {
    final int t = _clock.elapsedMicroseconds;
    lists++;
    final List<SrsLocationEntry> r = await super.list(dir);
    us += _clock.elapsedMicroseconds - t;
    return r;
  }

  @override
  Future<Uint8List?> get(String path) async {
    final int t = _clock.elapsedMicroseconds;
    gets++;
    final Uint8List? r = await super.get(path);
    getBytes += r?.length ?? 0;
    us += _clock.elapsedMicroseconds - t;
    return r;
  }

  @override
  Future<void> put(String path, Uint8List bytes) async {
    final int t = _clock.elapsedMicroseconds;
    puts++;
    putBytes += bytes.length;
    await super.put(path, bytes);
    us += _clock.elapsedMicroseconds - t;
  }
}

/// [SrsSync2Host] 各入口的次数 / 用时（`sync2Command` 按 `op` 分）。
final class _TracedHost implements SrsSync2Host {
  _TracedHost(this._inner);

  final SrsDbStore _inner;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, (int, int)> _stats = <String, (int, int)>{};

  String summary() => <String>[
    for (final MapEntry<String, (int, int)> e in _stats.entries)
      '${e.key} ${e.value.$1}x ${(e.value.$2 / 1000).round()}ms',
  ].join('; ');

  Future<T> _timed<T>(String name, Future<T> Function() body) async {
    final int t = _clock.elapsedMicroseconds;
    try {
      return await body();
    } finally {
      final (int n, int us) = _stats[name] ?? (0, 0);
      _stats[name] = (n + 1, us + _clock.elapsedMicroseconds - t);
    }
  }

  @override
  String get profileUid => _inner.profileUid;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => _timed(
    'cmd:${request['op']}',
    () => _inner.sync2Command(request, blobs: blobs),
  );

  @override
  Future<void> sync2IngestBegin() =>
      _timed('ingestBegin', _inner.sync2IngestBegin);

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) => _timed(
    'ingestBatch',
    () => _inner.sync2IngestBatch(segments, keyHex: keyHex),
  );

  @override
  Future<Map<String, Object?>> sync2IngestFinish() =>
      _timed('ingestFinish', _inner.sync2IngestFinish);

  @override
  Future<void> sync2IngestEnd() => _timed('ingestEnd', _inner.sync2IngestEnd);
}

/// 本进程的峰值私有提交（字节；非 Windows 为 -1）。
int _peakPrivateBytes() {
  if (!Platform.isWindows) return -1;
  final ProcessResult r = Process.runSync('powershell', <String>[
    '-NoProfile',
    '-Command',
    '(Get-Process -Id $pid).PeakPagedMemorySize64',
  ]);
  return int.tryParse((r.stdout as String).trim()) ?? -1;
}
