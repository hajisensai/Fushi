// 同步 v2 拉段按字节分批（srs_sync2_round.dart [srsFetchInBatches] / [kSrsSync2IngestBudgetBytes]）：
// 段按压缩后体积切、单段可到 4 MiB，按段数分批会让一批大到几百 MB 再整批跨 FFI；按实际字节切批则一批的内存
// 有上界，进度按批推进、中途收手只丢在途那一批。
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

/// 路径 → 大小的假存储；记录读取顺序与同时在途数。
class _Sized {
  _Sized(this.sizes, {this.delay = Duration.zero});

  final Map<String, int?> sizes;
  final Duration delay;
  final List<String> fetched = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Future<Uint8List?> get(String path) async {
    fetched.add(path);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(delay);
      final int? n = sizes[path];
      return n == null ? null : Uint8List(n);
    } finally {
      inFlight--;
    }
  }
}

Future<List<SrsFetchedBatch>> _collect(Stream<SrsFetchedBatch> s) => s.toList();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('srsFetchInBatches', () {
    test('大段提前切批：累计字节到预算就交出这一批', () async {
      final _Sized st = _Sized(<String, int?>{
        'a': 1,
        'b': 1,
        'c': 10,
        'd': 1,
        'e': 1,
      });
      final List<SrsFetchedBatch> out = await _collect(
        srsFetchInBatches(
          <String>['a', 'b', 'c', 'd', 'e'],
          fetch: st.get,
          budgetBytes: 5,
          concurrency: 1,
        ),
      );
      expect(
        <int>[for (final SrsFetchedBatch b in out) b.covered],
        <int>[3, 2],
      );
      expect(
        <List<int>>[
          for (final SrsFetchedBatch b in out)
            <int>[for (final Uint8List x in b.segments) x.length],
        ],
        <List<int>>[
          <int>[1, 1, 10],
          <int>[1, 1],
        ],
      );
    });

    test('单个超过预算的段自成一批（每批至少一个，不会卡死）', () async {
      final _Sized st = _Sized(<String, int?>{'a': 10, 'b': 10, 'c': 10});
      final List<SrsFetchedBatch> out = await _collect(
        srsFetchInBatches(
          <String>['a', 'b', 'c'],
          fetch: st.get,
          budgetBytes: 5,
          concurrency: 1,
        ),
      );
      expect(
        <int>[for (final SrsFetchedBatch b in out) b.covered],
        <int>[1, 1, 1],
      );
    });

    test('并发时：同时在途不超过上限，一批的字节小于 预算 + 并发 × 单段', () async {
      const int seg = 4;
      const int budget = 9;
      const int conc = 3;
      final List<String> paths = <String>[for (int i = 0; i < 40; i++) 'p$i'];
      final _Sized st = _Sized(<String, int?>{
        for (final String p in paths) p: seg,
      }, delay: const Duration(milliseconds: 1));
      final List<SrsFetchedBatch> out = await _collect(
        srsFetchInBatches(
          paths,
          fetch: st.get,
          budgetBytes: budget,
          concurrency: conc,
        ),
      );
      expect(st.maxInFlight, lessThanOrEqualTo(conc));
      expect(out.length, greaterThan(1));
      for (final SrsFetchedBatch b in out) {
        final int bytes = b.segments.fold(
          0,
          (int s, Uint8List x) => s + x.length,
        );
        expect(bytes, lessThan(budget + conc * seg));
      }
      // 原顺序、一个不漏。
      expect(st.fetched.toSet(), paths.toSet());
      expect(
        <int>[
          for (final SrsFetchedBatch b in out) b.covered,
        ].fold(0, (int s, int x) => s + x),
        paths.length,
      );
    });

    test('消费方处理一批时不再下载（同一时刻内存里只有一批）', () async {
      final List<String> paths = <String>[for (int i = 0; i < 12; i++) 'p$i'];
      final _Sized st = _Sized(<String, int?>{
        for (final String p in paths) p: 4,
      });
      int seen = 0;
      await for (final SrsFetchedBatch b in srsFetchInBatches(
        paths,
        fetch: st.get,
        budgetBytes: 8,
        concurrency: 2,
      )) {
        seen += b.covered;
        final int before = st.fetched.length;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(
          st.fetched.length,
          before,
          reason: 'no prefetch while ingesting',
        );
        expect(st.fetched.length, seen);
      }
      expect(seen, paths.length);
    });

    test('pinned：前若干个无视预算全进第一批', () async {
      final _Sized st = _Sized(<String, int?>{
        'o1': 10,
        'o2': 10,
        'o3': 10,
        'x': 1,
        'y': 1,
      });
      final List<SrsFetchedBatch> out = await _collect(
        srsFetchInBatches(
          <String>['o1', 'o2', 'o3', 'x', 'y'],
          fetch: st.get,
          budgetBytes: 5,
          concurrency: 2,
          pinned: 3,
        ),
      );
      expect(out.first.covered, greaterThanOrEqualTo(3));
      expect(out.first.segments.take(3).map((Uint8List x) => x.length), <int>[
        10,
        10,
        10,
      ]);
    });

    test('读不到的路径计进 covered、不进 segments；空输入交出一个空批', () async {
      final _Sized st = _Sized(<String, int?>{'a': 1, 'b': null, 'c': 1});
      final List<SrsFetchedBatch> out = await _collect(
        srsFetchInBatches(
          <String>['a', 'b', 'c'],
          fetch: st.get,
          budgetBytes: 100,
        ),
      );
      expect(out.single.covered, 3);
      expect(out.single.segments.length, 2);

      final List<SrsFetchedBatch> empty = await _collect(
        srsFetchInBatches(const <String>[], fetch: st.get, budgetBytes: 100),
      );
      expect(empty.single.covered, 0);
      expect(empty.single.segments, isEmpty);
    });

    test('一个失败：不再开新的，抛出第一个错误', () async {
      int calls = 0;
      Future<Uint8List?> fetch(String p) async {
        calls++;
        if (p == 'b') throw StateError('boom');
        return Uint8List(1);
      }

      await expectLater(
        _collect(
          srsFetchInBatches(
            <String>['a', 'b', 'c', 'd', 'e', 'f'],
            fetch: fetch,
            budgetBytes: 100,
            concurrency: 1,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 2);
    });

    test('消费方中途停止监听：之后不再读', () async {
      final List<String> paths = <String>[for (int i = 0; i < 10; i++) 'p$i'];
      final _Sized st = _Sized(<String, int?>{
        for (final String p in paths) p: 4,
      });
      await for (final SrsFetchedBatch _ in srsFetchInBatches(
        paths,
        fetch: st.get,
        budgetBytes: 4,
        concurrency: 1,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(st.fetched, <String>['p0']);
    });
  });

  group('srsSync2Round 按字节分批收', () {
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

    Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expression,
      },
    );

    Future<SrsSync2Report> round(
      SrsSync2Host s,
      SrsLocationStore loc, {
      int budget = kSrsSync2IngestBudgetBytes,
      void Function(int done, int total)? onFetchProgress,
      bool Function()? shouldStop,
    }) => srsSync2Round(
      host: s,
      location: loc,
      locationId: 'loc',
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      ingestBudgetBytes: budget,
      fetchConcurrency: 1,
      onFetchProgress: onFetchProgress,
      shouldStop: shouldStop,
    );

    /// 四台设备离线各写一条笔记，再依次同步一轮：位置上每台设备一个段（同一台设备的小段会被分层合并成一个），
    /// 且彼此没有因果依赖（写笔记时谁也没收过谁的），任意分批都能各自应用。
    Future<(SrsMemoryLocationStore, List<String>)> seeded() async {
      final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
      final List<String> notes = <String>[];
      final List<SrsDbStore> writers = <SrsDbStore>[];
      for (final (String dev, String w) in <(String, String)>[
        ('A', '雪'),
        ('C', '雨'),
        ('D', '風'),
        ('E', '霧'),
      ]) {
        final SrsDbStore s = await device(dev);
        notes.add(await addNote(s, w));
        writers.add(s);
      }
      for (final SrsDbStore s in writers) {
        await round(s, loc);
      }
      return (loc, notes);
    }

    test('每批一次 ingest、进度单调递增并收尾到总数，结果与一批收完相同', () async {
      final (SrsMemoryLocationStore loc, List<String> notes) = await seeded();
      final _CountingHost b = _CountingHost(await device('B'));
      final List<(int, int)> progress = <(int, int)>[];
      final SrsSync2Report r = await round(
        b,
        loc,
        budget: 1,
        onFetchProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(r.error, isNull);
      final int total = progress.first.$2;
      expect(total, greaterThanOrEqualTo(2), reason: 'need several segments');
      expect(progress.first.$1, 0);
      expect(progress.last, (total, total));
      for (int i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThan(progress[i - 1].$1));
        expect(progress[i].$2, total);
      }
      // 预算 1 字节：每段自成一批。
      expect(b.ingestSizes, everyElement(1));
      expect(b.ingestSizes.length, total);
      for (final String n in notes) {
        expect(await b.inner.note(n), isNotNull);
      }
    });

    test('中途收手：报 kSrsSync2Stopped、不发件；已收的批次已提交，下一轮补齐', () async {
      final (SrsMemoryLocationStore loc, List<String> notes) = await seeded();
      final _CountingHost b = _CountingHost(await device('B'));
      int batches = 0;
      final SrsSync2Report stopped = await round(
        b,
        loc,
        budget: 1,
        onFetchProgress: (int done, int total) {
          if (done > 0) batches++;
        },
        shouldStop: () => true,
      );
      expect(stopped.error, kSrsSync2Stopped);
      expect(batches, 1, reason: 'stops right after the first batch');
      expect(b.ingestSizes.length, 1);
      expect(stopped.uploaded, 0);
      expect(
        loc.files.keys.where((String k) => k.startsWith('devices/B/')),
        isEmpty,
        reason: 'no outbox after stopping',
      );

      final SrsSync2Report next = await round(b, loc);
      expect(next.error, isNull);
      for (final String n in notes) {
        expect(await b.inner.note(n), isNotNull);
      }
    });
  });
}

/// 记录每次 ingest 收了几个段的 host 包装。
class _CountingHost implements SrsSync2Host {
  _CountingHost(this.inner);

  final SrsDbStore inner;
  final List<int> ingestSizes = <int>[];

  @override
  String get profileUid => inner.profileUid;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => inner.sync2Command(request, blobs: blobs);

  @override
  Future<Map<String, Object?>> sync2Ingest(
    List<Uint8List> segments, {
    String? keyHex,
  }) {
    ingestSizes.add(segments.length);
    return inner.sync2Ingest(segments, keyHex: keyHex);
  }
}
