import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_merge_service.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_asset_store.dart' show AssetEntry;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// v92 统计域 wire v2：学习事实段（study_segments）与按身份墓碑随聚合快照上行，
// 按 uid LWW 并集、墓碑按「删除 startAt < deletedAt 的段」仲裁（BUG-2214 /
// BUG-2220：碑永不因后来的段退场）。本测试锁定：
//  * 快照 round-trip 与旧 payload（无新 key）兼容；
//  * 纯函数并集 / 仲裁的四条不变量；
//  * 双设备云同步：并集无重复、无塌缩、幂等，删除跨端传播，删除后开的新段存活；
//    删除时仍在跑的开放段回写被拒；两端 skew 下碑不消失；清空全部不复活（BUG-2215）；
//  * 游戏段 / 碑不出本机、不落地、不从备份搬入（BUG-2221）；
//  * 备份 ATTACH 合并与在线同步同语义。
// 这一套取代了 legacy 家族的 MAX-union / setVideoWatchStatistic 塌缩 / deficit-lift
// （BUG-1947：wire 键 (title, dateKey) 让分集裸集号跨作品相加再 MAX 固化）。

Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  final FushiDatabase db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

StudySegmentRecord _rec(
  String uid, {
  String kind = kActivityMediaVideo,
  String key = 'v1',
  int updatedAt = 1000,
  int startAt = 100,
  int ms = 60000,
  int chars = 0,
}) => StudySegmentRecord(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  format: '',
  title: 'T',
  startAt: startAt,
  endAt: 200,
  dateKey: '2026-08-29',
  hour: 12,
  durationMs: ms,
  chars: chars,
  pages: 0,
  updatedAt: updatedAt,
);

