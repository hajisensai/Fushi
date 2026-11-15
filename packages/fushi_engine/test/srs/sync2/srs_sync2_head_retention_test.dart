// 位置上哪些旧文件可以删只由内核定（native/fushi_fsrs/src/store/sync2/transport.rs `sync2_obsolete` /
// `HEAD_KEEP_GENS`）：一轮的收尾把本机目录的列表交给内核，照内核给的清单删、删成功的回执。Dart 不持有任何保留规则
// ——以前「留两代旧 head」写在这里（`gen < 当前 - 2`、删了不回执），而内核回收旧小段的安全性正依赖这条它看不到的
// 规则（BUG-4464）。
//
// 前半用脚本宿主钉 Dart 这半边的纪律（只删清单里的、失败不回执、下一轮重给）；后半在真实内核上钉端到端的结果与
// 改之前相同（位置上留下的 head 仍是最新三代），以及旧 head 删失败之后的重试。
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

const String kProfile = '01928c3e-0000-7000-8000-0000000000dd';

const SrsSync2Result _empty = SrsSync2Result(
  <String, Object?>{},
  <(String, Uint8List)>[],
);

String _head(int gen) =>
    'head-${gen.toString().padLeft(12, '0')}-aabbccdd.json';

int? _genOf(String path) {
  final String name = path.substring(path.lastIndexOf('/') + 1);
  if (!name.startsWith('head-') || !name.endsWith('.json')) return null;
  return int.tryParse(name.substring(5).split('-').first);
}

/// 脚本宿主：`head` 写出 [headGen] 代（[unchanged] 时回「没变」指向它），`obsolete` 回 [sweep]；[second] 非空时第
/// 一次回 [sweep] 并要求再问（`again`），第二次回 [second]。
class _Host implements SrsSync2Host {
  _Host(this.log);

