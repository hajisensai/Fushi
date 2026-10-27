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

    /// 先在空位置上跑一轮让握手写下 `meta.json`（位置上一有数据、没有它就不同步）。
    Future<void> writeMeta(SrsMemoryLocationStore loc) => srsSync2Round(
      host: _ScriptedHost(own: const <String>[], others: const <String>[]),
      location: loc,
      locationId: 'loc',
      nowMs: () => 0,
    );

    test('本机身份的段远超预算也按预算分批；会话 begin → 各批 → finish，分叉在收尾才报', () async {
      const int seg = 10;
      const int budget = 15;
      final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
      final List<String> own = <String>[
        for (int i = 0; i < 8; i++) 'devices/SELF/seg-own-$i.bin',
      ];
      final List<String> others = <String>[
        for (int i = 0; i < 4; i++) 'devices/O/seg-o-$i.bin',
      ];
      await writeMeta(loc);
      for (final String p in <String>[...own, ...others]) {
        loc.files[p] = Uint8List(seg);
      }
      final _ScriptedHost host = _ScriptedHost(own: own, others: others);
      for (final int conc in <int>[1, 3]) {
        host.steps.clear();
        host.batchSizes.clear();
        final List<(int, int)> progress = <(int, int)>[];
        final SrsSync2Report r = await srsSync2Round(
          host: host,
          location: loc,
          locationId: 'loc',
          nowMs: () => 0,
          ingestBudgetBytes: budget,
          fetchConcurrency: conc,
          onFetchProgress: (int done, int total) => progress.add((done, total)),
        );
        expect(r.error, isNull);
        expect(r.fork, isTrue, reason: 'fork comes from finish');
        expect(host.steps.first, 'begin');
        expect(host.steps.last, 'finish');
        expect(host.steps.where((String x) => x == 'begin').length, 1);
        expect(host.steps.where((String x) => x == 'finish').length, 1);
        // 本机身份的 8 个段（80 字节）不再整批塞进第一批。
        for (final List<int> b in host.batchSizes) {
          final int bytes = b.fold(0, (int s, int x) => s + x);
          expect(bytes, lessThan(budget + conc * seg), reason: 'conc=$conc');
        }
        expect(host.batchSizes.length, greaterThan(2));
        expect(
          host.batchSizes.fold(0, (int s, List<int> b) => s + b.length),
          own.length + others.length,
        );
        expect(progress.last, (12, 12));
        for (int i = 1; i < progress.length; i++) {
          expect(progress[i].$1, greaterThan(progress[i - 1].$1));
        }
      }
    });

    test('中途收手不收尾：分叉点可能没看全，不换身份', () async {
      final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
      final List<String> own = <String>[
        for (int i = 0; i < 4; i++) 'devices/SELF/seg-own-$i.bin',
      ];
      await writeMeta(loc);
      for (final String p in own) {
        loc.files[p] = Uint8List(10);
      }
      final _ScriptedHost host = _ScriptedHost(
        own: own,
        others: const <String>[],
      );
      final SrsSync2Report r = await srsSync2Round(
        host: host,
        location: loc,
        locationId: 'loc',
        nowMs: () => 0,
        ingestBudgetBytes: 1,
        fetchConcurrency: 1,
        shouldStop: () => true,
      );
      expect(r.error, kSrsSync2Stopped);
      expect(r.fork, isFalse);
      expect(host.steps, <String>['begin', 'batch']);
    });
  });

  // 发件分批 + 水位续传（反馈 XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL）：上传中途断掉，下一轮从已确认的水位接着发，
  // 已确认的批次一个不重发；读者照样收齐。
  group('srsSync2Round 分批发件', () {
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

    test('第二批上传失败：下一轮从水位续发，第一批不重发', () async {
      final SrsDbStore a = await device('A');
      final SrsMemoryLocationStore warmup = SrsMemoryLocationStore();
      final List<String> notes = <String>[];
      // 每轮只带一条笔记：本机切出三个小段（不到一层合并的个数，不会被合并）。
      for (final String w in <String>['雪', '雨', '風']) {
        notes.add(
          await a.createNote(
            noteTypeId: a.lapisNoteTypeId,
            fieldsById: <String, String>{
              srsLapisFieldId(kProfile, 'Expression'): w,
            },
          ),
        );
        final SrsSync2Report r = await srsSync2Round(
          host: a,
          location: warmup,
          locationId: 'warmup',
          nowMs: () => DateTime.now().millisecondsSinceEpoch,
        );
        expect(r.error, isNull);
      }

      final _FlakyLocation loc = _FlakyLocation(failSegmentPut: 2);
      Future<SrsSync2Report> round() => srsSync2Round(
        host: a,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        outboxBudgetBytes: 1, // 每批一段
      );
      await expectLater(round(), throwsA(isA<StateError>()));
      final List<String> firstRoundSegs = loc.segmentPuts.toList();
      expect(firstRoundSegs, hasLength(1), reason: 'batch 1 written + acked');
      expect(
        loc.files.keys.where((String k) => k.contains('/head-')),
        isEmpty,
        reason: 'no head until every batch is up',
      );

      final SrsSync2Report ok = await round();
      expect(ok.error, isNull);
      expect(
        loc.segmentPuts.where((String p) => p == firstRoundSegs.single),
        hasLength(1),
        reason: 'confirmed batch is not uploaded again',
      );
      expect(
        loc.segmentPuts.toSet().length,
        loc.segmentPuts.length,
        reason: 'no segment uploaded twice',
      );
      expect(loc.segmentPuts.length, greaterThanOrEqualTo(3));

      final SrsDbStore b = await device('B');
      final SrsSync2Report rb = await srsSync2Round(
        host: b,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );
      expect(rb.error, isNull);
      for (final String n in notes) {
        expect(await b.note(n), isNotNull);
      }
    });
  });
}