StudySegmentsCompanion _seg(
  String uid, {
  String kind = kActivityMediaVideo,
  String key = 'v1',
  int updatedAt = 1000,
  int startAt = 100,
  int ms = 60000,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  title: 'T',
  startAt: startAt,
  endAt: 200,
  dateKey: '2026-08-29',
  hour: 12,
  durationMs: Value(ms),
  updatedAt: updatedAt,
);

void main() {
  group('AggregateSnapshot wire v2（additive 字段）', () {
    test('段与墓碑 toJson / fromJson round-trip，版本仍是 1', () {
      final AggregateSnapshot snap = AggregateSnapshot(
        studySegments: <StudySegmentRecord>[_rec('u1', chars: 7)],
        studySegmentTombstones: const <StudyTombstoneRecord>[
          StudyTombstoneRecord(
            mediaKind: 'book',
            mediaKey: 'b1',
            deletedAt: 500,
          ),
        ],
      );
      final Map<String, Object?> json = snap.toJson();
      expect(
        json['version'],
        1,
        reason: 'additive 字段不 bump 版本（bump 会让旧端整包降级为空）',
      );
      final AggregateSnapshot back = AggregateSnapshot.fromJson(json);
      expect(back.studySegments.single.uid, 'u1');
      expect(back.studySegments.single.chars, 7);
      expect(back.studySegments.single.updatedAt, 1000);
      expect(back.studySegmentTombstones.single.mediaKey, 'b1');
      expect(back.isEmpty, isFalse);
    });

    test('旧端 v1 payload 没有新 key → 两个列表为空，其余家族照常', () {
      final AggregateSnapshot back = AggregateSnapshot.fromJson(
        <String, Object?>{
          'version': 1,
          'miningStats': <Object?>[
            <String, Object?>{
              'sourceType': 'book',
              'dateKey': '2026-01-01',
              'count': 3,
            },
          ],
        },
      );
      expect(back.studySegments, isEmpty);
      expect(back.studySegmentTombstones, isEmpty);
      expect(back.miningStats.single.count, 3);
    });

    test('坏行跳过：缺 uid / mediaKey 的段不进快照', () {
      final AggregateSnapshot back = AggregateSnapshot.fromJson(
        <String, Object?>{
          'studySegments': <Object?>[
            <String, Object?>{
              'uid': '',
              'mediaKind': 'book',
              'mediaKey': 'b',
              'dateKey': 'd',
            },
            <String, Object?>{
              'uid': 'ok',
              'mediaKind': 'book',
              'mediaKey': 'b',
              'dateKey': 'd',
            },
          ],
        },
      );
      expect(back.studySegments.map((r) => r.uid), <String>['ok']);
    });

    test('select(stats: false) 连段与墓碑一起置空（墓碑跟着它保护的族走）', () {
      final AggregateSnapshot snap = AggregateSnapshot(
        studySegments: <StudySegmentRecord>[_rec('u1')],
        studySegmentTombstones: const <StudyTombstoneRecord>[
          StudyTombstoneRecord(mediaKind: 'book', mediaKey: 'b1', deletedAt: 1),
        ],
      );
      final AggregateSnapshot cut = snap.select(stats: false, favorites: true);
      expect(cut.studySegments, isEmpty);
      expect(cut.studySegmentTombstones, isEmpty);
      expect(
        identical(snap.select(stats: true, favorites: true), snap),
        isTrue,
      );
    });
  });

  group('AggregateMergeService 段并集 / 仲裁（纯函数）', () {
    test('按 uid 并集，同 uid 取 updatedAt 大者；交换、幂等', () {
      final List<StudySegmentRecord> a = <StudySegmentRecord>[
        _rec('u1', updatedAt: 10, ms: 1000),
        _rec('u2', updatedAt: 10, ms: 2000),
      ];
      final List<StudySegmentRecord> b = <StudySegmentRecord>[
        _rec('u2', updatedAt: 20, ms: 2500),
        _rec('u3', updatedAt: 5, ms: 3000),
      ];
      final Map<String, StudySegmentRecord> ab =
          AggregateMergeService.mergeStudySegments(a, b);
      final Map<String, StudySegmentRecord> ba =
          AggregateMergeService.mergeStudySegments(b, a);
      expect(ab.keys.toSet(), <String>{'u1', 'u2', 'u3'});
      expect(ab['u2']!.durationMs, 2500, reason: 'LWW 取新');
      expect(ba['u2']!.durationMs, 2500, reason: '交换律');
      final Map<String, StudySegmentRecord> again =
          AggregateMergeService.mergeStudySegments(ab.values, b);
      expect(again['u2']!.durationMs, 2500, reason: '幂等');
      expect(again.length, 3);
      // 与 legacy 的形状对照：两台设备各写各的 uid，绝不相加、绝不塌缩。
      expect(
        ab['u1']!.durationMs + ab['u2']!.durationMs + ab['u3']!.durationMs,
        1000 + 2500 + 3000,
      );
    });

    test('仲裁：startAt < deletedAt 的段出局；墓碑永不退场；游戏段 / 碑不进', () {
      final Map<String, StudyTombstoneRecord> tombs =
          AggregateMergeService.mergeStudyTombstones(
            const <StudyTombstoneRecord>[
              StudyTombstoneRecord(
                mediaKind: 'video',
                mediaKey: 'v1',
                deletedAt: 100,
              ),
              StudyTombstoneRecord(
                mediaKind: 'video',
                mediaKey: 'v2',
                deletedAt: 100,
              ),
            ],
            const <StudyTombstoneRecord>[
              StudyTombstoneRecord(
                mediaKind: 'video',
                mediaKey: 'v1',
                deletedAt: 150,
              ),
            ],
          );
      expect(tombs['video|v1']!.deletedAt, 150, reason: '同键取 max');
      tombs['game|g1'] = const StudyTombstoneRecord(
        mediaKind: 'game',
        mediaKey: 'g1',
        deletedAt: 1,
      );
      final ({
        List<StudySegmentRecord> segments,
        List<StudyTombstoneRecord> tombstones,
      })
      out = AggregateMergeService.arbitrateStudySegments(
        union: <StudySegmentRecord>[
          // 删除前开的段：updatedAt 已被 tick 推过碑戳也出局（旧口径的病灶）。
          _rec('open', key: 'v1', startAt: 120, updatedAt: 999),
          _rec('new', key: 'v1', startAt: 150, updatedAt: 151), // 与碑同刻 → 存活
          _rec('v2seg', key: 'v2', startAt: 50, updatedAt: 500), // 被 100 压制
          _rec('other', key: 'v3', startAt: 1, updatedAt: 1),
          _rec('game', kind: 'game', key: 'g1', startAt: 9999), // BUG-2221
        ],
        tombstones: tombs,
      );
      expect(out.segments.map((r) => r.uid).toSet(), <String>{'new', 'other'});
      expect(out.tombstones.map((t) => t.key).toSet(), <String>{
        'video|v1',
        'video|v2',
      }, reason: '碑永不因后来的段退场；游戏碑不进');
    });
  });

  group('双设备云同步（FakeAssetStore）', () {
    test('并集无重复、无塌缩；重复 sync 幂等', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_a_');
      final FushiDatabase dbB = await _freshDb('seg_b_');
      // 两台设备看的是**同名不同视频**（BUG-1947 场景：裸集号 S01E01 跨作品）。
      await dbA.upsertStudySegment(_seg('a1', key: 'uid-A', ms: 30 * 60000));
      await dbB.upsertStudySegment(_seg('b1', key: 'uid-B', ms: 30 * 60000));

      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');

      for (final FushiDatabase db in <FushiDatabase>[dbA, dbB]) {
        final List<StudySegmentRow> rows = await db.getStudySegments();
        expect(rows.map((r) => r.uid).toSet(), <String>{'a1', 'b1'});
        expect(rows.map((r) => r.mediaKey).toSet(), <String>{
          'uid-A',
          'uid-B',
        }, reason: '各自身份保持，不按 title 塌缩成一条');
        expect(
          rows.fold<int>(0, (int s, r) => s + r.durationMs),
          60 * 60000,
          reason: '30+30 分钟，不是「同 title 求和再 MAX」的 60+60',
        );
      }
      final List<StudySegmentRow> before = await dbA.getStudySegments();
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      final List<StudySegmentRow> after = await dbA.getStudySegments();
      expect(after.length, before.length);
      expect(
        after.map((r) => '${r.uid}:${r.durationMs}:${r.updatedAt}').toSet(),
        before.map((r) => '${r.uid}:${r.durationMs}:${r.updatedAt}').toSet(),
        reason: '同值重放 no-op（LWW 不降级、不覆盖）',
      );
    });

    test('LWW：同 uid 更新的绝对值覆盖旧值，旧快照不能把值倒回去', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_lww_a_');
      final FushiDatabase dbB = await _freshDb('seg_lww_b_');
      await dbA.upsertStudySegment(_seg('a1', updatedAt: 10, ms: 1000));
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect((await dbB.getStudySegments()).single.durationMs, 1000);
      // A 的时钟继续 tick：同 uid 绝对值增大。
      await dbA.upsertStudySegment(_seg('a1', updatedAt: 20, ms: 5000));
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect((await dbB.getStudySegments()).single.durationMs, 5000);
      // B 再上传自己那份（仍是 5000/20）→ A 不会被倒回 1000。
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect((await dbA.getStudySegments()).single.durationMs, 5000);
    });

    test('删除跨端传播；对端删除后开的新段（startAt >= deletedAt）存活、碑仍在', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_del_a_');
      final FushiDatabase dbB = await _freshDb('seg_del_b_');
      await dbA.upsertStudySegment(_seg('a1', key: 'v1', updatedAt: 10));
      await dbA.upsertStudySegment(_seg('a2', key: 'v9', updatedAt: 10));
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect((await dbB.getStudySegments()).length, 2);

      // A 删掉 v1 的统计（立碑 deletedAt = now >> 10）。
      await dbA.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
      );
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect(
        (await dbA.getStudySegments()).map((r) => r.uid),
        <String>['a2'],
        reason: 'peer 快照里的旧段不能把本机删掉的复活',
      );
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect((await dbB.getStudySegments()).map((r) => r.uid), <String>[
        'a2',
      ], reason: '删除传播到 B');
      expect((await dbB.getStudySegmentTombstones()).single.mediaKey, 'v1');

      // B 又看了 v1：新段 startAt 在墓碑之后 → 两端都有；碑不退场。
      final int later = DateTime.now().millisecondsSinceEpoch + 1000;
      await dbB.upsertStudySegment(
        _seg('b1', key: 'v1', startAt: later, updatedAt: later),
      );
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect((await dbA.getStudySegments()).map((r) => r.uid).toSet(), <String>{
        'a2',
        'b1',
      });
      expect((await dbB.getStudySegments()).map((r) => r.uid).toSet(), <String>{
        'a2',
        'b1',
      });
      expect((await dbA.getStudySegmentTombstones()).single.mediaKey, 'v1');
      expect((await dbB.getStudySegmentTombstones()).single.mediaKey, 'v1');
    });

    test('删除时仍在跑的时钟：开放段回写被拒，对端也不复活（BUG-2214）', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_open_a_');
      final FushiDatabase dbB = await _freshDb('seg_open_b_');
      final int t0 = DateTime.now().millisecondsSinceEpoch - 10 * 60000;
      await dbA.upsertStudySegment(
        _seg('open', key: 'v1', startAt: t0, updatedAt: t0 + 60000),
      );
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect((await dbB.getStudySegments()).single.uid, 'open');

      await dbA.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
      );
      final int deletedAt =
          (await dbA.getStudySegmentTombstones()).single.deletedAt;
      // 时钟下一 tick：同 uid，updatedAt 越过碑戳，startAt 仍在删除之前。
      await dbA.upsertStudySegment(
        _seg(
          'open',
          key: 'v1',
          startAt: t0,
          updatedAt: deletedAt + 60000,
          ms: 120000,
        ),
      );
      expect(await dbA.getStudySegments(), isEmpty, reason: '本机回写被拒');
      for (int i = 0; i < 2; i++) {
        await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
        await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      }
      expect(await dbA.getStudySegments(), isEmpty, reason: 'peer 旧段不回灌');
      expect(await dbB.getStudySegments(), isEmpty, reason: '删除传播到 B');
      expect(
        (await dbA.getStudySegmentTombstones()).single.deletedAt,
        deletedAt,
      );
      expect(
        (await dbB.getStudySegmentTombstones()).single.deletedAt,
        deletedAt,
      );
    });

    test('两端墙钟 skew：对端时钟超前的段 updatedAt 再大也压不掉碑（BUG-2220）', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_skew_a_');
      final FushiDatabase dbB = await _freshDb('seg_skew_b_');
      final int now = DateTime.now().millisecondsSinceEpoch;
      // B 的墙钟快 2 小时：段的 startAt / updatedAt 都「来自未来」。
      const int skew = 2 * 3600000;
      await dbB.upsertStudySegment(
        _seg('bfuture', key: 'v1', startAt: now - 60000, updatedAt: now + skew),
      );
      await dbA.upsertStudySegment(
        _seg('a1', key: 'v1', startAt: now - 120000, updatedAt: now),
      );
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect((await dbA.getStudySegments()).length, 2);

      await dbA.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
      );
      final int deletedAt =
          (await dbA.getStudySegmentTombstones()).single.deletedAt;
      for (int i = 0; i < 3; i++) {
        await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
        await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      }
      expect(
        await dbA.getStudySegments(),
        isEmpty,
        reason: 'bfuture 的 updatedAt 超过 deletedAt，旧口径会把碑判死并回灌',
      );
      expect(await dbB.getStudySegments(), isEmpty);
      expect(
        (await dbA.getStudySegmentTombstones()).single.deletedAt,
        deletedAt,
      );
      expect(
        (await dbB.getStudySegmentTombstones()).single.deletedAt,
        deletedAt,
        reason: '碑在两端之间不来回消失',
      );
    });

    test('清空全部统计后同步合并不复活（BUG-2215）', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_clear_a_');
      final FushiDatabase dbB = await _freshDb('seg_clear_b_');
      await dbA.upsertStudySegment(_seg('a1', key: 'v1'));
      await dbB.upsertStudySegment(_seg('b1', key: 'v1'));
      await dbB.upsertStudySegment(_seg('b2', key: 'v2'));
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect((await dbA.getStudySegments()).length, 3);

      await dbA.clearAllVideoStatistics();
      expect(await dbA.getStudySegments(), isEmpty);
      for (int i = 0; i < 2; i++) {
        await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
        await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      }
      expect(await dbA.getStudySegments(), isEmpty, reason: 'peer 不回灌');
      expect(await dbB.getStudySegments(), isEmpty, reason: '清空传播到 B');
      expect(
        (await dbB.getStudySegmentTombstones()).map((t) => t.mediaKey).toSet(),
        <String>{'v1', 'v2'},
      );
      // 清空之后再看 v1：新段存活并传播。
      final int later = DateTime.now().millisecondsSinceEpoch + 1000;
      await dbB.upsertStudySegment(
        _seg('fresh', key: 'v1', startAt: later, updatedAt: later),
      );
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect((await dbA.getStudySegments()).single.uid, 'fresh');
    });

    test('游戏段 / 碑不出本机、旧端直落的游戏段也不落地（BUG-2221）', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_game_a_');
      final FushiDatabase dbB = await _freshDb('seg_game_b_');
      await dbA.upsertStudySegment(
        _seg('g1', kind: kActivityMediaGame, key: 'game-1'),
      );
      await dbA.upsertStudySegment(_seg('v1', key: 'vid-1'));
      await dbA.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaGame,
        mediaKey: 'game-9',
      );
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
      final AssetEntry? uploadedEntry = await store.findAsset(
        ns,
        'dev-A.fushiaggregate',
      );
      final AggregateSnapshot uploaded = AggregateSnapshot.fromJson(
        (await store.getJsonAsset(uploadedEntry!.id))! as Map<String, Object?>,
      );
      expect(uploaded.studySegments.map((r) => r.uid), <String>['v1']);
      expect(uploaded.studySegmentTombstones, isEmpty);

      // 旧端直接上传了带游戏段 / 碑的快照。
      await store.putJsonAsset(ns, 'dev-OLD.fushiaggregate', <String, Object?>{
        'version': 1,
        'studySegments': <Object?>[
          _rec('oldgame', kind: kActivityMediaGame, key: 'game-2').toJson(),
          _rec('oldvid', key: 'vid-2').toJson(),
        ],
        'studySegmentTombstones': <Object?>[
          const StudyTombstoneRecord(
            mediaKind: kActivityMediaGame,
            mediaKey: 'game-1',
            deletedAt: 1 << 50,
          ).toJson(),
        ],
      });
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect((await dbB.getStudySegments()).map((r) => r.uid).toSet(), <String>{
        'v1',
        'oldvid',
      }, reason: '游戏段不落地');
      expect(await dbB.getStudySegmentTombstones(), isEmpty, reason: '游戏碑不落地');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect(
        (await dbA.getStudySegments()).map((r) => r.uid).toSet(),
        <String>{'g1', 'v1', 'oldvid'},
        reason: '本机游戏段不受旧端游戏碑影响',
      );
    });

    test('旧端 v1 快照（无段字段）混入不影响新端的段', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('seg_old_a_');
      await dbA.upsertStudySegment(_seg('a1'));
      // 模拟旧端上传：只有 legacy 家族的 payload。
      final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
      await store.putJsonAsset(ns, 'dev-OLD.fushiaggregate', <String, Object?>{
        'version': 1,
        'readingStats': <Object?>[
          <String, Object?>{
            'title': 'Old Book',
            'dateKey': '2026-01-01',
            'charactersRead': 10,
            'readingTimeMs': 1000,
            'lastStatisticModified': 1,
          },
        ],
      });
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect((await dbA.getStudySegments()).single.uid, 'a1');
      expect(
        (await dbA.getAllReadingStatistics()).single.title,
        'Old Book',
        reason: 'legacy 家族照旧 MAX 进 legacy 表',
      );
    });
  });

  group('备份 ATTACH 合并（与在线同步同语义）', () {
    test('按 uid 并集 + LWW + 墓碑压制', () async {
      final Directory curDir = await Directory.systemTemp.createTemp(
        'segbk_cur_',
      );
      addTearDown(() => cleanupTempDir(curDir));
      final FushiDatabase cur = FushiDatabase(curDir.path);
      await cur.upsertStudySegment(_seg('shared', updatedAt: 10, ms: 100));
      await cur.upsertStudySegment(_seg('local', key: 'v2', updatedAt: 10));
      await cur.upsertStudySegment(_seg('doomed', key: 'v3', updatedAt: 10));
      await cur.close();

      final Directory srcDir = await Directory.systemTemp.createTemp(
        'segbk_src_',
      );
      addTearDown(() => cleanupTempDir(srcDir));
      final FushiDatabase src = FushiDatabase(srcDir.path);
      await src.upsertStudySegment(_seg('shared', updatedAt: 20, ms: 900));
      await src.upsertStudySegment(_seg('backup', key: 'v4', updatedAt: 10));
      await src.upsertStudySegment(
        _seg('game', kind: kActivityMediaGame, key: 'g1'),
      );
      await src.upsertStudySegmentTombstone(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v3',
        deletedAt: 500, // doomed 的 startAt = 100 < 500 → 压制
      );
      await src.upsertStudySegmentTombstone(
        mediaKind: kActivityMediaGame,
        mediaKey: 'g2',
        deletedAt: 500,
      );
      final Directory zipDir = await Directory.systemTemp.createTemp(
        'segbk_zip_',
      );
      addTearDown(() => cleanupTempDir(zipDir));
      final String zip = p.join(zipDir.path, 'b.zip');
      await BackupService(
        db: src,
        dbDirectory: srcDir.path,
        appVersion: '2.0.0',
      ).createBackup(zip);
      await src.close();
      expect(File(zip).existsSync(), isTrue);
      expect(
        ZipDecoder().decodeBytes(File(zip).readAsBytesSync()).files,
        isNotEmpty,
      );

      await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDir.path,
        zipPath: zip,
      );

      final FushiDatabase merged = FushiDatabase(curDir.path);
      addTearDown(merged.close);
      final Map<String, StudySegmentRow> byUid = <String, StudySegmentRow>{
        for (final StudySegmentRow r in await merged.getStudySegments())
          r.uid: r,
      };
      expect(byUid.keys.toSet(), <String>{
        'shared',
        'local',
        'backup',
      }, reason: 'doomed 被备份里的墓碑压制；备份里的游戏段不搬入（BUG-2221）');
      expect(byUid['shared']!.durationMs, 900, reason: 'LWW 取备份里更新的值');
      expect(
        (await merged.getStudySegmentTombstones()).single.mediaKey,
        'v3',
        reason: '游戏碑不搬入',
      );
    });

    test('备份合并：删除后开的新段存活、碑不退场（与在线同步同语义）', () async {
      final Directory curDir = await Directory.systemTemp.createTemp(
        'segbk2_cur_',
      );
      addTearDown(() => cleanupTempDir(curDir));
      final FushiDatabase cur = FushiDatabase(curDir.path);
      // 本机：v1 删除前的开放段（updatedAt 已越过碑戳）+ 删除后的新段。
      await cur.upsertStudySegment(
        _seg('open', key: 'v1', startAt: 100, updatedAt: 9000),
      );
      await cur.upsertStudySegment(
        _seg('fresh', key: 'v1', startAt: 6000, updatedAt: 6001),
      );
      await cur.close();

      final Directory srcDir = await Directory.systemTemp.createTemp(
        'segbk2_src_',
      );
      addTearDown(() => cleanupTempDir(srcDir));
      final FushiDatabase src = FushiDatabase(srcDir.path);
      await src.upsertStudySegmentTombstone(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
        deletedAt: 5000,
      );
      final Directory zipDir = await Directory.systemTemp.createTemp(
        'segbk2_zip_',
      );
      addTearDown(() => cleanupTempDir(zipDir));
      final String zip = p.join(zipDir.path, 'b.zip');
      await BackupService(
        db: src,
        dbDirectory: srcDir.path,
        appVersion: '2.0.0',
      ).createBackup(zip);
      await src.close();

      await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path,
        zipPath: zip,
      );
      final FushiDatabase merged = FushiDatabase(curDir.path);
      addTearDown(merged.close);
      expect(
        (await merged.getStudySegments()).map((r) => r.uid).toList(),
        <String>['fresh'],
        reason: 'open 按 startAt 压制（旧口径按 updatedAt 会放过它并把碑删掉）',
      );
      expect((await merged.getStudySegmentTombstones()).single.deletedAt, 5000);
    });
  });
}
