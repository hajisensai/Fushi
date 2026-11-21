import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/srs/srs_backup_bundle.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

/// 整包备份复习部分（新代，G11-4）的纯逻辑：清单解析、按集合导出、合并时备份 profile → 本机 profile 的认领规则。
void main() {
  late SrsStorage backupSrs;
  late SrsStorage localSrs;
  late Directory work;

  setUp(() async {
    backupSrs = await openTestSrsStorage();
    localSrs = await openTestSrsStorage();
    work = Directory.systemTemp.createTempSync('srs_backup_bundle_');
    addTearDown(() {
      try {
        work.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄尚未释放；临时目录留给系统清理。
      }
    });
  });

  int now() => DateTime.now().millisecondsSinceEpoch;

  Future<String> addNote(SrsCore core, String uid, String text) async {
    final SrsDbStore s = await SrsDbStore.open(
      core: core,
      profileUid: uid,
      deviceId: 'dev',
    );
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{srsLapisFieldId(uid, 'Expression'): text},
    );
  }

  /// [uid] 在 [core] 里的笔记身份记录条数（内核读命令 `events`）。
  Future<int> noteCount(SrsCore core, String uid) async =>
      (await srsEventsOf(core, uid))
          .whereType<SrsEntityEvent>()
          .where((SrsEntityEvent e) => e.record.kind == SrsEntityKind.note)
          .length;

  /// 备份端导出 [profiles]，回可落地的单元。
  Future<List<SrsBackupLandUnit>> exportUnits(
    List<SrsBackupProfile> profiles,
  ) async {
    final SrsBackupBundleManifest? m = await srsExportBackupStreams(
      core: backupSrs.core,
      profiles: profiles,
      outDir: work.path,
      nowMs: now(),
    );
    if (m == null) return const <SrsBackupLandUnit>[];
    // 清单经序列化再解析（与整包备份一致）。
    final SrsBackupBundleManifest parsed = SrsBackupBundleManifest.parse(
      utf8.encode(jsonEncode(m.toJson())),
    );
    return <SrsBackupLandUnit>[
      for (final SrsBackupUnit u in parsed.units)
        SrsBackupLandUnit(
          profiles: u.profiles,
          file: SrsBackupStreamFile(
            path: p.join(work.path, '${u.n}.bin'),
            unit: u,
          ),
        ),
    ];
  }

  group('清单', () {
    Map<String, Object?> base() => <String, Object?>{
      'v': kSrsBackupManifestVersion,
      'gen': kSrsBackupManifestGen,
      'exportedAt': 1,
      'collections': <Object?>[],
    };
    List<int> bytes(Map<String, Object?> m) => utf8.encode(jsonEncode(m));

    test('带 magic（v1 .fushisrs 那种头）的拒绝', () {
      expect(
        () => SrsBackupBundleManifest.parse(
          bytes(base()..['magic'] = 'FUSHISRS'),
        ),
        throwsFormatException,
      );
    });

    test('更新的版本 / 代号：明确的 TooNew，不按旧格式猜', () {
      expect(
        () => SrsBackupBundleManifest.parse(bytes(base()..['v'] = 3)),
        throwsA(isA<SrsBackupTooNewException>()),
      );
      expect(
        () => SrsBackupBundleManifest.parse(bytes(base()..['gen'] = 5)),
        throwsA(isA<SrsBackupTooNewException>()),
      );
    });

    test('不是 JSON / 形状不对的拒绝', () {
      expect(
        () => SrsBackupBundleManifest.parse(utf8.encode('not json')),
        throwsFormatException,
      );
      expect(
        () => SrsBackupBundleManifest.parse(
          bytes(base()..['collections'] = <Object?>['x']),
        ),
        throwsFormatException,
      );
    });
  });

  test('「（备份）」撞名时加序号', () {
    expect(srsBackupProfileName('A', <String>{}), 'A（备份）');
    expect(srsBackupProfileName('A', <String>{'A（备份）'}), 'A（备份 2）');
    expect(srsBackupProfileName('A', <String>{'A（备份）', 'A（备份 2）'}), 'A（备份 3）');
  });

  test('只有内置行 / 没绑定的 profile 不导出（不造空单元）', () async {
    final String uid = uuidV7();
    await SrsDbStore.open(core: backupSrs.core, profileUid: uid, deviceId: 'd');
    expect(
      await exportUnits(<SrsBackupProfile>[
        SrsBackupProfile(uid: uid, name: '只打开过'),
        SrsBackupProfile(uid: uuidV7(), name: '从没打开'),
      ]),
      isEmpty,
    );
  });

  group('合并认领', () {
    late List<SrsLocalProfile> locals;
    late List<(String, String)> created;

    setUp(() {
      locals = <SrsLocalProfile>[];
      created = <(String, String)>[];
    });

    Future<List<SrsBackupMergeResult>> merge(
      List<SrsBackupLandUnit> units, {
      bool confirmed = true,
    }) => mergeSrsFromBackup(
      units: units,
      localProfiles: () async => List<SrsLocalProfile>.of(locals),
      localSrs: localSrs.core,
      createProfile: (String name, String uid) async {
        created.add((name, uid));
        final int id = locals.length + 100;
        locals.add((id: id, name: name, uid: uid));
        return id;
      },
      confirmed: confirmed,
      nowMs: now(),
    );

    test('同 uid：落进本机那个 profile；第二次零新增', () async {
      final String uid = uuidV7();
      await addNote(backupSrs.core, uid, '雪');
      final List<SrsBackupLandUnit> units = await exportUnits(
        <SrsBackupProfile>[SrsBackupProfile(uid: uid, name: '日语')],
      );
      locals.add((id: 1, name: '日语', uid: uid));
      final List<SrsBackupMergeResult> r1 = await merge(units);
      expect(r1.single.action, SrsBackupMergeAction.sameUid);
      expect(r1.single.localProfileId, 1);
      expect(r1.single.newEvents, greaterThan(0));
      expect(await noteCount(localSrs.core, uid), 1);
      final List<SrsBackupMergeResult> r2 = await merge(units);
      expect(r2.single.newEvents, 0);
      expect(created, isEmpty);
    });

    test('同名、本机没数据：认领备份的集合；第二次走「已绑在这个集合上」、零新增', () async {
      final String uid = uuidV7();
      await addNote(backupSrs.core, uid, '雪');
      final List<SrsBackupLandUnit> units = await exportUnits(
        <SrsBackupProfile>[SrsBackupProfile(uid: uid, name: '日语')],
      );
      final String localUid = uuidV7();
      locals.add((id: 1, name: '日语', uid: localUid));
      final List<SrsBackupMergeResult> r1 = await merge(units);
      expect(r1.single.action, SrsBackupMergeAction.adoptedCollection);
      expect(r1.single.profileUid, localUid);
      expect(await noteCount(localSrs.core, localUid), 1);
      final List<SrsBackupMergeResult> r2 = await merge(units);
      expect(r2.single.action, SrsBackupMergeAction.sameCollection);
      expect(r2.single.profileUid, localUid);
      expect(r2.single.newEvents, 0);
      expect(await noteCount(localSrs.core, localUid), 1);
      expect(created, isEmpty);
    });

    test('同名但本机有自己的笔记：没确认什么都不落、不建 profile；确认后建「（备份）」，本机数据不动', () async {
      final String uid = uuidV7();
      await addNote(backupSrs.core, uid, '雪');
      final List<SrsBackupLandUnit> units = await exportUnits(
        <SrsBackupProfile>[SrsBackupProfile(uid: uid, name: '日语')],
      );
      final String localUid = uuidV7();
      await addNote(localSrs.core, localUid, '月');
      locals.add((id: 1, name: '日语', uid: localUid));

      final List<SrsBackupMergeResult> declined = await merge(
        units,
        confirmed: false,
      );
      expect(declined.single.action, SrsBackupMergeAction.declined);
      expect(created, isEmpty);
      expect(await noteCount(localSrs.core, localUid), 1);

      final List<SrsBackupMergeResult> r = await merge(units);
      expect(r.single.action, SrsBackupMergeAction.createdProfile);
      expect(r.single.profileUid, uid);
      expect(created, <(String, String)>[('日语（备份）', uid)]);
      expect(await noteCount(localSrs.core, uid), 1);
      expect(await noteCount(localSrs.core, localUid), 1);

      final List<SrsBackupMergeResult> again = await merge(units);
      expect(again.single.action, SrsBackupMergeAction.sameUid);
      expect(again.single.newEvents, 0);
      expect(created, hasLength(1));
    });

    test('同名、本机没数据但发布过批次（传到过位置）：不认领，建「（备份）」；本机 profile 的集合不动', () async {
      final String uid = uuidV7();
      await addNote(backupSrs.core, uid, '雪');
      final List<SrsBackupLandUnit> units = await exportUnits(
        <SrsBackupProfile>[SrsBackupProfile(uid: uid, name: '日语')],
      );
      final String localUid = uuidV7();
      final SrsDbStore local = await SrsDbStore.open(
        core: localSrs.core,
        profileUid: localUid,
        deviceId: 'dev',
      );
      final Directory usb = Directory(p.join(work.path, 'usb'))..createSync();
      await srsSyncFolderLocation(
        location: SrsFolderLocation(id: 'usb', path: usb.path),
        store: local,
      );
      // 前提：本机 profile 没有用户数据，但已经往位置上传过批次。
      expect(await srsProfileHasUserData(localSrs.core, localUid), isFalse);
      final List<Object?> locations =
          (await local.sync2Status())['locations']! as List<Object?>;
      expect(
        locations.any(
          (Object? l) => l is Map && ((l['uploaded'] as int?) ?? 0) > 0,
        ),
        isTrue,
        reason: '$locations',
      );
      final Object? before = localSrs.core.sync2(<String, Object?>{
        'op': 'collection_info',
        'profile': localUid,
      }).map['collection'];
      locals.add((id: 1, name: '日语', uid: localUid));

      final List<SrsBackupMergeResult> r = await merge(units);
      expect(r.single.action, SrsBackupMergeAction.createdProfile);
      expect(r.single.profileUid, uid);
      expect(created, <(String, String)>[('日语（备份）', uid)]);
      expect(await noteCount(localSrs.core, uid), 1);
      expect(await noteCount(localSrs.core, localUid), 0);
      expect(
        localSrs.core.sync2(<String, Object?>{
          'op': 'collection_info',
          'profile': localUid,
        }).map['collection'],
        before,
      );
    });
  });
}