/// 第 [failSegmentPut] 次写段时抛错（模拟上传中途断网）的内存位置；记下每次写成的段。
class _FlakyLocation extends SrsMemoryLocationStore {
  _FlakyLocation({required this.failSegmentPut});

  final int failSegmentPut;
  int _segmentAttempts = 0;
  final List<String> segmentPuts = <String>[];

  @override
  Future<void> put(String path, Uint8List bytes) async {
    if (path.contains('/seg-')) {
      _segmentAttempts++;
      if (_segmentAttempts == failSegmentPut) {
        throw StateError('network dropped mid-upload');
      }
      segmentPuts.add(path);
    }
    await super.put(path, bytes);
  }
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
  Future<void> sync2IngestBegin() => inner.sync2IngestBegin();

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) {
    ingestSizes.add(segments.length);
    return inner.sync2IngestBatch(segments, keyHex: keyHex);
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() => inner.sync2IngestFinish();
}

/// 只回答一轮同步要的命令的假内核：plan 让拉 [own]（本机身份）与 [others] 两组段，记下收段会话的每一步。
class _ScriptedHost implements SrsSync2Host {
  _ScriptedHost({required this.own, required this.others});

  final List<String> own;
  final List<String> others;

  /// 'begin' / 'batch:<字节数>' / 'finish'，按调用顺序。
  final List<String> steps = <String>[];
  final List<List<int>> batchSizes = <List<int>>[];

  @override
  String get profileUid => kProfile;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async => switch (request['op']) {
    'identity' => const SrsSync2Result(<String, Object?>{
      'collection': 'c1',
      'device': 'SELF',
    }, <(String, Uint8List)>[]),
    'plan' => SrsSync2Result(<String, Object?>{
      'fetch': <Object?>[
        <String, Object?>{'device': 'SELF', 'files': own, 'own': true},
        <String, Object?>{'device': 'O', 'files': others, 'own': false},
      ],
      'fork': true,
    }, const <(String, Uint8List)>[]),
    'outbox' => const SrsSync2Result(<String, Object?>{
      'upto': 0,
    }, <(String, Uint8List)>[]),
    'head' => const SrsSync2Result(<String, Object?>{
      'gen': 0,
      'delete': <Object?>[],
    }, <(String, Uint8List)>[]),
    _ => const SrsSync2Result(<String, Object?>{}, <(String, Uint8List)>[]),
  };

  @override
  Future<void> sync2IngestBegin() async => steps.add('begin');

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) async {
    steps.add('batch');
    batchSizes.add(<int>[for (final Uint8List s in segments) s.length]);
    return <String, Object?>{'applied': segments.length, 'fork': false};
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() async {
    steps.add('finish');
    return <String, Object?>{'applied': 0, 'fork': true};
  }
}
