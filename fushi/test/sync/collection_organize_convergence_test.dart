import 'dart:convert';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_merge.dart';
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';

/// AI 整理库 spec §8：多端各自整理、任意顺序同步，最终每台设备的合集逐项相同；
/// 用户合集永不被并掉；来源只升不降；拒绝跨端生效；旧对端丢字段不清身份。
void main() {
  group('planOrganizeConvergence（纯函数）', () {
    ConvergenceCollection c(
      int id,
      String name, {
      CollectionOrigin origin = CollectionOrigin.ai,
      String? key,
      Set<String> aliases = const <String>{},
      required List<String> members,
      String kind = 'epub',
    }) => ConvergenceCollection(
      id: id,
      name: name,
      collectionType: 'collection',
      origin: origin,
      organizeKey: key,
      organizeAliases: aliases,
      memberWireKeys: <String>{for (final String m in members) '$kind\u0000$m'},
    );

    test('同键两个 AI 合集合并，胜方与输入顺序无关', () {
      final List<ConvergenceCollection> input = <ConvergenceCollection>[
        c(1, '凉宫春日系列', key: 't:books:すずみやはるひ', members: <String>['a']),
        c(2, '涼宮ハルヒ', key: 't:books:すずみやはるひ', members: <String>['b']),
      ];
      final List<ConvergenceMerge> p1 = planOrganizeConvergence(input);
      final List<ConvergenceMerge> p2 = planOrganizeConvergence(
        input.reversed.toList(),
      );
      expect(p1, hasLength(1));
      // 同键时按名字字典序：「凉」(U+51C9) < 「涼」(U+6DBC)。
      expect(p1.single.targetId, 1);
      expect(p1.single.sourceIds, <int>[2]);
      expect(p2.single.targetId, p1.single.targetId);
    });

    test('外部 id 键优先当胜方', () {
      final List<ConvergenceMerge> plan = planOrganizeConvergence(
        <ConvergenceCollection>[
          c(
            1,
            'A',
            key: 't:video:ふりーれん',
            kind: 'video',
            members: <String>['x'],
          ),
          c(
            2,
            'B',
            key: 'anilist:154587',
            aliases: <String>{'t:video:ふりーれん'},
            kind: 'video',
            members: <String>['y'],
          ),
        ],
      );
      expect(plan.single.targetId, 2);
    });

    test('键在对方别名里也算同一个', () {
      final List<ConvergenceMerge> plan = planOrganizeConvergence(
        <ConvergenceCollection>[
          c(1, 'A', key: 'k1', aliases: <String>{'k2'}, members: <String>['a']),
          c(2, 'B', key: 'k2', members: <String>['b']),
        ],
      );
      expect(plan.single.sourceIds, <int>[2]);
    });

    test('成员重叠过半的两个整理器合集合并；用户合集不因重叠被并', () {
      final List<ConvergenceMerge> plan = planOrganizeConvergence(
        <ConvergenceCollection>[
          c(1, 'A', key: 'k1', members: <String>['a', 'b', 'c']),
          c(2, 'B', key: 'k2', members: <String>['b', 'c']),
          c(
            3,
            'U',
            origin: CollectionOrigin.user,
            members: <String>['a', 'b', 'c'],
          ),
        ],
      );
      expect(plan, hasLength(1));
      expect(plan.single.targetId, 1);
      expect(plan.single.sourceIds, <int>[2]);
    });

    test('同键的用户合集当胜方，自己永不当败方', () {
      final List<ConvergenceMerge> plan = planOrganizeConvergence(
        <ConvergenceCollection>[
          c(1, 'A', key: 'k', members: <String>['a']),
          c(
            2,
            'U1',
            origin: CollectionOrigin.user,
            key: 'k',
            members: <String>['b'],
          ),
          c(
            3,
            'U2',
            origin: CollectionOrigin.user,
            key: 'k',
            members: <String>['c'],
          ),
        ],
      );
      expect(plan.single.targetId, 2);
      expect(plan.single.sourceIds, <int>[1]);
    });

    test('跨域同键不合并；目录合集不参与', () {
      expect(
        planOrganizeConvergence(<ConvergenceCollection>[
          c(1, 'A', key: 'k', members: <String>['a']),
          c(2, 'B', key: 'k', kind: 'video', members: <String>['v']),
          c(
            3,
            'F',
            origin: CollectionOrigin.folder,
            key: 'k',
            members: <String>['a'],
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('多端收敛（真实内存库 + 共享清单）', () {
    late List<_Device> devices;
    late _Cloud cloud;

    setUp(() {
      cloud = _Cloud();
      devices = <_Device>[];
    });
    tearDown(() async {
      for (final _Device d in devices) {
        await d.db.close();
      }
    });

    _Device device() {
      final _Device d = _Device(
        FushiDatabase.forTesting(NativeDatabase.memory()),
      );
      devices.add(d);
      return d;
    }

    Future<void> tick() =>
        Future<void>.delayed(const Duration(milliseconds: 3));

    Future<int> aiCollection(
      _Device d,
      String name,
      String key,
      List<String> members,
    ) async {
      final int id = await d.db.createMediaCollection(
        name,
        origin: CollectionOrigin.ai,
        organizeKey: key,
      );
      for (final String m in members) {
        await d.db.addToCollection(id, MediaKind.video, m, userIntent: false);
      }
      await convergeOrganizedCollections(d.db);
      return id;
    }

    Future<void> settle(Random random, {int maxRounds = 30}) async {
      int quiet = 0;
      for (int round = 0; round < maxRounds && quiet < 2; round++) {
        final List<_Device> order = List<_Device>.of(devices)..shuffle(random);
        int changed = 0;
        for (final _Device d in order) {
          await tick();
          changed += await d.sync(cloud);
        }
        quiet = changed == 0 ? quiet + 1 : 0;
      }
      expect(quiet, 2, reason: 'sync did not quiesce');
    }

    test('两端各自给同一系列起了不同名字 → 同步后合成一个', () async {
      final _Device a = device();
      final _Device b = device();
      await aiCollection(a, '凉宫春日系列', 't:video:すずみや', <String>['v1', 'v2']);
      await aiCollection(b, 'Haruhi', 't:video:すずみや', <String>['v3']);
      await settle(Random(1));
      for (final _Device d in devices) {
        final List<_Snapshot> alive = await _snapshot(d.db);
        expect(alive, hasLength(1));
        expect(alive.single.name, 'Haruhi'); // 'H' < '凉'
        expect(alive.single.members, <String>{
          'video|v1',
          'video|v2',
          'video|v3',
        });
        expect(alive.single.origin, 'ai');
      }
    });

    test('随机多端、随机键冲突、随机同步顺序：最终逐项一致且每键至多一个合集', () async {
      // 200 个种子覆盖到了曾经炸过的 0（同名不同组）与 139（部分可见下各端选出不同胜方）。
      for (int seed = 0; seed < 200; seed++) {
        for (final _Device d in devices) {
          await d.db.close();
        }
        devices.clear();
        cloud = _Cloud();
        final Random random = Random(seed);
        final int deviceCount = 2 + random.nextInt(3);
        for (int i = 0; i < deviceCount; i++) {
          device();
        }
        const List<String> keys = <String>[
          't:video:a',
          't:video:b',
          'anilist:7',
        ];
        final Set<String> everAdded = <String>{};
        for (final _Device d in devices) {
          final int n = 1 + random.nextInt(3);
          for (int i = 0; i < n; i++) {
            final String key = keys[random.nextInt(keys.length)];
            final List<String> members = <String>[
              for (int m = 0; m < 1 + random.nextInt(3); m++)
                'v${random.nextInt(8)}',
            ];
            everAdded.addAll(<String>[
              for (final String m in members) 'video|$m',
            ]);
            await aiCollection(d, 'name-${random.nextInt(4)}', key, members);
          }
          // 中途插一轮部分同步，制造交错。
          if (random.nextBool()) await d.sync(cloud);
        }
        await settle(random);
        final List<_Snapshot> first = await _snapshot(devices.first.db);
        for (final _Device d in devices.skip(1)) {
          expect(await _snapshot(d.db), first, reason: 'seed $seed diverged');
        }
        // 没有人移出过成员：收敛只能合并，不能把任何一次归组弄丢。
        expect(
          <String>{for (final _Snapshot s in first) ...s.members},
          everAdded,
          reason: 'seed $seed lost grouped members: $first',
        );
        final Map<String, int> byKey = <String, int>{};
        for (final _Snapshot s in first) {
          if (s.key != null) byKey[s.key!] = (byKey[s.key!] ?? 0) + 1;
        }
        expect(
          byKey.values.where((int n) => n > 1),
          isEmpty,
          reason: 'seed $seed: a key is held by >1 collection: $first',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('用户在一端接手 → 来源跨端升为 user，收敛不再并它', () async {
      final _Device a = device();
      final _Device b = device();
      final int id = await aiCollection(a, 'S', 'k', <String>['v1']);
      await settle(Random(2));
      final MediaCollectionRow onB = (await b.db.getMediaCollectionByNaturalKey(
        'S',
        'collection',
      ))!;
      expect(onB.origin, 'ai');
      await b.db.addToCollection(onB.id, MediaKind.video, 'v9');
      expect((await b.db.getMediaCollectionById(onB.id))!.origin, 'user');
      await settle(Random(3));
      expect((await a.db.getMediaCollectionById(id))!.origin, 'user');
      // A 端 AI 又为同键建了一个：并进用户合集，用户合集不动。
      await aiCollection(a, 'S2', 'k', <String>['v5']);
      await settle(Random(4));
      for (final _Device d in devices) {
        final List<_Snapshot> alive = await _snapshot(d.db);
        expect(alive.map((_Snapshot s) => s.name), <String>['S']);
        expect(alive.single.members, contains('video|v5'));
        expect(alive.single.origin, 'user');
      }
    });

    test('一端用户接手的同时另一端把它当整理器合集并掉 → 用户合集保住，吸收者不被吞', () async {
      final _Device a = device();
      final _Device b = device();
      await aiCollection(a, 'L', 'k-l', <String>['v1', 'v2']);
      await aiCollection(a, 'W', 'k-w', <String>['v9']);
      await settle(Random(7));
      // A：用户往 L 里加 v3（接手为 user），还没同步。
      final MediaCollectionRow lOnA = (await a.db
          .getMediaCollectionByNaturalKey('L', 'collection'))!;
      await a.db.addToCollection(lOnA.id, MediaKind.video, 'v3');
      // B：同时按旧状态把 L 并进 W。
      await mergeMediaCollectionsInto(
        b.db,
        targetId: (await b.db.getMediaCollectionByNaturalKey(
          'W',
          'collection',
        ))!.id,
        sourceIds: <int>[
          (await b.db.getMediaCollectionByNaturalKey('L', 'collection'))!.id,
        ],
        userIntent: false,
      );
      await settle(Random(8));
      for (final _Device d in devices) {
        final Map<String, _Snapshot> byName = <String, _Snapshot>{
          for (final _Snapshot s in await _snapshot(d.db)) s.name: s,
        };
        expect(byName['L']?.origin, 'user');
        expect(byName['L']!.members, contains('video|v3'));
        expect(byName['W'], isNotNull, reason: '吸收者不该因为别名里有 L 的键被并进 L');
      }
    });

    test('删除 AI 合集 = 拒绝，跨端可见；被合并掉的不算拒绝', () async {
      final _Device a = device();
      final _Device b = device();
      final int id = await aiCollection(a, 'X', 'k-x', <String>['v1']);
      await aiCollection(a, 'Y1', 'k-y', <String>['v2']);
      await aiCollection(b, 'Y2', 'k-y2', <String>['v2', 'v3']);
      await settle(Random(5));
      await a.db.deleteMediaCollection(id);
      await settle(Random(6));
      for (final _Device d in devices) {
        expect(await d.db.getRejectedOrganizeKeys(), <String>{'k-x'});
      }
    });

    test('旧版对端丢掉整理字段回传清单，新端的来源与键不被清掉', () async {
      final _Device a = device();
      await aiCollection(a, 'S', 'k', <String>['v1']);
      await a.sync(cloud);
      cloud.manifest = _stripOrganizeFields(cloud.manifest);
      await tick();
      await a.sync(cloud);
      final MediaCollectionRow row = (await a.db.getMediaCollectionByNaturalKey(
        'S',
        'collection',
      ))!;
      expect(row.origin, 'ai');
      expect(row.organizeKey, 'k');
    });
  });
}

class _Cloud {
  CollectionManifest manifest = CollectionManifest.empty;
}

class _Device {
  _Device(this.db);

  final FushiDatabase db;
  int baselineMs = 0;

  Future<int> sync(_Cloud cloud) async {
    final CollectionManifest local = await loadLocalCollectionManifest(db);
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: local,
      remote: cloud.manifest,
      lastSyncedAtMs: baselineMs,
    );
    final int applied = await applyCollectionLocalChanges(db, outcome.changes);
    // 与编排器一致：推的是本轮合并结果；基线推进之后再收敛，收敛造成的本地变化
    // 下一轮再推。
    cloud.manifest = outcome.merged;
    baselineMs = DateTime.now().millisecondsSinceEpoch;
    final int converged = await convergeCollectionsAfterSync(
      db,
      baselineMs: baselineMs,
    );
    return applied + converged;
  }
}

/// 一个活合集里跨端可比的部分（本地 id 各端不同，不比）。
class _Snapshot {
  _Snapshot(this.name, this.type, this.origin, this.key, this.members);

  final String name;
  final String type;
  final String origin;
  final String? key;
  final Set<String> members;

  @override
  bool operator ==(Object other) =>
      other is _Snapshot &&
      other.name == name &&
      other.type == type &&
      other.origin == origin &&
      other.key == key &&
      other.members.length == members.length &&
      other.members.containsAll(members);

  @override
  int get hashCode => Object.hash(name, type, origin, key);

  @override
  String toString() => '$name/$type/$origin/$key$members';
}

Future<List<_Snapshot>> _snapshot(FushiDatabase db) async {
  final List<_Snapshot> out = <_Snapshot>[
    for (final MediaCollectionRow row in await db.getAllMediaCollections())
      _Snapshot(
        row.name,
        row.collectionType,
        row.origin,
        row.organizeKey,
        <String>{
          for (final MediaCollectionItemRow m in await db.getCollectionItems(
            row.id,
          ))
            '${m.mediaType}|${m.entryKey}',
        },
      ),
  ]..sort((_Snapshot a, _Snapshot b) => a.name.compareTo(b.name));
  return out;
}

CollectionManifest _stripOrganizeFields(CollectionManifest m) {
  final Map<String, dynamic> json =
      jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>;
  for (final Object? c in json['collections'] as List<Object?>) {
    (c! as Map<String, dynamic>)
      ..remove('origin')
      ..remove('organizeKey')
      ..remove('organizeAliases');
  }
  return CollectionManifest.fromJson(json);
}
