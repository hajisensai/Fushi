// 新代同步一轮（srs_sync2_round.dart，G8-7）的 Dart 侧编排：假内核 + 内存位置，不要原生库。内核一侧的语义（两台设备
// 收敛、加密、分叉、停用……）在 native/fushi_fsrs/src/store/gen4/cmd/sync_tests.rs 经 C ABI 测。
//
// - 根：`location_root` 给的文件按前缀分到新根 / 旧根，`ensure` 里已存在的不覆盖；要更新的版本 / 认不得的根什么都不写。
// - 读：plan 收到各设备目录的文件名（`listing`）与 loc 标记；要拉的段分批交给 ingest，有分叉就收尾。
// - 发：outbox → 写 → outbox_ack 直到 `more` 为假；被拒（本机日志变了）就不写 head。
// - head：没变且上次那份还在位置上就不写；上次那份不在了就不带 `skipUnchangedMs` 再要一次。
// - 收尾：obsolete 给的路径照删。
// - G8-7b / G8-7c：旧根接手（扫 → 学公钥的 head + 段按字节分批、每批按 maxItems 切事务，最后不带段带 settle）、承袭上传（plan → 读 → outbox → 写 → ack；
//   传不上去的不记指纹）、媒体清单收发、旧身份目录清理、只有协议 1 旧根时 `has2`。
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/srs/sync2/srs_sync4_steps.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// 按命令名给回包的假内核；记下每条请求。
class _FakeHost implements SrsSync2Host {
  _FakeHost(this.replies);

  /// 命令名 → 依次给出的回包（用完了重复最后一个）。
  final Map<String, List<SrsSync2Result>> replies;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<List<Uint8List>> ingested = <List<Uint8List>>[];

  /// 每批收段带的位置（重切件的停放按位置记，内核 `cmd/sync_park.rs`）。
  final List<String?> ingestLocations = <String?>[];
  int finishes = 0;
  int begins = 0;
  int ends = 0;

  @override
  String get profileUid => 'p';

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    requests.add(request);
    final String op = request['op']! as String;
    switch (op) {
      case 'identity':
        return const SrsSync2Result(<String, Object?>{
          'device': 'dev-a',
          'collection': 'c',
          'dir': 'p',
        }, <(String, Uint8List)>[]);
      case 'location_sealed':
      case 'location_seal':
        return const SrsSync2Result(<String, Object?>{
          'sealed': false,
          'kdf': null,
        }, <(String, Uint8List)>[]);
    }
    final List<SrsSync2Result> q = replies[op] ?? <SrsSync2Result>[];
    if (q.isEmpty) {
      return const SrsSync2Result(<String, Object?>{}, <(String, Uint8List)>[]);
    }
    return q.length == 1 ? q.first : q.removeAt(0);
  }

  @override
  Future<void> sync2IngestBegin() async => begins++;

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
    String? location,
  }) async {
    ingested.add(segments);
    ingestLocations.add(location);
    return <String, Object?>{'applied': segments.length, 'fork': true};
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() async {
    finishes++;
    return <String, Object?>{'fork': true};
  }

  @override
  Future<void> sync2IngestEnd() async => ends++;

  List<String> ops() => <String>[
    for (final Map<String, Object?> r in requests) r['op']! as String,
  ];

  Map<String, Object?> last(String op) =>
      requests.lastWhere((Map<String, Object?> r) => r['op'] == op);
}

SrsSync2Result _r(
  Map<String, Object?> m, [
  List<(String, Uint8List)> files = const <(String, Uint8List)>[],
]) => SrsSync2Result(m, files);

