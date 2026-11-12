// 换过身份（设计 §7.3）的设备清位置上旧身份的目录：能删什么只由内核定（native/fushi_fsrs/src/store/sync2/former.rs
// `sync2_obsolete_former`——只会是被盖过的旧 head，段一个不删）。Dart 这半边（srs_sync2_round.dart
// `srsSweepFormerIdentities`）只列目录、读 head、照单删。
//
// 前半用脚本宿主钉 Dart 这半边的纪律：内核点名才去看、列的是写完 head 之后的目录、每一份 head 的字节都原样交给
// 内核、读不到的不补、只删清单里的、出错不让这一轮失败也不混进「跳过了段」。后半在真实内核上钉端到端的结果：旧
// 目录里被盖过的 head 过一个静止期后删掉，段都在，之后才来的设备读到全部内容。
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

const String kProfile = '01928c3e-0000-7000-8000-0000000000de';

const SrsSync2Result _empty = SrsSync2Result(
  <String, Object?>{},
  <(String, Uint8List)>[],
);

String _head(int gen) =>
    'head-${gen.toString().padLeft(12, '0')}-aabbccdd.json';

/// 脚本宿主：`obsolete` 的回复带 [former]；`obsolete_former` 对每个旧身份回 [formerDelete] 里它那一份清单
/// （[formerThrows] 里的旧身份改为抛错），并记下收到的 head 字节。
class _Host implements SrsSync2Host {
  _Host(this.log);

  final List<String> log;
  bool unchanged = false;
  List<String>? former = <String>[];
  final Map<String, List<String>> formerDelete = <String, List<String>>{};
  final Set<String> formerThrows = <String>{};
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final Map<String, List<Uint8List>> formerBlobs = <String, List<Uint8List>>{};

  List<Map<String, Object?>> of(String op) => <Map<String, Object?>>[
    for (final Map<String, Object?> r in requests)
      if (r['op'] == op) r,
  ];

  @override
  String get profileUid => 'p';

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    requests.add(request);
    log.add('op ${request['op']}');
    switch (request['op']) {
      case 'identity':
        return const SrsSync2Result(<String, Object?>{
          'collection': 'c1',
          'device': 'SELF',
        }, <(String, Uint8List)>[]);
      case 'plan':
        return const SrsSync2Result(<String, Object?>{
          'fetch': <Object?>[],
        }, <(String, Uint8List)>[]);
      case 'outbox':
        return const SrsSync2Result(<String, Object?>{
          'upto': 0,
        }, <(String, Uint8List)>[]);
      case 'head':
        final String path = 'devices/SELF/${_head(9)}';
        if (unchanged && request['skipUnchangedMs'] != null) {
          return SrsSync2Result(<String, Object?>{
            'unchanged': true,
            'path': path,
          }, const <(String, Uint8List)>[]);
        }
        return SrsSync2Result(
          <String, Object?>{'gen': 9},
          <(String, Uint8List)>[(path, Uint8List(1))],
        );
      case 'obsolete':
        return SrsSync2Result(<String, Object?>{
          'delete': const <String>[],
          'again': false,
          'former': ?former,
        }, const <(String, Uint8List)>[]);
      case 'obsolete_former':
        final String device = request['device']! as String;
        formerBlobs[device] = blobs;
        if (formerThrows.contains(device)) {
          throw StateError('kernel refused $device');
        }
        return SrsSync2Result(<String, Object?>{
          'delete': formerDelete[device] ?? const <String>[],
        }, const <(String, Uint8List)>[]);
    }
    return _empty;
  }

  @override
  Future<void> sync2IngestBegin() async {}

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) async => <String, Object?>{'applied': 0, 'fork': false};

  @override
  Future<Map<String, Object?>> sync2IngestFinish() async => <String, Object?>{
    'applied': 0,
    'fork': false,
  };

  @override
  Future<void> sync2IngestEnd() async {}
}