  final List<String> log;
  int headGen = 9;
  bool unchanged = false;
  List<String> sweep = <String>[];
  List<String>? second;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

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
        final String path = 'devices/SELF/${_head(headGen)}';
        if (unchanged && request['skipUnchangedMs'] != null) {
          return SrsSync2Result(<String, Object?>{
            'unchanged': true,
            'path': path,
          }, const <(String, Uint8List)>[]);
        }
        return SrsSync2Result(
          <String, Object?>{'gen': headGen},
          <(String, Uint8List)>[(path, Uint8List(1))],
        );
      case 'obsolete':
        final bool first = of('obsolete').length == 1;
        return SrsSync2Result(<String, Object?>{
          'delete': first ? sweep : (second ?? sweep),
          'again': first && second != null,
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

/// 记下写 / 删（`put <path>` / `delete <path>`）；[failOn] 里的路径删除时抛错。
class _Store extends SrsMemoryLocationStore {
  _Store(this.log);

  final List<String> log;
  final Set<String> failOn = <String>{};

  @override
  Future<void> put(String path, Uint8List bytes) {
    log.add('put $path');
    return super.put(path, bytes);
  }

  @override
  Future<void> delete(String path) async {
    if (failOn.contains(path)) throw StateError('delete failed: $path');
    log.add('delete $path');
    await super.delete(path);
  }

  List<String> get own => <String>[
    for (final String p in files.keys)
      if (p.startsWith('devices/SELF/')) p.substring('devices/SELF/'.length),
  ]..sort();
}

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

    setUp(() async {
      log = <String>[];
      host = _Host(log)..headGen = 8;
      loc = _Store(log);
      // 先在空位置上跑一轮（握手建出 meta.json、写出代号 8 的 head），再往本机目录里放：代号很旧的 head（按以前
      // 写在 Dart 的规则早该删）、两个段。
      expect((await round()).error, isNull);
      for (final int g in <int>[1, 2, 3, 7]) {
        loc.files['devices/SELF/${_head(g)}'] = Uint8List(1);
      }
      loc.files['devices/SELF/seg-old.bin'] = Uint8List(1);
      loc.files['devices/SELF/seg-keep.bin'] = Uint8List(1);
      host
        ..headGen = 9
        ..requests.clear();
      log.clear();
    });

    test('只删内核清单里的文件；清单是 head 传上去之后拿本机目录的列表问来的', () async {
      host.sweep = <String>[
        'devices/SELF/${_head(2)}',
        'devices/SELF/seg-old.bin',
      ];
      final SrsSync2Report r = await round();
      expect(r.error, isNull);
      // 内核没给的一个不动：代号 1、3 的旧 head 照样留着（Dart 自己不按代号删）。
      expect(loc.own, <String>[
        _head(1),
        _head(3),
        _head(7),
        _head(8),
        _head(9),
        'seg-keep.bin',
      ]);
      final Map<String, Object?> q = host.of('obsolete').single;
      expect(q['location'], host.of('head').single['location']);
      expect(q['archive'], false);
      expect(q['now'], 1234);
      // 列表是写完 head 之后的：带着刚写的那一份。
      expect(
        (q['present']! as List<Object?>).cast<String>(),
        unorderedEquals(<String>[
          for (final int g in <int>[1, 2, 3, 7, 8, 9]) _head(g),
          'seg-old.bin',
          'seg-keep.bin',
        ]),
      );
      final int put = log.indexOf('put devices/SELF/${_head(9)}');
      final int asked = log.indexOf('op obsolete');
      expect(put, greaterThanOrEqualTo(0));
      expect(asked, greaterThan(put), reason: 'head first, then the sweep');
      expect(
        log.indexWhere((String l) => l.startsWith('delete ')),
        greaterThan(asked),
        reason: 'nothing is deleted before the kernel is asked',
      );
      expect(
        (host.of('obsolete_ack').single['deleted']! as List<Object?>)
            .cast<String>(),
        unorderedEquals(host.sweep),
      );
    });

    test('删失败的不回执、这一轮报错；下一轮内核照样再给，删成功才回执', () async {
      host.sweep = <String>[
        'devices/SELF/${_head(2)}',
        'devices/SELF/seg-old.bin',
      ];
      loc.failOn.add('devices/SELF/${_head(2)}');
      await expectLater(round(), throwsA(isA<StateError>()));
      expect(loc.files.containsKey('devices/SELF/${_head(2)}'), isTrue);
      expect(host.of('obsolete_ack').single['deleted'], <String>[
        'devices/SELF/seg-old.bin',
      ]);

      // 下一轮 head 没变、不写：照样收尾。内核的记录里只剩没确认的那一份。
      loc.failOn.clear();
      host
        ..unchanged = true
        ..sweep = <String>['devices/SELF/${_head(2)}']
        ..requests.clear();
      log.clear();
      final SrsSync2Report r = await round();
      expect(r.error, isNull);
      expect(log.where((String l) => l.startsWith('put ')), isEmpty);
      expect(loc.files.containsKey('devices/SELF/${_head(2)}'), isFalse);
      expect(host.of('obsolete_ack').single['deleted'], <String>[
        'devices/SELF/${_head(2)}',
      ]);
    });

    test('head 没变但上次那份不在位置上：先补写，再收尾（只问一次）', () async {
      host
        ..unchanged = true
        ..sweep = <String>['devices/SELF/${_head(1)}'];
      await round();
      expect(host.of('head'), hasLength(2));
      expect(host.of('obsolete'), hasLength(1));
      expect(
        log.indexOf('put devices/SELF/${_head(9)}'),
        lessThan(log.indexOf('op obsolete')),
      );
      expect(loc.files.containsKey('devices/SELF/${_head(1)}'), isFalse);
    });

    test('归档位置：把归档标记带给内核，清单里的一个不删、直接回执', () async {
      host.sweep = <String>['devices/SELF/seg-old.bin'];
      await round(archive: true);
      expect(host.of('obsolete').single['archive'], true);
      expect(log.where((String l) => l.startsWith('delete ')), isEmpty);
      expect(loc.files.containsKey('devices/SELF/seg-old.bin'), isTrue);
      expect(host.of('obsolete_ack').single['deleted'], <String>[
        'devices/SELF/seg-old.bin',
      ]);
    });

    test('内核清单为空：不删、不回执', () async {
      await round();
      expect(host.of('obsolete'), hasLength(1));
      expect(host.of('obsolete_ack'), isEmpty);
      expect(log.where((String l) => l.startsWith('delete ')), isEmpty);
    });

    test('内核要求再问：清单全部删成并回执之后再问一次，列表里不带刚删掉的；旧小段排在旧 head 之后删', () async {
      host
        ..sweep = <String>[
          'devices/SELF/${_head(1)}',
          'devices/SELF/${_head(2)}',
        ]
        ..second = <String>['devices/SELF/seg-old.bin'];
      final SrsSync2Report r = await round();
      expect(r.error, isNull);
      final List<Map<String, Object?>> asks = host.of('obsolete');
      expect(asks, hasLength(2));
      expect(
        (asks[1]['present']! as List<Object?>).cast<String>(),
        unorderedEquals(<String>[
          for (final int g in <int>[3, 7, 8, 9]) _head(g),
          'seg-old.bin',
          'seg-keep.bin',
        ]),
      );
      final List<String> steps = <String>[
        for (final String l in log)
          if (l.startsWith('delete ') || l.startsWith('op obsolete')) l,
      ];
      expect(steps.sublist(0, 1), <String>['op obsolete']);
      expect(
        steps.sublist(1, 3),
        unorderedEquals(<String>[
          'delete devices/SELF/${_head(1)}',
          'delete devices/SELF/${_head(2)}',
        ]),
      );
      expect(steps.sublist(3), <String>[
        'op obsolete_ack',
        'op obsolete',
        'delete devices/SELF/seg-old.bin',
        'op obsolete_ack',
      ]);
      expect(loc.own, <String>[
        _head(3),
        _head(7),
        _head(8),
        _head(9),
        'seg-keep.bin',
      ]);
    });

    test('内核要求再问但旧 head 没删成：不再问，旧小段留着', () async {
      host
        ..sweep = <String>[
          'devices/SELF/${_head(1)}',
          'devices/SELF/${_head(2)}',
        ]
        ..second = <String>['devices/SELF/seg-old.bin'];
      loc.failOn.add('devices/SELF/${_head(2)}');
      await expectLater(round(), throwsA(isA<StateError>()));
      expect(host.of('obsolete'), hasLength(1));
      expect(loc.files.containsKey('devices/SELF/seg-old.bin'), isTrue);
      expect(host.of('obsolete_ack').single['deleted'], <String>[
        'devices/SELF/${_head(1)}',
      ]);
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

    Future<SrsSync2Report> round(
      SrsDbStore s,
      SrsLocationStore loc,
      String id, {
      bool archive = false,
    }) => srsSync2Round(
      host: s,
      location: loc,
      locationId: id,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      archive: archive,
    );

    List<int> gensOn(_Store loc, String device) => <int>[
      for (final String p in loc.files.keys)
        if (p.startsWith('devices/$device/')) ?_genOf(p),
    ]..sort();

    test('多轮之后位置上留下的 head 与改之前同一条规则（代号 ≥ 最新 - 2）；归档位置全留', () async {
      final SrsDbStore a = await device('A');
      final _Store loc = _Store(<String>[]);
      final _Store arch = _Store(<String>[]);
      for (int i = 0; i < 6; i++) {
        await addNote(a, '語$i');
        await round(a, loc, 'loc');
        await round(a, arch, 'arch', archive: true);
      }
      final String self = a.sync2Device!;
      // 写过的每一代（代号是本机全局的：两个位置轮流写，各自不连续）。
      List<int> written(_Store s) => <int>[
        for (final String l in s.log)
          if (l.startsWith('put devices/$self/')) ?_genOf(l),
      ]..sort();
      final List<int> all = written(loc);
      expect(all.length, greaterThanOrEqualTo(6));
      // 以前写在 Dart 里的规则：写出代号 gen 的 head 之后删 `g < gen - 2`。
      expect(gensOn(loc, self), <int>[
        for (final int g in all)
          if (g >= all.last - 2) g,
      ]);
      expect(
        gensOn(arch, self),
        written(arch),
        reason: 'archive never deletes',
      );
      expect(written(arch).length, greaterThanOrEqualTo(6));
    });

    test('旧 head 删失败：这一轮报错；之后没变的一轮照样重删（以前要等下一次写 head）', () async {
      final SrsDbStore a = await device('A');
      final _Store loc = _Store(<String>[]);
      for (int i = 0; i < 3; i++) {
        await addNote(a, '語$i');
        await round(a, loc, 'loc');
      }
      final String self = a.sync2Device!;
      expect(gensOn(loc, self), hasLength(3));
      // 下一轮写第四代：最旧的那一份该删，删它失败。
      final String oldest = loc.files.keys.firstWhere(
        (String p) =>
            p.startsWith('devices/$self/') &&
            _genOf(p) == gensOn(loc, self).first,
      );
      loc.failOn.add(oldest);
      await addNote(a, '語x');
      await expectLater(round(a, loc, 'loc'), throwsA(isA<StateError>()));
      expect(gensOn(loc, self), hasLength(4));
      // 没有新东西的一轮：不写 head，但没确认删掉的旧 head 照样在内核的清单里。
      loc.failOn.clear();
      loc.log.clear();
      final SrsSync2Report quiet = await round(a, loc, 'loc');
      expect(quiet.error, isNull);
      expect(loc.log, <String>['delete $oldest']);
      expect(gensOn(loc, self), hasLength(3));
      // 再一轮：什么都不动。
      loc.log.clear();
      await round(a, loc, 'loc');
      expect(loc.log, isEmpty);
    });
  });
}