void main() {
  late SrsMemoryLocationStore v4;
  late SrsMemoryLocationStore v3;

  setUp(() {
    v4 = SrsMemoryLocationStore();
    v3 = SrsMemoryLocationStore();
  });

  Future<SrsSync2Report> run(_FakeHost host) => srsSync2Round(
    host: host,
    location: v4,
    oldRoot: v3,
    locationId: 'L',
    nowMs: () => 1000,
    ingestBudgetBytes: 1,
    fetchConcurrency: 1,
  );

  Map<String, List<SrsSync2Result>> happy({bool accepted = true}) =>
      <String, List<SrsSync2Result>>{
        'location_root': <SrsSync2Result>[
          _r(
            <String, Object?>{
              'state': kSrs4RootOk,
              'loc': 'LOC1',
              'ensure': <String>['v3/devices/tomb/head-1.json'],
            },
            <(String, Uint8List)>[
              ('v4/meta.json', _b('{"fmt":"m4"}')),
              ('v4/loc/LOC1', Uint8List(0)),
              ('v3/meta.json', _b('{"moved":"v4"}')),
              ('v3/devices/tomb/head-1.json', _b('new tomb')),
            ],
          ),
        ],
        'plan': <SrsSync2Result>[
          _r(<String, Object?>{
            'fetch': <Object?>[
              <String, Object?>{
                'device': 'dev-b',
                'own': false,
                'files': <String>[
                  'devices/dev-b/seg-000000000001-000000000002-aaaaaaaa.bin',
                  'devices/dev-b/seg-000000000003-000000000004-bbbbbbbb.bin',
                ],
              },
            ],
            'needsUpgrade': false,
            'sealed': false,
            'finishPending': false,
            'errors': <String>[],
          }),
        ],
        'outbox': <SrsSync2Result>[
          _r(
            <String, Object?>{
              'segments': <Object?>[
                <Object?>[1, 5, 'cccccccc', 0],
              ],
              'upto': 5,
              'more': true,
            },
            <(String, Uint8List)>[
              (
                'devices/dev-a/seg-000000000001-000000000005-cccccccc.bin',
                _b('s1'),
              ),
            ],
          ),
          _r(
            <String, Object?>{
              'segments': <Object?>[
                <Object?>[6, 7, 'dddddddd', 0],
              ],
              'upto': 7,
              'more': false,
            },
            <(String, Uint8List)>[
              (
                'devices/dev-a/seg-000000000006-000000000007-dddddddd.bin',
                _b('s2'),
              ),
            ],
          ),
        ],
        'outbox_ack': <SrsSync2Result>[
          _r(<String, Object?>{'accepted': accepted, 'uploaded': 7}),
        ],
        'head': <SrsSync2Result>[
          _r(
            <String, Object?>{
              'unchanged': false,
              'path': 'devices/dev-a/head-000000000003-dddddddd.json',
              'gen': 3,
            },
            <(String, Uint8List)>[
              ('devices/dev-a/head-000000000003-dddddddd.json', _b('h3')),
            ],
          ),
        ],
        'obsolete': <SrsSync2Result>[
          _r(<String, Object?>{
            'delete': <String>['devices/dev-a/head-000000000001-old.json'],
          }),
        ],
        // 旧根清单没变、没有承袭日志、位置上没有别的设备的新清单（真内核在这些情形下的回包）。
        'oldroot_scan': <SrsSync2Result>[
          _r(<String, Object?>{'changed': false}),
        ],
        'heritage_plan': <SrsSync2Result>[
          _r(<String, Object?>{'skip': true}),
        ],
        'media_manifests': <SrsSync2Result>[
          _r(<String, Object?>{'fetch': <String>[]}),
        ],
        'media_manifest_build': <SrsSync2Result>[
          _r(<String, Object?>{'built': false}),
        ],
      };

  test('一轮按顺序走完：根分到两个根、分批收、分叉收尾、分批发、写 head、删旧的', () async {
    v3.files['devices/tomb/head-1.json'] = _b('old tomb');
    // 位置上已有数据却没有 meta 时握手会停下（可能是列目录还没看到），所以这里先放一份。
    v4.files['meta.json'] = _b('{"fmt":"m4"}');
    v4.files['devices/dev-b/head-000000000002-bbbbbbbb.json'] = _b('hb');
    v4.files['devices/dev-b/seg-000000000001-000000000002-aaaaaaaa.bin'] = _b(
      'x1',
    );
    v4.files['devices/dev-b/seg-000000000003-000000000004-bbbbbbbb.bin'] = _b(
      'x2',
    );
    v4.files['devices/dev-a/head-000000000001-old.json'] = _b('old');
    final _FakeHost host = _FakeHost(happy());
    final SrsSync2Report r = await run(host);

    expect(r.error, isNull);
    expect(
      host.ops().where(
        (String o) => o != 'identity' && !o.startsWith('location_seal'),
      ),
      <String>[
        'location_root',
        'plan',
        'oldroot_scan',
        'media_manifests',
        'heritage_plan',
        'outbox',
        'outbox_ack',
        'outbox',
        'outbox_ack',
        'head',
        'obsolete',
        'media_manifest_build',
        'relay_outbox',
        'relay_ack',
      ],
    );
    // 根：新根 meta / loc 标记进 v4，围栏进 v3；墓碑已在，不覆盖。
    expect(utf8.decode(v4.files['meta.json']!), '{"fmt":"m4"}');
    expect(v4.files.containsKey('loc/LOC1'), isTrue);
    expect(utf8.decode(v3.files['meta.json']!), '{"moved":"v4"}');
    expect(utf8.decode(v3.files['devices/tomb/head-1.json']!), 'old tomb');
    final Map<String, Object?> root = host.last('location_root');
    expect(root['has4'], isTrue);
    expect(root['has3'], isFalse);
    // plan：listing 去掉 `devices/` 前缀，带 loc 标记与位置名。
    final Map<String, Object?> plan = host.last('plan');
    expect(plan['loc'], 'LOC1');
    expect(plan['location'], 'L');
    expect(
      (plan['listing']! as Map)['dev-b'],
      containsAll(<String>[
        'head-000000000002-bbbbbbbb.json',
        'seg-000000000001-000000000002-aaaaaaaa.bin',
      ]),
    );
    // 收：预算 1 字节 = 每段一批；这一批报了分叉 → 收尾一次。
    expect(host.ingested.length, 2);
    // 收段带的位置与 plan 的同值。
    expect(host.ingestLocations, <String?>['L', 'L']);
    expect(host.finishes, 1);
    expect(host.begins, host.ends);
    expect(r.applied, 2);
    expect(r.fork, isTrue);
    // 发：两批都写上了，第一批带本机目录清单（作者自检），第二批不带。
    expect(
      v4.files.containsKey(
        'devices/dev-a/seg-000000000001-000000000005-cccccccc.bin',
      ),
      isTrue,
    );
    expect(
      v4.files.containsKey(
        'devices/dev-a/seg-000000000006-000000000007-dddddddd.bin',
      ),
      isTrue,
    );
    final List<Map<String, Object?>> outs = host.requests
        .where((Map<String, Object?> q) => q['op'] == 'outbox')
        .toList();
    expect(outs.first['present'], <String>['head-000000000001-old.json']);
    expect(outs.last.containsKey('present'), isFalse);
    expect(outs.first['progress'], startsWith('L'));
    expect(r.uploaded, 2);
    // head 写上、带位置与 loc；旧 head 删掉。
    final Map<String, Object?> head = host.last('head');
    expect(head['location'], 'L');
    expect(head['loc'], 'LOC1');
    expect(head['seal'], '');
    expect(
      v4.files.containsKey('devices/dev-a/head-000000000003-dddddddd.json'),
      isTrue,
    );
    expect(
      v4.files.containsKey('devices/dev-a/head-000000000001-old.json'),
      isFalse,
    );
  });

  test('outbox_ack 被拒：不写 head', () async {
    final _FakeHost host = _FakeHost(happy(accepted: false));
    final SrsSync2Report r = await run(host);
    expect(r.error, kSrsSync2OutboxRecut);
    expect(host.ops(), isNot(contains('head')));
  });

  test('根要更新的版本 / 认不得：什么都不写、不读 head', () async {
    for (final (String state, bool upgrade) in <(String, bool)>[
      (kSrs4RootNeedsUpgrade, true),
      ('refused', false),
    ]) {
      final _FakeHost host = _FakeHost(<String, List<SrsSync2Result>>{
        'location_root': <SrsSync2Result>[
          _r(<String, Object?>{'state': state, 'error': 'x'}),
        ],
      });
      final SrsSync2Report r = await run(host);
      expect(r.needsUpgrade, upgrade, reason: state);
      if (!upgrade) expect(r.error, startsWith(kSrs4LocationRefused));
      expect(host.ops(), isNot(contains('plan')));
      expect(v4.files, isEmpty);
      expect(v3.files, isEmpty);
    }
  });

  test('plan 要求更新的读者：不收、不发', () async {
    final Map<String, List<SrsSync2Result>> replies = happy();
    replies['plan'] = <SrsSync2Result>[
      _r(<String, Object?>{'fetch': <Object?>[], 'needsUpgrade': true}),
    ];
    final _FakeHost host = _FakeHost(replies);
    final SrsSync2Report r = await run(host);
    expect(r.needsUpgrade, isTrue);
    expect(host.ops(), isNot(contains('outbox')));
    expect(host.ingested, isEmpty);
  });

  test('head 没变：上次那份还在就不写，不在了就不带 skipUnchangedMs 再要一次', () async {
    final Map<String, List<SrsSync2Result>> replies = happy();
    replies['plan'] = <SrsSync2Result>[
      _r(<String, Object?>{'fetch': <Object?>[], 'needsUpgrade': false}),
    ];
    replies['outbox'] = <SrsSync2Result>[
      _r(<String, Object?>{'segments': <Object?>[], 'upto': 7, 'more': false}),
    ];
    replies['head'] = <SrsSync2Result>[
      _r(<String, Object?>{
        'unchanged': true,
        'path': 'devices/dev-a/head-000000000003-dddddddd.json',
        'gen': 3,
      }),
      _r(
        <String, Object?>{'unchanged': false, 'gen': 4},
        <(String, Uint8List)>[
          ('devices/dev-a/head-000000000004-dddddddd.json', _b('h4')),
        ],
      ),
    ];
    final _FakeHost host = _FakeHost(replies);
    await run(host);
    final List<Map<String, Object?>> heads = host.requests
        .where((Map<String, Object?> q) => q['op'] == 'head')
        .toList();
    expect(heads.length, 2);
    expect(heads.first.containsKey('skipUnchangedMs'), isTrue);
    expect(heads.last.containsKey('skipUnchangedMs'), isFalse);
    expect(
      v4.files.containsKey('devices/dev-a/head-000000000004-dddddddd.json'),
      isTrue,
    );
    // 那份还在：只问一次。
    final Map<String, List<SrsSync2Result>> again = happy();
    again['plan'] = replies['plan']!;
    again['outbox'] = <SrsSync2Result>[
      _r(<String, Object?>{'segments': <Object?>[], 'upto': 7, 'more': false}),
    ];
    again['head'] = <SrsSync2Result>[
      _r(<String, Object?>{
        'unchanged': true,
        'path': 'devices/dev-a/head-000000000004-dddddddd.json',
        'gen': 4,
      }),
    ];
    final _FakeHost host2 = _FakeHost(again);
    await run(host2);
    expect(host2.ops().where((String o) => o == 'head').length, 1);
  });

  test('轮次时钟：plan 与见到密封时记的时刻都取注入的 nowMs，不取墙钟', () async {
    final Map<String, List<SrsSync2Result>> replies = happy();
    replies['plan'] = <SrsSync2Result>[
      _r(<String, Object?>{
        'fetch': <Object?>[
          <String, Object?>{
            'device': 'dev-b',
            'own': false,
            'files': <String>[
              'devices/dev-b/seg-000000000001-000000000002-aaaaaaaa.bin',
            ],
          },
        ],
        'needsUpgrade': false,
        'sealed': true,
      }),
    ];
    v4.files['meta.json'] = _b('{"fmt":"m4"}');
    v4.files['devices/dev-b/seg-000000000001-000000000002-aaaaaaaa.bin'] = _b(
      'x1',
    );
    final _FakeHost host = _FakeHost(replies);
    await run(host);
    expect(host.last('plan')['now'], 1000);
    final List<Map<String, Object?>> seals = host.requests
        .where((Map<String, Object?> q) => q['op'] == 'location_seal')
        .toList();
    // 一次是 plan 报了 `sealed`，一次是按明文读到段时看段头。
    expect(seals.length, 2);
    for (final Map<String, Object?> s in seals) {
      expect(s['now'], 1000);
    }
  });

  test(
    '新集合：旧根没有 meta.json 时 location_root 收到 has3 = false，围栏与墓碑由它写；媒体根照内核记',
    () async {
      final Map<String, List<SrsSync2Result>> replies = happy();
      replies['location_root'] = <SrsSync2Result>[
        _r(
          <String, Object?>{
            'state': kSrs4RootOk,
            'loc': 'LOC1',
            'media': kSrs4Root,
            'ensure': <String>['v3/devices/tomb/head-1.json'],
          },
          <(String, Uint8List)>[
            ('v4/meta.json', _b('{"fmt":"m4","media":"v4"}')),
            ('v4/loc/LOC1', Uint8List(0)),
            ('v3/meta.json', _b('{"moved":"v4"}')),
            ('v3/devices/tomb/head-1.json', _b('tomb')),
          ],
        ),
      ];
      final _FakeHost host = _FakeHost(replies);
      SrsLocationRoot? seen;
      final SrsSync2Report r = await srsSync2Round(
        host: host,
        location: v4,
        oldRoot: v3,
        locationId: 'L',
        nowMs: () => 1000,
        archive: true,
        onLocationRoot: (SrsLocationRoot root) => seen = root,
      );
      final Map<String, Object?> root = host.last('location_root');
      expect(root['has3'], isFalse);
      expect(root['has4'], isFalse);
      expect(utf8.decode(v3.files['meta.json']!), '{"moved":"v4"}');
      expect(utf8.decode(v3.files['devices/tomb/head-1.json']!), 'tomb');
      expect(r.mediaRoot, kSrs4Root);
      expect(seen?.media, kSrs4Root);
      expect(seen?.loc, 'LOC1');
      // 归档：标记交给内核（删什么只由内核定）。
      expect(host.last('obsolete')['archive'], isTrue);
    },
  );

  test(
    '旧根接手：学公钥的 head 先于段；按字节分批收、每批带这一轮的 fp；最后不带段带 settle 与清单；包在收段会话里',
    () async {
      v3.files['devices/old/head-000000000001-aa.json'] = _b('h-old');
      v3.files['devices/old/seg-000000000001-000000000002-aa.bin'] = _b('s1');
      v3.files['devices/old/seg-000000000003-000000000004-bb.bin'] = _b('s2');
      final Map<String, List<SrsSync2Result>> replies = happy()
        ..['oldroot_scan'] = <SrsSync2Result>[
          _r(<String, Object?>{
            'changed': true,
            'fp':
                'abababababababababababababababababababababababababababababababab',
            'heads': <String>['devices/old/head-000000000001-aa.json'],
            'fetch': <String>[
              'devices/old/seg-000000000001-000000000002-aa.bin',
              'devices/old/seg-000000000003-000000000004-bb.bin',
            ],
          }),
        ]
        ..['oldroot_ingest'] = <SrsSync2Result>[
          _r(<String, Object?>{'applied': 2, 'rest': 1, 'errors': <String>[]}),
          _r(<String, Object?>{
            'applied': 0,
            'rest': 1,
            'errors': <String>['seg-3-4: Deferred'],
          }),
          _r(<String, Object?>{
            'applied': 0,
            'rest': 0,
            'recorded': false,
            'errors': <String>[],
          }),
        ];
      final _FakeHost host = _FakeHost(replies);
      final SrsSync2Report r = await run(host);
      expect(r.error, isNull);
      final List<Map<String, Object?>> ings = host.requests
          .where((Map<String, Object?> q) => q['op'] == 'oldroot_ingest')
          .toList();
      // 预算 1 字节：两段各一批（不带 settle），之后不带段的收尾那一次带 settle 与整份清单；不再重扫。
      expect(host.ops().where((String o) => o == 'oldroot_scan').length, 1);
      expect(ings.length, 3);
      expect(ings[0]['heads'], 1);
      expect(ings[0]['paths'], <String>[
        'devices/old/seg-000000000001-000000000002-aa.bin',
      ]);
      expect(ings[0].containsKey('settle'), isFalse);
      expect(ings[1]['heads'], 0);
      expect(ings[1]['paths'], <String>[
        'devices/old/seg-000000000003-000000000004-bb.bin',
      ]);
      expect(ings[2]['settle'], isTrue);
      expect(ings[2]['paths'], isEmpty);
      expect(ings[2]['heads'], 0);
      // 整份旧根清单（三个旧设备文件 + 这一轮根立的墓碑 head）。
      expect(
        <Object?>[
          for (final Object? e in ings[2]['listing']! as List)
            (e! as Map)['path'],
        ],
        containsAll(<String>[
          'devices/old/head-000000000001-aa.json',
          'devices/old/seg-000000000001-000000000002-aa.bin',
          'devices/old/seg-000000000003-000000000004-bb.bin',
        ]),
      );
      for (final Map<String, Object?> q in ings) {
        expect(q['location'], 'L');
        expect(
          q['fp'],
          'abababababababababababababababababababababababababababababababab',
          reason: '每个事务都带这一轮的指纹',
        );
        expect(q['maxItems'], kSrsSync4OldRootSliceItems);
      }
      expect(r.applied, 2, reason: '新根的段不在位置上，只有旧根落的');
      expect(r.errors, contains('old root: seg-3-4: Deferred'));
      // 收新根一段会话、旧根一段会话。
      expect(host.begins, 2);
      expect(host.ends, 2);
      // 旧根接手在发件之前。
      expect(
        host.ops().indexOf('oldroot_ingest'),
        lessThan(host.ops().indexOf('outbox')),
      );
    },
  );

  test(
    '旧根接手按 maxItems 切片：交完的段从队首去掉、剩下的下一个事务再交；drainMore 不带段接着交；收尾那一次也按片',
    () async {
      for (final String n in <String>['1', '2', '3']) {
        v3.files['devices/old/seg-00000000000$n-00000000000$n-aa.bin'] = _b(n);
      }
      final List<String> segs = <String>[
        for (final String n in <String>['1', '2', '3'])
          'devices/old/seg-00000000000$n-00000000000$n-aa.bin',
      ];
      final _FakeHost host = _FakeHost(<String, List<SrsSync2Result>>{
        'oldroot_scan': <SrsSync2Result>[
          _r(<String, Object?>{
            'changed': true,
            'fp':
                'abababababababababababababababababababababababababababababababab',
            'heads': <String>[],
            'fetch': segs,
          }),
        ],
        'oldroot_ingest': <SrsSync2Result>[
          _r(<String, Object?>{'applied': 5, 'rest': 1, 'spent': 5}),
          _r(<String, Object?>{
            'applied': 3,
            'rest': 2,
            'spent': 3,
            'drainMore': true,
          }),
          _r(<String, Object?>{'applied': 2, 'rest': 0, 'spent': 2}),
          // 收尾那一次也可能要接着投。
          _r(<String, Object?>{
            'applied': 1,
            'rest': 0,
            'spent': 1,
            'drainMore': true,
          }),
          _r(<String, Object?>{'applied': 0, 'rest': 0, 'recorded': true}),
        ],
      });
      final SrsSync2Report report = SrsSync2Report();
      await srsSync4TakeOldRoot(
        host: host,
        oldRoot: v3,
        locationId: 'L',
        keyHex: null,
        report: report,
        nowMs: () => 1,
        sliceItems: 4,
      );
      final List<Map<String, Object?>> ings = host.requests
          .where((Map<String, Object?> q) => q['op'] == 'oldroot_ingest')
          .toList();
      expect(
        <Object?>[for (final Map<String, Object?> q in ings) q['paths']],
        <Object?>[segs, segs.sublist(1), <String>[], <String>[], <String>[]],
      );
      expect(
        <Object?>[
          for (final Map<String, Object?> q in ings) q['settle'] == true,
        ],
        <bool>[false, false, false, true, true],
      );
      expect(
        ings.every((Map<String, Object?> q) => q['maxItems'] == 4),
        isTrue,
      );
      expect(report.applied, 11);
      expect(host.begins, 1);
      expect(host.ends, 1);
    },
  );

  test('旧根接手的一片既没交完段也没做新工作：契约坏了，抛错不原地打转', () async {
    v3.files['devices/old/seg-000000000001-000000000001-aa.bin'] = _b('1');
    final _FakeHost host = _FakeHost(<String, List<SrsSync2Result>>{
      'oldroot_scan': <SrsSync2Result>[
        _r(<String, Object?>{
          'changed': true,
          'fp':
              'abababababababababababababababababababababababababababababababab',
          'heads': <String>[],
          'fetch': <String>['devices/old/seg-000000000001-000000000001-aa.bin'],
        }),
      ],
      'oldroot_ingest': <SrsSync2Result>[
        _r(<String, Object?>{'applied': 0, 'rest': 0, 'spent': 0}),
      ],
    });
    await expectLater(
      srsSync4TakeOldRoot(
        host: host,
        oldRoot: v3,
        locationId: 'L',
        keyHex: null,
        report: SrsSync2Report(),
        nowMs: () => 1,
      ),
      throwsStateError,
    );
    expect(host.ends, 1, reason: '收段会话照样收尾');
  });

  test('承袭上传：读位置上相关的承袭段 → 打包写上 → 记指纹；在本机原生段之前', () async {
    v4.files['meta.json'] = _b('{"fmt":"m4"}');
    v4.files['devices/dev-c/hrt-x.bin'] = _b('their heritage');
    final Map<String, List<SrsSync2Result>> replies = happy()
      ..['heritage_plan'] = <SrsSync2Result>[
        _r(<String, Object?>{
          'skip': false,
          'read': <String>['devices/dev-c/hrt-x.bin'],
        }),
      ]
      ..['heritage_outbox'] = <SrsSync2Result>[
        _r(
          <String, Object?>{
            'put': 1,
            'blocked': <Object?>[],
            'keptForked': <Object?>[],
            'errors': <String>[],
          },
          <(String, Uint8List)>[('devices/dev-a/hrt-mine.bin', _b('mine'))],
        ),
      ];
    final _FakeHost host = _FakeHost(replies);
    final SrsSync2Report r = await run(host);
    expect(r.error, isNull);
    expect(utf8.decode(v4.files['devices/dev-a/hrt-mine.bin']!), 'mine');
    final Map<String, Object?> out = host.last('heritage_outbox');
    expect(out['paths'], <String>['devices/dev-c/hrt-x.bin']);
    // 记指纹时的清单里有刚写上的那份。
    final Map<String, Object?> ack = host.last('heritage_ack');
    expect((ack['listing']! as Map)['dev-a'], contains('hrt-mine.bin'));
    final List<String> ops = host.ops();
    expect(ops.indexOf('heritage_ack'), lessThan(ops.indexOf('outbox')));
    expect(r.uploaded, 1 + 2);
  });

  test('承袭上传有传不上去的地方：报进 errors、不记指纹', () async {
    final Map<String, List<SrsSync2Result>> replies = happy()
      ..['heritage_plan'] = <SrsSync2Result>[
        _r(<String, Object?>{'skip': false, 'read': <String>[]}),
      ]
      ..['heritage_outbox'] = <SrsSync2Result>[
        _r(<String, Object?>{
          'put': 0,
          'blocked': <Object?>[
            <Object?>['dev-old', 3, 9],
          ],
          'keptForked': <Object?>[],
          'errors': <String>[],
        }),
      ];
    final _FakeHost host = _FakeHost(replies);
    final SrsSync2Report r = await run(host);
    expect(host.ops(), isNot(contains('heritage_ack')));
    expect(r.errors.any((String e) => e.contains('dev-old')), isTrue);
  });

  test('承袭上传不替待确认作者传：回包的 unvouched / pending 进报告，指纹没变（skip）时也带', () async {
    final _FakeHost skipped = _FakeHost(
      happy()
        ..['heritage_plan'] = <SrsSync2Result>[
          _r(<String, Object?>{
            'skip': true,
            'unvouched': <String>['dev-old', 'dev-rejected'],
            'pending': <String>['dev-old'],
          }),
        ],
    );
    final SrsSync2Report r = await run(skipped);
    expect(r.error, isNull);
    expect(r.heritageUnvouched, <String>['dev-old', 'dev-rejected']);
    expect(r.heritagePending, <String>['dev-old'], reason: '已拒绝的不催用户确认');
    expect(skipped.ops(), isNot(contains('heritage_outbox')));

    // 确认之后内核不再列它：报告里是空表（走到了这一步），不是 null。
    final SrsSync2Report after = await run(
      _FakeHost(
        happy()
          ..['heritage_plan'] = <SrsSync2Result>[
            _r(<String, Object?>{
              'skip': true,
              'unvouched': <String>[],
              'pending': <String>[],
            }),
          ],
      ),
    );
    expect(after.heritageUnvouched, isEmpty);
    expect(after.heritagePending, isEmpty);
  });

  test('媒体清单：收别的设备的（读不到的标 present=false）；head 之后发本机的、写上再确认', () async {
    v4.files['meta.json'] = _b('{"fmt":"m4"}');
    v4.files['devices/dev-b/mf-000000000001-aa.bin'] = _b('mf-b');
    final Map<String, List<SrsSync2Result>> replies = happy()
      ..['media_manifests'] = <SrsSync2Result>[
        _r(<String, Object?>{
          'fetch': <String>[
            'devices/dev-b/mf-000000000001-aa.bin',
            'devices/dev-b/mf-000000000002-bb.bin',
          ],
        }),
      ]
      ..['media_manifest_ingest'] = <SrsSync2Result>[
        _r(<String, Object?>{'ingested': 1, 'errors': <String>[]}),
      ]
      ..['media_manifest_build'] = <SrsSync2Result>[
        _r(
          <String, Object?>{
            'built': true,
            'path': 'devices/dev-a/mf-000000000004-cc.bin',
            'gen': 4,
          },
          <(String, Uint8List)>[
            ('devices/dev-a/mf-000000000004-cc.bin', _b('mf-a')),
          ],
        ),
      ];
    v4.files['devices/dev-a/mf-000000000003-zz.bin'] = _b('mine before');
    final _FakeHost host = _FakeHost(replies);
    final SrsSync2Report r = await run(host);
    expect(r.error, isNull);
    final Map<String, Object?> ing = host.last('media_manifest_ingest');
    expect(ing['location'], 'L');
    expect(ing['present'], <bool>[true, false]);
    expect(host.last('media_manifest_build')['ownGens'], <int>[3]);
    expect(host.last('media_manifest_build')['loc'], 'LOC1');
    expect(
      utf8.decode(v4.files['devices/dev-a/mf-000000000004-cc.bin']!),
      'mf-a',
    );
    final List<String> ops = host.ops();
    // 本机清单发完才轮到转发（一轮的最后一步）。
    expect(
      ops.indexOf('media_manifest_published'),
      lessThan(ops.indexOf('relay_outbox')),
    );
    expect(ops.last, 'relay_ack');
    expect(
      ops.indexOf('media_manifest_ingest'),
      lessThan(ops.indexOf('outbox')),
    );
  });

  test('转发：一批写完再确认、要下一批；被取代的旧件删掉后报回 deleted；归档位置不删也报回', () async {
    for (final bool archive in <bool>[false, true]) {
      v4.files['meta.json'] = _b('{"fmt":"m4"}');
      v4.files['devices/dev-x/rhd-000000000001-old.json'] = _b('old rhd');
      final Map<String, List<SrsSync2Result>> replies = happy()
        ..['relay_outbox'] = <SrsSync2Result>[
          _r(
            <String, Object?>{
              'files': <String>[
                'devices/dev-x/rly-000000000001-000000000002-aa.bin',
              ],
              'more': true,
            },
            <(String, Uint8List)>[
              (
                'devices/dev-x/rly-000000000001-000000000002-aa.bin',
                _b('piece'),
              ),
            ],
          ),
          _r(
            <String, Object?>{
              'files': <String>['devices/dev-x/rhd-000000000002-aa.json'],
              'more': false,
            },
            <(String, Uint8List)>[
              ('devices/dev-x/rhd-000000000002-aa.json', _b('new rhd')),
            ],
          ),
        ]
        ..['relay_ack'] = <SrsSync2Result>[
          _r(<String, Object?>{'delete': <String>[]}),
          _r(<String, Object?>{
            'delete': <String>['devices/dev-x/rhd-000000000001-old.json'],
          }),
          _r(<String, Object?>{'delete': <String>[]}),
        ];
      final _FakeHost host = _FakeHost(replies);
      final SrsSync2Report r = await srsSync2Round(
        host: host,
        location: v4,
        oldRoot: v3,
        locationId: 'L',
        nowMs: () => 1000,
        archive: archive,
      );
      expect(r.error, isNull);
      expect(r.relayed, 2);
      expect(
        utf8.decode(
          v4.files['devices/dev-x/rly-000000000001-000000000002-aa.bin']!,
        ),
        'piece',
      );
      final List<Map<String, Object?>> acks = <Map<String, Object?>>[
        for (final Map<String, Object?> q in host.requests)
          if (q['op'] == 'relay_ack') q,
      ];
      expect(acks, hasLength(3));
      expect(acks[0]['paths'], <String>[
        'devices/dev-x/rly-000000000001-000000000002-aa.bin',
      ]);
      expect(acks[1]['paths'], <String>[
        'devices/dev-x/rhd-000000000002-aa.json',
      ]);
      expect(acks[2]['deleted'], <String>[
        'devices/dev-x/rhd-000000000001-old.json',
      ]);
      expect(
        acks.every((Map<String, Object?> q) => q['location'] == 'L'),
        isTrue,
      );
      expect(
        v4.files.containsKey('devices/dev-x/rhd-000000000001-old.json'),
        archive,
        reason: 'an archive location keeps the superseded relay head',
      );
    }
  });

  test('旧身份目录：obsolete 报的 former 逐个交 obsolete_former，给的路径照删', () async {
    v4.files['meta.json'] = _b('{"fmt":"m4"}');
    v4.files['devices/dev-old/head-000000000001-aa.json'] = _b('h1');
    v4.files['devices/dev-old/seg-000000000001-000000000002-aa.bin'] = _b('s');
    final Map<String, List<SrsSync2Result>> replies = happy()
      ..['obsolete'] = <SrsSync2Result>[
        _r(<String, Object?>{
          'delete': <String>[],
          'former': <String>['dev-old'],
        }),
      ]
      ..['obsolete_former'] = <SrsSync2Result>[
        _r(<String, Object?>{
          'delete': <String>['devices/dev-old/head-000000000001-aa.json'],
        }),
      ];
    final _FakeHost host = _FakeHost(replies);
    await run(host);
    final Map<String, Object?> f = host.last('obsolete_former');
    expect(f['device'], 'dev-old');
    expect(
      f['present'],
      containsAll(<String>[
        'head-000000000001-aa.json',
        'seg-000000000001-000000000002-aa.bin',
      ]),
    );
    expect(
      v4.files.containsKey('devices/dev-old/head-000000000001-aa.json'),
      isFalse,
    );
    expect(
      v4.files.containsKey(
        'devices/dev-old/seg-000000000001-000000000002-aa.bin',
      ),
      isTrue,
    );
  });

  test('只有协议 1 旧根：带 has2，拒绝时把机读码放进错误', () async {
    final SrsMemoryLocationStore v2 = SrsMemoryLocationStore();
    v2.files['meta.json'] = _b('{"v":1}');
    final _FakeHost host = _FakeHost(<String, List<SrsSync2Result>>{
      'location_root': <SrsSync2Result>[
        _r(<String, Object?>{
          'state': 'refused',
          'code': 'srs_location_protocol1_root',
          'error': 'protocol 1 layout',
        }),
      ],
    });
    final SrsSync2Report r = await srsSync2Round(
      host: host,
      location: v4,
      oldRoot: v3,
      protocol1Root: v2,
      locationId: 'L',
      nowMs: () => 1000,
    );
    expect(host.last('location_root')['has2'], isTrue);
    expect(r.error, kSrsLocationProtocol1Root);
    expect(host.ops(), isNot(contains('plan')));
    expect(v4.files, isEmpty);
    expect(v3.files, isEmpty);
  });

  test('只走根这一步（只做媒体的位置）：没过就返回 null、什么都不写', () async {
    final _FakeHost host = _FakeHost(<String, List<SrsSync2Result>>{
      'location_root': <SrsSync2Result>[
        _r(<String, Object?>{'state': kSrs4RootNeedsUpgrade, 'error': 'x'}),
      ],
    });
    final SrsSync2Report report = SrsSync2Report();
    final SrsLocationRoot? r = await srsSync4LocationRoot(
      host: host,
      location: v4,
      oldRoot: v3,
      locationId: 'L',
      nowMs: () => 1000,
      collection: 'c',
      report: report,
    );
    expect(r, isNull);
    expect(report.needsUpgrade, isTrue);
    expect(report.mediaRoot, isNull);
    expect(v4.files, isEmpty);
    expect(v3.files, isEmpty);
  });
}