/// 记下列目录 / 写 / 删（`list <dir>` / `put <path>` / `delete <path>`）；[failDelete] 里的路径删除时抛错，
/// [failList] 里的目录列的时候抛错，[unreadable] 里的路径读出来是 null（列得到、读不到）。[armed] 之前不抛、不藏
/// （一轮开头读各设备 head 的那一半照常）。
class _Store extends SrsMemoryLocationStore {
  _Store(this.log);

  final List<String> log;
  final Set<String> failDelete = <String>{};
  final Set<String> failList = <String>{};
  final Set<String> unreadable = <String>{};
  bool Function() armed = () => true;

  @override
  Future<List<SrsLocationEntry>> list(String dir) {
    log.add('list $dir');
    if (armed() && failList.contains(dir)) {
      throw StateError('list failed: $dir');
    }
    return super.list(dir);
  }

  @override
  Future<Uint8List?> get(String path) async {
    if (armed() && unreadable.contains(path)) return null;
    return super.get(path);
  }

  @override
  Future<void> put(String path, Uint8List bytes) {
    log.add('put $path');
    return super.put(path, bytes);
  }

  @override
  Future<void> delete(String path) async {
    if (failDelete.contains(path)) throw StateError('delete failed: $path');
    log.add('delete $path');
    await super.delete(path);
  }

  List<String> under(String device) => <String>[
    for (final String p in files.keys)
      if (p.startsWith('devices/$device/'))
        p.substring('devices/$device/'.length),
  ]..sort();
}

