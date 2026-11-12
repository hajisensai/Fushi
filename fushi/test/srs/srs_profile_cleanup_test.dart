// 反馈 8TaOy2i-lL 现象 3：删 Profile 只删 profiles 行，srs.db 里该 uid 的笔记 / 卡 / 复习记录与 srs_media/<uid>
// 目录全部留成无主副本。这里经真实的 ProfileViewModel → SrsProfileCleanup → Rust `profile_purge` 走一遍：
// 确认框规模、删前备份（且能导回）、备份失败中止、删当前 Profile、一次性存量扫描。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_deletion_cascade.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_profile_cleanup.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_profile_data.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_anki_repository.dart';
import 'srs_test_support.dart';

void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late SrsStorage storage;
  late Directory support;
  late Directory backups;
  late Map<String, SrsDbStore> stores;
  late Future<Directory> Function() backupRoot;

  Future<String> uidOf(int id) => db.profileUidOf(id);

  /// 当前 Profile 的副本（同 app：按激活 id 取；同一个 uid 复用同一个实例）。
  Future<SrsDbStore> activeStore() async {
    final String uid = await uidOf(await repo.getActiveProfileId());
    return stores[uid] ??= await SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: uid,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    );
  }

  SrsProfileCleanup newCleanup() => SrsProfileCleanup(
    SrsProfileCleanupDeps(
      storage: () async => storage,
      activeStore: activeStore,
      deviceId: () async => 'dev',
      supportRoot: () async => support,
      backupRoot: () => backupRoot(),
      clock: () => DateTime(2026, 10, 27, 9, 30, 5),
    ),
  );

  ProfileViewModel newVm() => ProfileViewModel(
    repo,
    () async {},
    ProfileDraftCoordinator(),
    deletionCascade: newCleanup(),
  );

  Future<ProfileViewModel> loadedVm() async {
    final ProfileViewModel vm = newVm();
    addTearDown(vm.dispose);
    await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    return vm;
  }

  /// [uid] 下 [notes] 条笔记（第一条引用一个媒体文件），第一张卡复习 [reviews] 次；媒体文件落进它的媒体目录。
  Future<SrsDbStore> seed(
    String uid, {
    required int notes,
    required int reviews,
  }) async {
    final SrsDbStore s = stores[uid] ??= await SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: uid,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    );
    final List<String> ids = <String>[];
    for (int i = 0; i < notes; i++) {
      ids.add(
        await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(uid, 'Expression'): i == 0
                ? '雪<img src="snow.png">'
                : '語$i',
          },
        ),
      );
    }
    final String card = (await s.cardsOfNote(ids.first)).first.id;
    for (int i = 0; i < reviews; i++) {
      await s.answer(card, 3);
    }
    final Directory media = SrsMediaStore.directoryFor(support, uid);
    await media.create(recursive: true);
    await File(p.join(media.path, 'snow.png')).writeAsBytes(<int>[1, 2, 3]);
    final Directory rwkv = Directory(p.join(support.path, 'srs_rwkv', 'state'));
    await rwkv.create(recursive: true);
    await File(p.join(rwkv.path, 'rwkv-$uid-m.snap')).writeAsBytes(<int>[9]);
    return s;
  }

  Future<int> sqlCount(String sql, String uid) async {
    final QueryRow r = await storage.db
        .customSelect(
          sql,
          variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
        )
        .getSingle();
    return r.read<int>('c');
  }

  /// [uid] 名下按 profile 记的 `srs_meta` 键数（`…/<uid>` 或 `…/<uid>/…`）。
  Future<int> metaOf(String uid) async =>
      (await storage.db
              .customSelect(
                "SELECT COUNT(*) AS c FROM srs_meta WHERE key LIKE '%/' || ?1 "
                "OR key LIKE '%/' || ?1 || '/%'",
                variables: <Variable<Object>>[Variable<String>(uid)],
              )
              .getSingle())
          .read<int>('c');

  /// 库里每张带 `profile_uid` 的表里 [uid] 各有几行（逐表；断言「一行没少 / 没变」用）。
  Future<Map<String, int>> tableRows(String uid) async {
    final List<QueryRow> tables = await storage.db
        .customSelect(
          "SELECT m.name AS n FROM sqlite_master m WHERE m.type = 'table' "
          'AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) '
          "WHERE name = 'profile_uid') ORDER BY m.name",
        )
        .get();
    final Map<String, int> out = <String, int>{};
    for (final QueryRow t in tables) {
      final String name = t.read<String>('n');
      out[name] = await sqlCount(
        'SELECT COUNT(*) AS c FROM "$name" WHERE profile_uid = ?',
        uid,
      );
    }
    return out;
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    storage = await openSrsTestStorage();
    support = Directory.systemTemp.createTempSync('fushi_srs_cleanup_');
    backups = Directory(p.join(support.path, 'backups'));
    backupRoot = () async => backups;
    stores = <String, SrsDbStore>{};
    addTearDown(() async {
      await db.close();
      try {
        support.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄滞后；留给系统清理。
      }
    });
  });

  test(
    'deleting a profile backs up then removes all its SRS data, media and RWKV '
    'snapshots; the other profile is untouched; the backup restores',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final int keepId = await repo.getActiveProfileId();
      final int goneId = await repo.createProfile('日语 学习');
      final String keepUid = await uidOf(keepId);
      final String goneUid = await uidOf(goneId);
      await activeStore();
      await seed(keepUid, notes: 1, reviews: 1);
      await seed(goneUid, notes: 3, reviews: 2);
      final SrsProfileFootprint keepBefore = await srsProfileFootprint(
        storage.core,
        keepUid,
      );

      // 确认框规模 = 库里真实的数。
      final ProfileDeletionImpact impact = await vm.deletionImpact(goneId);
      expect(impact.hasSrsData, isTrue);
      expect(impact.srsNotes, 3);
      expect(
        impact.srsCards,
        await sqlCount(
          'SELECT COUNT(*) AS c FROM srs_cards_cache WHERE profile_uid = ?',
          goneUid,
        ),
      );
      expect(impact.srsCards, greaterThan(0));
      expect(
        impact.srsReviews,
        await sqlCount(
          'SELECT COUNT(*) AS c FROM srs_review_logs WHERE profile_uid = ?',
          goneUid,
        ),
      );
      expect(impact.srsReviews, 2);

      final ProfileDeletionOutcome? outcome = await vm.deleteProfile(goneId);

      expect((await repo.getAllProfiles()).map((ProfileRow r) => r.id), <int>[
        keepId,
      ]);
      // srs.db：这个 uid 在每张按 profile 分的表里一行不剩（rows 是内核按表清单现数的总行数）。
      expect((await srsProfileFootprint(storage.core, goneUid)).rows, 0);
      expect((await srsStoredProfiles(storage.core)).uids, <String>[keepUid]);
      expect(
        SrsMediaStore.directoryFor(support, goneUid).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(support.path, 'srs_rwkv', 'state', 'rwkv-$goneUid-m.snap'),
        ).existsSync(),
        isFalse,
      );
      // 另一个 profile 原样。
      expect(await srsProfileFootprint(storage.core, keepUid), keepBefore);
      expect(SrsMediaStore.directoryFor(support, keepUid).existsSync(), isTrue);
      expect(
        File(
          p.join(support.path, 'srs_rwkv', 'state', 'rwkv-$keepUid-m.snap'),
        ).existsSync(),
        isTrue,
      );
      // 备份：名字带 profile 名与时刻，内容是这个 uid 的 .fushisrs（含被引用的媒体）。
      expect(outcome, isNotNull);
      expect(outcome!.impact.srsReviews, 2);
      final File backup = File(outcome.backupPath!);
      expect(
        p.basename(backup.path),
        'fushi-review-日语 学习-20261027-093005.$kSrsFushiSrsExtension',
      );
      final Archive zip = ZipDecoder().decodeBytes(await backup.readAsBytes());
      final Map<String, Object?> manifest =
          jsonDecode(
                utf8.decode(
                  zip.findFile('manifest.json')!.content as List<int>,
                ),
              )
              as Map<String, Object?>;
      expect(manifest['profile'], goneUid);
      expect(zip.findFile('media/snow.png'), isNotNull);

      // 撤销途径：同 uid 的 profile 导回这份备份，笔记与复习记录都回来。
      final SrsStorage fresh = await openSrsTestStorage();
      final SrsDbStore restored = await SrsDbStore.open(
        db: fresh.db,
        core: fresh.core,
        profileUid: goneUid,
        deviceId: 'dev2',
        engine: const SrsTestEngine(),
      );
      final Directory restoredMedia = Directory(
        p.join(support.path, 'restored_media'),
      );
      await srsImportFushiSrs(restored, backup, mediaRoot: restoredMedia);
      final SrsProfileFootprint back = await srsProfileFootprint(
        fresh.core,
        goneUid,
      );
      expect(back.notes, 3);
      expect(back.reviews, 2);
      expect(File(p.join(restoredMedia.path, 'snow.png')).existsSync(), isTrue);
    },
  );

  test(
    'a failed backup aborts the deletion and leaves everything in place',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final int goneId = await repo.createProfile('B');
      final String goneUid = await uidOf(goneId);
      await activeStore();
      await seed(goneUid, notes: 2, reviews: 1);
      final SrsProfileFootprint before = await srsProfileFootprint(
        storage.core,
        goneUid,
      );
      // 备份根是一个普通文件：建不了目录。
      final File blocker = File(p.join(support.path, 'not_a_dir'));
      await blocker.writeAsString('x');
      backupRoot = () async => Directory(blocker.path);

      await expectLater(
        vm.deleteProfile(goneId),
        throwsA(isA<ProfileDeletionBackupException>()),
      );

      expect(
        (await repo.getAllProfiles()).any((ProfileRow r) => r.id == goneId),
        isTrue,
      );
      expect(await srsProfileFootprint(storage.core, goneUid), before);
      expect(SrsMediaStore.directoryFor(support, goneUid).existsSync(), isTrue);
    },
  );

  test(
    'deleting the active profile switches away first, then purges it',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final int otherId = await repo.getActiveProfileId();
      final int activeId = await repo.createProfile('active');
      await repo.setActiveProfileId(activeId);
      final String activeUid = await uidOf(activeId);
      final SrsDbStore current = await activeStore();
      expect(current.profileUid, activeUid);
      await seed(activeUid, notes: 2, reviews: 3);

      final ProfileDeletionOutcome? outcome = await vm.deleteProfile(activeId);

      expect(await repo.getActiveProfileId(), otherId);
      expect(outcome!.impact.srsReviews, 3);
      expect(File(outcome.backupPath!).existsSync(), isTrue);
      expect((await srsProfileFootprint(storage.core, activeUid)).rows, 0);
      expect(
        SrsMediaStore.directoryFor(support, activeUid).existsSync(),
        isFalse,
      );
      await expectLater(
        current.createNote(
          noteTypeId: current.lapisNoteTypeId,
          fieldsById: const <String, String>{},
        ),
        throwsStateError,
      );
    },
  );

  test('a profile with no SRS data is deleted without a backup', () async {
    final ProfileViewModel vm = await loadedVm();
    final int goneId = await repo.createProfile('never reviewed');
    expect((await vm.deletionImpact(goneId)).hasSrsData, isFalse);

    final ProfileDeletionOutcome? outcome = await vm.deleteProfile(goneId);

    expect(outcome!.backupPath, isNull);
    expect(backups.existsSync(), isFalse);
  });

  test(
    'the one-off sweep backs up and removes orphan uids, then never runs again',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      // 旧版本删 Profile 留下的无主数据：srs.db 里有行，主库没有这个 uid 的 profile。
      const String orphan = '0193a1b2-0000-7000-8000-00000000dead';
      await seed(orphan, notes: 2, reviews: 2);
      final SrsProfileFootprint liveBefore = await srsProfileFootprint(
        storage.core,
        liveUid,
      );

      expect(await vm.sweepOrphanProfileData(), 1);

      expect((await srsStoredProfiles(storage.core)).uids, <String>[liveUid]);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);
      expect(SrsMediaStore.directoryFor(support, orphan).existsSync(), isFalse);
      expect(await srsProfileFootprint(storage.core, liveUid), liveBefore);
      final List<File> files = backups.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(
        p.basename(files.single.path),
        startsWith('fushi-review-orphan-0193a1b2-'),
      );

      // 已扫过：之后新出现的无主数据不再由它清（只跑一次）。
      await seed('0193a1b2-0000-7000-8000-00000000beef', notes: 1, reviews: 0);
      expect(await vm.sweepOrphanProfileData(), 0);
    },
  );

  // BUG-4463：BUG-4292 之前「采用 uid」的手抄删除只删 10 张 srs_* 表，sync2_* 全留下；那之前已经扫过（v1 标记）
  // 的库里这些残留永远扫不到。换了标记键后再扫一次，经同一个 profile_purge 清干净。
  test(
    'the sweep re-runs once over a v1-swept library and clears residue left by '
    'the old adopt implementation; the live profile keeps every row',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      // 本机打开过一次复习的 profile 采用别的 uid：旧实现删掉 10 张 srs_* 表里的行，sync2_* 的操作 / 身份 /
      // 设备 / 摘要桶、按 profile 的 srs_meta 键都留下（BUG-4292 实测）。
      const String residue = '0193a1b2-0000-7000-8000-00000000ad09';
      await SrsDbStore.open(
        db: storage.db,
        core: storage.core,
        profileUid: residue,
        deviceId: 'dev',
        engine: const SrsTestEngine(),
      );
      // 旧实现的表清单（srs_backup_merge.dart `_kSrsProfileTables`，BUG-4292 删掉）。
      for (final String t in <String>[
        'srs_entities',
        'srs_field_edits',
        'srs_review_logs',
        'srs_unknown_events',
        'srs_event_local',
        'srs_local_state',
        'srs_notes_cache',
        'srs_cards_cache',
        'srs_stat_reviews',
        'srs_sent_batches',
      ]) {
        final int exists =
            (await storage.db
                    .customSelect(
                      "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'table' "
                      'AND name = ?',
                      variables: <Variable<Object>>[Variable<String>(t)],
                    )
                    .getSingle())
                .read<int>('c');
        if (exists == 0) continue;
        await storage.db.customStatement(
          'DELETE FROM $t WHERE profile_uid = srs_id(?)',
          <Object>[residue],
        );
      }
      final Map<String, int> left = await tableRows(residue);
      expect(left['sync2_ops'], greaterThan(0));
      expect(left['sync2_self'], 1);
      expect(left['srs_entities'], 0);
      // v1 已经扫过（BUG-4292 之前进过 Profile 管理）。
      await storage.db.customStatement(
        "INSERT INTO srs_meta (key, value) VALUES ('profile_orphan_sweep_v1', '1')",
      );
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
      final Map<String, int> liveBefore = await tableRows(liveUid);
      final int liveMeta = await metaOf(liveUid);

      expect(await vm.sweepOrphanProfileData(), 1);

      expect((await srsStoredProfiles(storage.core)).uids, <String>[liveUid]);
      expect(
        (await tableRows(residue)).values.where((int n) => n > 0),
        isEmpty,
      );
      expect(await metaOf(residue), 0);
      expect(await tableRows(liveUid), liveBefore);
      expect(await metaOf(liveUid), liveMeta);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);

      // 再扫一次：什么都不变。
      expect(await vm.sweepOrphanProfileData(), 0);
      expect(await tableRows(liveUid), liveBefore);
      expect(await metaOf(liveUid), liveMeta);
    },
  );

  test(
    'uids of an unfinished merge are not orphans, and the sweep is not marked '
    'done until the merge finishes',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 0);
      // 并入做到一半：旧 uid 的数据还要等第二遍并入，目标 uid 在改主库 uid 之前也不在主库里。
      const String oldUid = '0193a1b2-0000-7000-8000-0000000001d0';
      const String newUid = '0193a1b2-0000-7000-8000-0000000002d0';
      const String orphan = '0193a1b2-0000-7000-8000-0000000003d0';
      await seed(oldUid, notes: 2, reviews: 1);
      await seed(newUid, notes: 1, reviews: 1);
      await seed(orphan, notes: 1, reviews: 0);
      await storage.db.customStatement(
        'INSERT INTO srs_meta (key, value) VALUES (?, ?)',
        <Object>['profile_merge/$oldUid', '{"profileId":1,"newUid":"$newUid"}'],
      );
      final Map<String, int> oldBefore = await tableRows(oldUid);
      final Map<String, int> newBefore = await tableRows(newUid);

      expect(await vm.sweepOrphanProfileData(), 1);

      expect(await tableRows(oldUid), oldBefore);
      expect(await tableRows(newUid), newBefore);
      expect((await tableRows(orphan)).values.where((int n) => n > 0), isEmpty);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
    },
  );

  /// 不带参数的计数查询。
  Future<int> countAll(String sql) async =>
      (await storage.db.customSelect(sql).getSingle()).read<int>('c');

  Future<void> putMeta(String key) => storage.db.customStatement(
    "INSERT INTO srs_meta (key, value) VALUES (?, '{}')",
    <Object>[key],
  );

  /// 旧版删除实现删过的 uid：表里一行不剩，按 profile 记的键留下四个（三个 uid 在中间的是 Rust 旧
  /// `profile_purge` 漏的，状态摘要是并入旧实现漏的）。不为它开副本——开了就有行了。
  Future<void> leaveMetaOnly(String uid, String device) async {
    await putMeta('sync2_device_ext/$uid/$device');
    await putMeta('sync2_retired/$uid/$device');
    await putMeta('sync2_head_sig/$uid/local:/srv/sync');
    await putMeta('sync2_digest/$uid');
    expect((await tableRows(uid)).values.where((int n) => n > 0), isEmpty);
    expect(await metaOf(uid), 4);
  }

  // BUG-4463 跟进：第一版扫描只认「表里还有行」的 uid，只剩 srs_meta 键的 uid 与没人引用的 sync2_deps 不在清理面
  // 里。完成标记再换一次键（v3），v2 扫过的库再扫一次，收尾把这两类清掉。
  test(
    'the sweep re-runs once over a v2-swept library and clears meta-only orphan '
    'uids and unreferenced sync2_deps; keys that carry a device id stay',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      // 一台别的设备的 ID：UUID 形状，不是任何 profile 的 uid。
      const String device = '0193a1b2-0000-7000-8000-0000000d0001';
      const String gone = '0193a1b2-0000-7000-8000-00000000a0e1';
      // 活 profile 名下带设备 ID 的键、不分 profile 的设备键：把设备 ID 当成无主 uid 去删就会误删它们。
      await putMeta('sync2_device_ext/$liveUid/$device');
      await putMeta('sync2_retired/$liveUid/$device');
      await putMeta('sync2_device_hint/$device');
      await leaveMetaOnly(gone, device);
      await storage.db.customStatement(
        "INSERT INTO sync2_deps (vv) VALUES (x'DEADBEEF')",
      );
      // v2 已经扫过。
      await putMeta('profile_orphan_sweep_v2');
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
      expect((await srsStoredProfiles(storage.core)).uids, <String>[liveUid]);
      final Map<String, int> liveBefore = await tableRows(liveUid);
      final int liveMeta = await metaOf(liveUid);
      final int depsBefore = await countAll(
        'SELECT COUNT(*) AS c FROM sync2_deps',
      );

      expect(await vm.sweepOrphanProfileData(), 1);

      expect(await metaOf(gone), 0);
      expect(await metaOf(liveUid), liveMeta);
      expect(
        await countAll(
          'SELECT COUNT(*) AS c FROM srs_meta '
          "WHERE key = 'sync2_device_hint/$device'",
        ),
        1,
      );
      expect(await tableRows(liveUid), liveBefore);
      expect(
        await countAll('SELECT COUNT(*) AS c FROM sync2_deps'),
        depsBefore - 1,
      );
      expect(
        await countAll(
          'SELECT COUNT(*) AS c FROM sync2_ops '
          'WHERE deps NOT IN (SELECT id FROM sync2_deps)',
        ),
        0,
        reason: 'every op keeps its causal context',
      );
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);
      expect(
        backups.existsSync(),
        isFalse,
        reason: 'a uid with no rows has nothing to back up',
      );
      // 活 profile 照常能写。
      final SrsDbStore live = await activeStore();
      await live.createNote(
        noteTypeId: live.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(liveUid, 'Expression'): '後',
        },
      );
      final Map<String, int> liveAfter = await tableRows(liveUid);
      final int depsAfter = await countAll(
        'SELECT COUNT(*) AS c FROM sync2_deps',
      );

      // 已扫过：不再跑。
      expect(await vm.sweepOrphanProfileData(), 0);
      // 幂等：去掉完成标记硬再扫一遍，也没有可清的、什么都不变。
      await storage.db.customStatement(
        "DELETE FROM srs_meta WHERE key = 'profile_orphan_sweep_v3'",
      );
      expect(await vm.sweepOrphanProfileData(), 0);
      expect(await tableRows(liveUid), liveAfter);
      expect(await metaOf(liveUid), liveMeta);
      expect(await countAll('SELECT COUNT(*) AS c FROM sync2_deps'), depsAfter);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);
    },
  );

  test('leftover meta keys of an unfinished merge target stay until the merge '
      'finishes; an unrelated meta-only orphan is cleared meanwhile', () async {
    final ProfileViewModel vm = await loadedVm();
    final String liveUid = await uidOf(await repo.getActiveProfileId());
    await activeStore();
    await seed(liveUid, notes: 1, reviews: 0);
    const String device = '0193a1b2-0000-7000-8000-0000000d0002';
    // 并入刚开始：标记已写，目标 uid 的副本还没开（表里没有行），它名下只有上一次用这个 uid 时留下的键。
    const String target = '0193a1b2-0000-7000-8000-0000000002e0';
    const String gone = '0193a1b2-0000-7000-8000-0000000003e0';
    await leaveMetaOnly(target, device);
    await leaveMetaOnly(gone, device);
    await storage.db.customStatement(
      'INSERT INTO srs_meta (key, value) VALUES (?, ?)',
      <Object>['profile_merge/$liveUid', '{"profileId":1,"newUid":"$target"}'],
    );
    final Map<String, int> liveBefore = await tableRows(liveUid);
    final int liveMeta = await metaOf(liveUid);

    expect(await vm.sweepOrphanProfileData(), 1);

    expect(await metaOf(target), 4, reason: 'merge target is not an orphan');
    expect(await metaOf(gone), 0);
    expect(await tableRows(liveUid), liveBefore);
    expect(await metaOf(liveUid), liveMeta, reason: 'merge marker kept');
    expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);

    // 并入不做了（标记撤掉）、目标 uid 也没成为本机 profile：下一次扫描才把它当无主清掉，并记完成。
    await storage.db.customStatement(
      'DELETE FROM srs_meta WHERE key = ?',
      <Object>['profile_merge/$liveUid'],
    );
    expect(await vm.sweepOrphanProfileData(), 1);
    expect(await metaOf(target), 0);
    expect(await tableRows(liveUid), liveBefore);
    expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);
  });

  test(
    'with no live profile uid to compare against the sweep deletes nothing',
    () async {
      await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      const String other = '0193a1b2-0000-7000-8000-0000000004d0';
      await seed(other, notes: 1, reviews: 0);
      final Map<String, int> liveBefore = await tableRows(liveUid);
      final Map<String, int> otherBefore = await tableRows(other);

      // 主库一行 profile 都没读出来：判定不了谁活着。
      expect(await newCleanup().sweepOrphans(const <ProfileRow>[]), 0);

      expect(await tableRows(liveUid), liveBefore);
      expect(await tableRows(other), otherBefore);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
      expect(backups.existsSync(), isFalse);
    },
  );
}
