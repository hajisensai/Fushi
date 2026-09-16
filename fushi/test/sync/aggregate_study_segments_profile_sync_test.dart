import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/aggregate_merge_service.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// v105 统计按 Profile 隔离——同步 wire 与备份 ATTACH 合并的 Profile 语义：
//  * 本机自增 profile_id 不出机，wire 传 Profile **名字**（additive 字段，旧端
//    payload 没有 = ''）；
//  * 落地按名字找本机同名 Profile；段找不到落当前激活 Profile（数据不丢），碑找
//    不到**丢弃**（压错 Profile = 删别人的历史）；空名字（旧端）两者都落激活 Profile；
//  * 已有段的归属不随 LWW 改；
//  * 备份 ATTACH 合并同一套按名映射（Profile 先于统计并入，src 独有的 Profile
//    先按名建出来再落统计）。

Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  final FushiDatabase db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<int> _profile(
  FushiDatabase db,
  String name, {
  bool activate = false,
}) async {
  final int id = await db.insertProfile(
    ProfilesCompanion.insert(name: name, createdAt: 1, updatedAt: 1),
  );
  if (activate) await db.setPref(kActiveProfileIdPrefKey, id.toString());
  return id;
}

StudySegmentsCompanion _seg(
  String uid, {
  String key = 'v1',
  int updatedAt = 1000,
  int startAt = 100,
  int ms = 60000,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kActivityMediaVideo,
  mediaKey: key,
  title: 'T',
  startAt: startAt,
  endAt: 200,
  dateKey: '2026-08-29',
  hour: 12,
  durationMs: Value(ms),
  updatedAt: updatedAt,
);

StudySegmentRecord _rec(String uid, {String profileName = ''}) =>
    StudySegmentRecord(
      uid: uid,
      deviceId: 'dev',
      mediaKind: kActivityMediaVideo,
      mediaKey: 'v1',
      format: '',
      title: 'T',
      startAt: 100,
      endAt: 200,
      dateKey: '2026-08-29',
      hour: 12,
      durationMs: 60000,
      chars: 0,
      pages: 0,
      updatedAt: 1000,
      profileName: profileName,
    );

void main() {
  group('wire（additive 字段）', () {
    test('profileName round-trip；空名不写 key（旧端 payload 形状不变）', () {
      final Map<String, Object?> withName = _rec(
        'a',
        profileName: 'JP',
      ).toJson();
      expect(withName['profileName'], 'JP');
      expect(StudySegmentRecord.fromJson(withName)!.profileName, 'JP');
      final Map<String, Object?> noName = _rec('b').toJson();
      expect(noName.containsKey('profileName'), isFalse);
      expect(StudySegmentRecord.fromJson(noName)!.profileName, '');

      const StudyTombstoneRecord tomb = StudyTombstoneRecord(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
        deletedAt: 5,
        profileName: 'JP',
      );
      expect(StudyTombstoneRecord.fromJson(tomb.toJson())!.profileName, 'JP');
      expect(tomb.key, 'JP|video|v1');
      expect(_rec('a', profileName: 'JP').mediaIdentity, tomb.key);
    });

    test('仲裁：碑只压同名 Profile 的段', () {
      final Map<String, StudyTombstoneRecord> tombs =
          AggregateMergeService.mergeStudyTombstones(
            const <StudyTombstoneRecord>[
              StudyTombstoneRecord(
                mediaKind: kActivityMediaVideo,
                mediaKey: 'v1',
                deletedAt: 500,
                profileName: 'JP',
              ),
            ],
            const <StudyTombstoneRecord>[],
          );
      final ({
        List<StudySegmentRecord> segments,
        List<StudyTombstoneRecord> tombstones,
      })
      out = AggregateMergeService.arbitrateStudySegments(
        union: <StudySegmentRecord>[
          _rec('jp', profileName: 'JP'),
          _rec('en', profileName: 'EN'),
          _rec('anon'),
        ],
        tombstones: tombs,
      );
      expect(
        out.segments.map((StudySegmentRecord s) => s.uid).toSet(),
        <String>{'en', 'anon'},
        reason: 'JP 的碑只压 JP 的段（startAt 100 < 500）',
      );
    });
  });

  group('双设备云同步（FakeAssetStore）', () {
    test('同名 Profile 两端各落各的；对端没有的名字落激活 Profile', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('segp_a_');
      final FushiDatabase dbB = await _freshDb('segp_b_');
      final int aJp = await _profile(dbA, 'JP', activate: true);
      final int aEn = await _profile(dbA, 'EN');
      final int bDefault = await _profile(dbB, 'Default', activate: true);
      final int bJp = await _profile(dbB, 'JP');

      await dbA.upsertStudySegment(_seg('jp1'));
      await dbA.setPref(kActiveProfileIdPrefKey, aEn.toString());
      await dbA.upsertStudySegment(_seg('en1', key: 'v2'));
      await dbA.setPref(kActiveProfileIdPrefKey, aJp.toString());

      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');

      expect(
        (await dbB.getStudySegments(profileId: bJp)).single.uid,
        'jp1',
        reason: 'JP 两端同名 → 落 B 的 JP',
      );
      expect(
        (await dbB.getStudySegments(profileId: bDefault)).single.uid,
        'en1',
        reason: 'B 没有 EN → 落 B 当前激活的 Default，数据不丢',
      );
      // 反向：B 的 Default 段回到 A 时 A 没有 Default → 落 A 的激活 JP。
      await dbB.upsertStudySegment(_seg('def1', key: 'v3'));
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect(
        (await dbA.getStudySegments(
          profileId: aJp,
        )).map((StudySegmentRow r) => r.uid).toSet(),
        <String>{'jp1', 'def1'},
      );
      expect(
        (await dbA.getStudySegments(profileId: aEn)).single.uid,
        'en1',
        reason: 'A 自己的 en1 归属不被回灌改掉',
      );
    });

    test('删除跨端只传到同名 Profile；对端没有的名字的碑丢弃', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase dbA = await _freshDb('segp_del_a_');
      final FushiDatabase dbB = await _freshDb('segp_del_b_');
      await _profile(dbA, 'JP', activate: true);
      final int aEn = await _profile(dbA, 'EN');
      final int bJp = await _profile(dbB, 'JP', activate: true);

      // 两端同一视频各有自己的段（uid 不同）。
      await dbA.upsertStudySegment(_seg('a-jp', startAt: 100));
      await dbB.upsertStudySegment(_seg('b-jp', startAt: 100));
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      expect(await dbB.getStudySegments(profileId: bJp), hasLength(2));

      // A 在 EN 下删 v1：EN 的碑对 B 没有意义（B 没有 EN）→ 丢弃，B 的 JP 不受影响。
      await dbA.setPref(kActiveProfileIdPrefKey, aEn.toString());
      await dbA.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
      );
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      expect(
        await dbB.getStudySegments(profileId: bJp),
        hasLength(2),
        reason: 'EN 的碑不能压 B 的 JP',
      );
      expect(
        await dbB.getStudySegmentTombstones(),
        isEmpty,
        reason: '名字对不上的碑不落地',
      );

      // B 在 JP 下删 v1：碑传到 A 的 JP，A 的 EN 不受影响。
      await dbB.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
      );
      await AggregateSyncService(dbB).sync(store: store, deviceId: 'dev-B');
      await AggregateSyncService(dbA).sync(store: store, deviceId: 'dev-A');
      final List<StudySegmentTombstoneRow> aTombs = await dbA
          .getStudySegmentTombstones();
      expect(
        aTombs.map((StudySegmentTombstoneRow t) => t.profileId).toSet(),
        <int>{aEn, (await dbA.getAllProfiles()).first.id},
        reason: 'A 有 EN 自己的碑 + 从 B 传来的 JP 碑',
      );
      expect(
        await dbA.getStudySegments(
          profileId: (await dbA.getAllProfiles()).first.id,
        ),
        isEmpty,
        reason: 'A 的 JP 段被 B 的 JP 碑压掉',
      );
    });

    test('旧端 v1 快照（无 profileName）落进当前激活 Profile', () async {
      final FushiDatabase db = await _freshDb('segp_legacy_');
      final int jp = await _profile(db, 'JP', activate: true);
      await _profile(db, 'EN');
      await AggregateSyncService(db).applySnapshotToLocal(
        AggregateSnapshot(studySegments: <StudySegmentRecord>[_rec('old')]),
      );
      expect((await db.getStudySegments(profileId: jp)).single.uid, 'old');
    });
  });

  group('备份 ATTACH 合并', () {
    test('段按 Profile 名落到本机同名 Profile；src 独有的 Profile 先按名建出', () async {
      final Directory curDir = await Directory.systemTemp.createTemp(
        'segpbk_cur_',
      );
      addTearDown(() => cleanupTempDir(curDir));
      final FushiDatabase cur = FushiDatabase(curDir.path);
      final int curJp = await _profile(cur, 'JP', activate: true);
      await cur.upsertStudySegment(_seg('local'));
      await cur.close();

      final Directory srcDir = await Directory.systemTemp.createTemp(
        'segpbk_src_',
      );
      addTearDown(() => cleanupTempDir(srcDir));
      final FushiDatabase src = FushiDatabase(srcDir.path);
      // src 的 Profile 自增 id 与 cur 错开（先建一个占位再建 JP / EN）。
      await _profile(src, 'Placeholder');
      final int srcJp = await _profile(src, 'JP', activate: true);
      await src.upsertStudySegment(_seg('from-jp', key: 'v2'));
      final int srcEn = await _profile(src, 'EN');
      await src.setPref(kActiveProfileIdPrefKey, srcEn.toString());
      await src.upsertStudySegment(_seg('from-en', key: 'v3'));
      await src.upsertStudySegmentTombstone(
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
        deletedAt: 500,
        profileId: srcEn,
      );
      expect(srcJp, isNot(curJp), reason: '前置：两库的 JP id 必须不同才有映射可测');
      final Directory zipDir = await Directory.systemTemp.createTemp(
        'segpbk_zip_',
      );
      addTearDown(() => cleanupTempDir(zipDir));
      final String zip = p.join(zipDir.path, 'b.zip');
      await BackupService(
        db: src,
        dbDirectory: srcDir.path,
        appVersion: '2.0.0',
      ).createBackup(zip);
      await src.close();

      await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDir.path,
        zipPath: zip,
      );

      final FushiDatabase merged = FushiDatabase(curDir.path);
      addTearDown(merged.close);
      final Map<String, int> idByName = <String, int>{
        for (final ProfileRow p in await merged.getAllProfiles()) p.name: p.id,
      };
      expect(
        idByName.keys.toSet(),
        containsAll(<String>['JP', 'EN', 'Placeholder']),
      );
      expect(idByName['JP'], curJp);
      final Map<String, int> profileByUid = <String, int>{
        for (final StudySegmentRow r in await merged.getStudySegments(
          allProfiles: true,
        ))
          r.uid: r.profileId,
      };
      expect(profileByUid, <String, int>{
        'local': curJp,
        'from-jp': curJp,
        'from-en': idByName['EN']!,
      });
      // EN 的碑落到本机 EN，只压 EN 的段：cur JP 的 v1 段（local）不受影响。
      final StudySegmentTombstoneRow tomb =
          (await merged.getStudySegmentTombstones()).single;
      expect(tomb.profileId, idByName['EN']);
      expect(profileByUid.containsKey('local'), isTrue);
    });
  });
}