Uint8List _bytes(int tag) => Uint8List.fromList(<int>[1, 2, 3, tag]);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('脚本宿主', () {
    late List<String> log;
    late _Host host;
    late _Store loc;

    Future<SrsSync2Report> round({bool archive = false}) => srsSync2Round(
      host: host,
      location: loc,
      locationId: 'loc',
      nowMs: () => 1234,
      archive: archive,
    );

    /// 旧身份 [device] 的目录：代号 [gens] 的 head（内容各不相同）、一个段、一个转发件。
    void seed(String device, List<int> gens) {
      for (final int g in gens) {
        loc.files['devices/$device/${_head(g)}'] = _bytes(g);
      }
      loc.files['devices/$device/seg-a.bin'] = Uint8List(1);
      loc.files['devices/$device/rly-b.bin'] = Uint8List(1);
    }

    setUp(() async {
      log = <String>[];
      host = _Host(log);
      loc = _Store(log);
      // 先在空位置上跑一轮（握手建出 meta.json、写出 head）。
      expect((await round()).error, isNull);
      seed('OLD', <int>[3, 4, 5]);
      host.requests.clear();
      log.clear();
      // 清旧目录那一步在写 head 之后；在那之前位置照常。
      loc.armed = () => log.contains('op obsolete');
    });

    test('内核没点名（没换过身份 / 没到该看的时候）：不列旧目录、不问', () async {
      for (final List<String>? none in <List<String>?>[<String>[], null]) {
        host
          ..former = none
          ..requests.clear();
        log.clear();
        final SrsSync2Report r = await round();
        expect(r.error, isNull);
        expect(host.of('obsolete_former'), isEmpty);
        expect(
          log.sublist(log.indexOf('op obsolete')),
          isNot(contains('list devices/OLD')),
        );
        expect(r.formerSweepErrors, isEmpty);
      }
      expect(loc.under('OLD'), hasLength(5));
    });

    test('内核点名：收尾之后重新列旧目录、把每一份 head 的字节交给内核，只删内核给的', () async {
      host
        ..former = <String>['OLD']
        ..formerDelete['OLD'] = <String>['devices/OLD/${_head(3)}'];
      final SrsSync2Report r = await round();
      expect(r.error, isNull);
      expect(r.formerSweepErrors, isEmpty);
      final Map<String, Object?> q = host.of('obsolete_former').single;
      expect(q['location'], host.of('obsolete').single['location']);
      expect(q['device'], 'OLD');
      expect(q['now'], 1234);
      expect(q.containsKey('archive'), isFalse);
      // 目录里的全部文件名（不只 head）；head 的字节一份不少、原样。
      expect(
        (q['present']! as List<Object?>).cast<String>(),
        unorderedEquals(<String>[
          _head(3),
          _head(4),
          _head(5),
          'seg-a.bin',
          'rly-b.bin',
        ]),
      );
      expect(
        host.formerBlobs['OLD'],
        unorderedEquals(<Uint8List>[_bytes(3), _bytes(4), _bytes(5)]),
      );
      // 顺序：本机的 head 写上去 → 本机目录收尾 → 这时才列旧目录 → 问内核 → 删。
      final int swept = log.indexOf('op obsolete');
      final int listed = log.lastIndexOf('list devices/OLD');
      final int asked = log.indexOf('op obsolete_former');
      expect(log.indexOf('put devices/SELF/${_head(9)}'), lessThan(swept));
      expect(listed, greaterThan(swept));
      expect(asked, greaterThan(listed));
      expect(log.indexOf('delete devices/OLD/${_head(3)}'), greaterThan(asked));
      // 内核没给的一个不动；内核不记待删清单，删完不回执。
      expect(loc.under('OLD'), <String>[
        _head(4),
        _head(5),
        'rly-b.bin',
        'seg-a.bin',
      ]);
      expect(host.of('obsolete_ack'), isEmpty);
    });

    test('head 没变、不写的一轮照样去看', () async {
      host
        ..unchanged = true
        ..former = <String>['OLD']
        ..formerDelete['OLD'] = <String>['devices/OLD/${_head(4)}'];
      final SrsSync2Report r = await round();
      expect(r.error, isNull);
      expect(log.where((String l) => l.startsWith('put ')), isEmpty);
      expect(host.of('obsolete_former'), hasLength(1));
      expect(loc.files.containsKey('devices/OLD/${_head(4)}'), isFalse);
    });

    test('列得到、读不到的 head：少交一份，不补不猜（由内核判证明不了）', () async {
      host.former = <String>['OLD'];
      loc.unreadable.add('devices/OLD/${_head(4)}');
      final SrsSync2Report r = await round();
      expect(r.error, isNull);
      final Map<String, Object?> q = host.of('obsolete_former').single;
      expect((q['present']! as List<Object?>), contains(_head(4)));
      expect(
        host.formerBlobs['OLD'],
        unorderedEquals(<Uint8List>[_bytes(3), _bytes(5)]),
      );
      expect(loc.under('OLD'), hasLength(5));
    });

    test('几个旧身份逐个看；一个出错不影响这一轮、不影响下一个，也不算跳过了段', () async {
      seed('OLDER', <int>[1, 2]);
      seed('GONE', <int>[7]);
      seed('STUCK', <int>[6, 8]);
      host
        ..former = <String>['GONE', 'OLD', 'STUCK', 'OLDER']
        ..formerThrows.add('OLD')
        ..formerDelete['STUCK'] = <String>[
          'devices/STUCK/${_head(6)}',
          'devices/STUCK/seg-a.bin',
        ]
        ..formerDelete['OLDER'] = <String>['devices/OLDER/${_head(1)}'];
      loc
        ..failList.add('devices/GONE')
        ..failDelete.add('devices/STUCK/${_head(6)}');
      final SrsSync2Report r = await round();
      expect(r.error, isNull, reason: 'the round itself is done');
      expect(r.errors, isEmpty, reason: 'not a skipped segment');
      expect(r.formerSweepErrors, hasLength(3));
      expect(r.formerSweepErrors[0], startsWith('GONE: '));
      expect(r.formerSweepErrors[0], contains('list failed'));
      expect(r.formerSweepErrors[1], startsWith('OLD: '));
      expect(r.formerSweepErrors[1], contains('kernel refused'));
      expect(r.formerSweepErrors[2], startsWith('STUCK: '));
      expect(r.formerSweepErrors[2], contains('delete failed'));
      // 列不了的没问内核；删失败的那份还在、同一份清单里别的照删；排在后面的旧身份照常。
      expect(
        <Object?>[
          for (final Map<String, Object?> q in host.of('obsolete_former'))
            q['device'],
        ],
        <String>['OLD', 'STUCK', 'OLDER'],
      );
      expect(loc.files.containsKey('devices/STUCK/${_head(6)}'), isTrue);
      expect(loc.files.containsKey('devices/STUCK/seg-a.bin'), isFalse);
      expect(loc.under('OLDER'), <String>[_head(2), 'rly-b.bin', 'seg-a.bin']);
      expect(loc.under('OLD'), hasLength(5));
    });

    test('没出错的轮次报告里没有这一项', () async {
      host.former = <String>['OLD'];
      expect((await round()).formerSweepErrors, isEmpty);
    });
  });

  group('真实内核', () {
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

    Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc, int now) =>
        srsSync2Round(
          host: s,
          location: loc,
          locationId: 'loc',
          nowMs: () => now,
        );

    Future<String> idOf(SrsDbStore s, int now) async =>
        (await s.sync2Command(<String, Object?>{
              'op': 'identity',
              'now': now,
            })).map['device']!
            as String;

    const int day = 24 * 60 * 60 * 1000;

    test('换身份之后：旧目录里被盖过的 head 过一个静止期才删，段一个不删；后来的设备读到全部', () async {
      final SrsDbStore a = await device('A');
      final _Store loc = _Store(<String>[]);
      final int t0 = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < 5; i++) {
        await addNote(a, '語$i');
        expect((await round(a, loc, t0 + i)).error, isNull);
      }
      final String old = await idOf(a, t0 + 10);
      await a.sync2Command(<String, Object?>{'op': 'rotate', 'now': t0 + 20});
      final String fresh = await idOf(a, t0 + 30);
      expect(fresh, isNot(old));
      final List<String> before = loc.under(old);
      List<String> heads(List<String> names) => <String>[
        for (final String n in names)
          if (n.startsWith('head-')) n,
      ];
      List<String> rest(List<String> names) => <String>[
        for (final String n in names)
          if (!n.startsWith('head-')) n,
      ];
      expect(heads(before), hasLength(3));
      expect(rest(before), isNotEmpty);

      // 新身份的第一轮：旧目录第一次被看，只起算。
      await addNote(a, '新');
      SrsSync2Report r = await round(a, loc, t0 + 1000);
      expect(r.error, isNull);
      expect(r.formerSweepErrors, isEmpty);
      expect(loc.under(old), before);
      // 没静止够的轮次不动它。
      await round(a, loc, t0 + 1000 + day - 1);
      expect(loc.under(old), before);
      // 静止够了：只剩代号最大的那份 head，段原样。
      r = await round(a, loc, t0 + 1000 + day);
      expect(r.error, isNull);
      expect(r.formerSweepErrors, isEmpty);
      expect(heads(loc.under(old)), <String>[heads(before).last]);
      expect(rest(loc.under(old)), rest(before));
      // 之后的轮次再没有东西可删。
      for (int k = 2; k < 5; k++) {
        await round(a, loc, t0 + 1000 + k * day + k);
        expect(heads(loc.under(old)), <String>[heads(before).last]);
        expect(rest(loc.under(old)), rest(before));
      }

      // 清过之后才第一次来的设备：旧身份与新身份的内容都读到。
      final SrsDbStore b = await device('B');
      final int end = t0 + 1000 + 6 * day;
      for (int i = 0; i < 2; i++) {
        expect((await round(b, loc, end)).error, isNull);
        expect((await round(a, loc, end)).error, isNull);
      }
      expect(
        (await b.sync2Digest())['digest'],
        (await a.sync2Digest())['digest'],
      );
      expect(await a.userNoteCount(), 6);
      expect(await b.userNoteCount(), 6);
    });
  });
}
