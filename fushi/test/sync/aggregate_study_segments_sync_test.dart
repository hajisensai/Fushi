import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_merge_service.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// v92 统计域 wire v2：学习事实段（study_segments）与按身份墓碑随聚合快照上行，
// 按 uid LWW 并集、墓碑仲裁「删除 vs 又读了」。本测试锁定：
//  * 快照 round-trip 与旧 payload（无新 key）兼容；
//  * 纯函数并集 / 仲裁的四条不变量；
//  * 双设备云同步：并集无重复、无塌缩、幂等，删除跨端传播，重读复活；
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
  int ms = 60000,
  int chars = 0,
}) => StudySegmentRecord(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  format: '',
  title: 'T',
  startAt: 100,
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
  int ms = 60000,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  title: 'T',
  startAt: 100,
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

    test('仲裁：墓碑严格新于段 → 段出局；有更新的段 → 墓碑出局', () {
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
      final ({
        List<StudySegmentRecord> segments,
        List<StudyTombstoneRecord> tombstones,
      })
      out = AggregateMergeService.arbitrateStudySegments(
        union: <StudySegmentRecord>[
          _rec('old', key: 'v1', updatedAt: 120), // 被 150 压制
          _rec('new', key: 'v1', updatedAt: 150), // 与墓碑同刻 → 段胜
          _rec('v2seg', key: 'v2', updatedAt: 50), // 被 100 压制
          _rec('other', key: 'v3', updatedAt: 1),
        ],
        tombstones: tombs,
      );
      expect(out.segments.map((r) => r.uid).toSet(), <String>{'new', 'other'});
      expect(
        out.tombstones.map((t) => t.key),
        <String>['video|v2'],
        reason: 'v1 有 updatedAt >= deletedAt 的段 → 墓碑退场（重读复活）',
      );
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

    test('删除跨端传播；对端重读（updatedAt 更新）复活', () async {
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

      // B 又看了 v1：新段 updatedAt 在墓碑之后 → 两端都复活。
      final int later = DateTime.now().millisecondsSinceEpoch + 1000;
      await dbB.upsertStudySegment(_seg('b1', key: 'v1', updatedAt: later));
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
      await src.upsertStudySegmentTombstone(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v3',
        deletedAt: 50,
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

      await BackupService.mergeRestoreBackup(
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
      }, reason: 'doomed 被备份里的墓碑压制');
      expect(byUid['shared']!.durationMs, 900, reason: 'LWW 取备份里更新的值');
      expect((await merged.getStudySegmentTombstones()).single.mediaKey, 'v3');
    });
  });
}
