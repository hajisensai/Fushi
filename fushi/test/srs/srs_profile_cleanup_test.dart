// 反馈 8TaOy2i-lL 现象 3：删 Profile 只删 profiles 行，srs.db 里该 uid 的笔记 / 卡 / 复习记录与 srs_media/<uid>
// 目录全部留成无主副本。这里经真实的 ProfileViewModel → SrsProfileCleanup → Rust `profile_purge` 走一遍：
// 确认框规模、删前备份（且能导回）、备份失败中止、删当前 Profile、一次性存量扫描。
//
// 新代（协议 4，G9-5）：一个 profile 的数据 = 它绑定的那一个集合（内核 `collections` 一行 + 各表按 `col` 的行）与本机
// 状态行 `srs_meta.local_state/<uid>`；规模与「一行不剩」都按内核 `profile_footprint` 数（没有集合 = 全 0），不再按
// 协议 3 的 `srs_*` / `sync2_*` 表逐表数。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Variable;
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
import '../../../packages/fushi_engine/test/srs/support/srs_raw_sql.dart';

void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late SrsStorage storage;
  late Directory support;
  late Directory backups;
  late Map<String, SrsDbStore> stores;
  late Map<String, List<String>> seededNotes;
  late Future<Directory> Function() backupRoot;

  Future<String> uidOf(int id) => db.profileUidOf(id);

  /// 当前 Profile 的副本（同 app：按激活 id 取；同一个 uid 复用同一个实例）。
  Future<SrsDbStore> activeStore() async {
    final String uid = await uidOf(await repo.getActiveProfileId());
    return stores[uid] ??= await SrsDbStore.open(
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
    (seededNotes[uid] ??= <String>[]).addAll(ids);
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

  /// [uid] 经 [seed] 写下的笔记一共有几张卡（按 store 现读）。
  Future<int> cardsOf(String uid) async {
    int n = 0;
    for (final String id in seededNotes[uid] ?? const <String>[]) {
      n += (await stores[uid]!.cardsOfNote(id)).length;
    }
    return n;
  }

  /// [uid] 在本机新代库里的规模（内核 `profile_footprint`；没有集合 = 全 0）。
  Future<SrsProfileFootprint> footprintOf(String uid) =>
      srsProfileFootprint(storage.core, uid);

  /// [uid] 名下按 profile 记的 `srs_meta` 键数（`…/<uid>` 或 `…/<uid>/…`；新代里就是本机状态行
  /// `local_state/<uid>`）。
  Future<int> metaOf(String uid) async =>
      (await storage.core
              .customSelect(
                "SELECT COUNT(*) AS c FROM srs_meta WHERE key LIKE '%/' || ?1 "
                "OR key LIKE '%/' || ?1 || '/%'",
                variables: <Variable<Object>>[Variable<String>(uid)],
              )
              .getSingle())
          .read<int>('c');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    storage = await openSrsTestStorage();
    support = Directory.systemTemp.createTempSync('fushi_srs_cleanup_');
    backups = Directory(p.join(support.path, 'backups'));
    backupRoot = () async => backups;
    stores = <String, SrsDbStore>{};
    seededNotes = <String, List<String>>{};
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
      expect(impact.srsCards, await cardsOf(goneUid));
      expect(impact.srsCards, greaterThan(0));
      expect(impact.srsReviews, 2);

      final ProfileDeletionOutcome? outcome = await vm.deleteProfile(goneId);

      expect((await repo.getAllProfiles()).map((ProfileRow r) => r.id), <int>[
        keepId,
      ]);
      // 新代库：这个 uid 的集合一行不剩（rows 是内核按表清单现数的总行数；集合删掉之后数出来是全 0）。
      expect((await footprintOf(goneUid)).rows, 0);
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
        core: fresh.core,
        profileUid: goneUid,
        deviceId: 'dev2',
        engine: const SrsTestEngine(),
      );
      final Directory restoredMedia = Directory(
        p.join(support.path, 'restored_media'),
      );
      // 新代 `.fushisrs` 第 2 版：来自另一个复习库的文件要用户确认才并入（G11-3）；导入页会问，这里答是。
      final List<SrsFushiSrsForeign> asked = <SrsFushiSrsForeign>[];
      final SrsFushiSrsImport imported = await srsImportFushiSrs(
        restored,
        backup,
        mediaRoot: restoredMedia,
        confirmForeign: (SrsFushiSrsForeign f) async {
          asked.add(f);
          return true;
        },
      );
      expect(asked, hasLength(1));
      expect(imported.declined, isFalse);
      expect(imported.applied, greaterThan(0));
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

  // 新代：协议 3 的完成标记（`profile_orphan_sweep_v1` / `…_v3`）不算数——迁移把协议 3 库里的无主 uid 各迁成一个集合，
  // 新代库要按自己的标记（`profile_orphan_sweep_g4`）再扫一次，经同一个 `profile_purge` 清干净。
  test(
    'a protocol-3 sweep marker does not count in generation 4: the sweep runs '
    'once more and clears orphan collections; the live profile keeps every row',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      // 协议 3 时代留下的无主 uid（迁移后成了一个集合）。
      const String residue = '0193a1b2-0000-7000-8000-00000000ad09';
      await seed(residue, notes: 2, reviews: 1);
      expect((await footprintOf(residue)).rows, greaterThan(0));
      // 协议 3 已经扫过的标记（随 srs_meta 留在库里）。
      for (final String old in <String>[
        'profile_orphan_sweep_v1',
        'profile_orphan_sweep_v3',
      ]) {
        storage.core.debugExecRaw(
          'INSERT INTO srs_meta (key, value) VALUES (?, ?)',
          <Object>[old, '1'],
        );
      }
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
      final SrsProfileFootprint liveBefore = await footprintOf(liveUid);
      final int liveMeta = await metaOf(liveUid);

      expect(await vm.sweepOrphanProfileData(), 1);

      expect((await srsStoredProfiles(storage.core)).uids, <String>[liveUid]);
      expect((await footprintOf(residue)).rows, 0);
      expect(await metaOf(residue), 0);
      expect(await footprintOf(liveUid), liveBefore);
      expect(await metaOf(liveUid), liveMeta);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);

      // 再扫一次：什么都不变。
      expect(await vm.sweepOrphanProfileData(), 0);
      expect(await footprintOf(liveUid), liveBefore);
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
      storage.core.debugExecRaw(
        'INSERT INTO srs_meta (key, value) VALUES (?, ?)',
        <Object>['profile_merge/$oldUid', '{"profileId":1,"newUid":"$newUid"}'],
      );
      final SrsProfileFootprint oldBefore = await footprintOf(oldUid);
      final SrsProfileFootprint newBefore = await footprintOf(newUid);

      expect(await vm.sweepOrphanProfileData(), 1);

      expect(await footprintOf(oldUid), oldBefore);
      expect(await footprintOf(newUid), newBefore);
      expect((await footprintOf(orphan)).rows, 0);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
    },
  );

  /// 只剩本机状态行（`local_state/<uid>`）、没有集合的 uid：新代里「表里一行不剩、只剩 meta 键」的样子。不为它开
  /// 副本——开了就有集合了。
  Future<void> leaveStateOnly(String uid) async {
    storage.core.debugExecRaw(
      "INSERT INTO srs_meta (key, value) VALUES (?, '{}')",
      <Object>['local_state/$uid'],
    );
    expect((await footprintOf(uid)).rows, 0);
    expect(await metaOf(uid), 1);
  }

  /// `srs_meta` 里 [key] 这一行在不在。
  Future<bool> hasMeta(String key) async =>
      (await storage.core
              .customSelect(
                'SELECT COUNT(*) AS c FROM srs_meta WHERE key = ?',
                variables: <Variable<Object>>[Variable<String>(key)],
              )
              .getSingle())
          .read<int>('c') ==
      1;

  // 新代的收尾（内核 `orphan_sweep_done`）：没有集合、只剩本机状态行的无主 uid 也清掉（没有行可备份）；别的
  // `srs_meta` 键（设备提示等不按 profile 分的）不动；新代没有 `sync2_deps`，回收数恒为 0。
  test(
    'the sweep clears state-only orphan uids without a backup; other meta keys '
    'and the live profile stay; re-running finds nothing',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      const String device = '0193a1b2-0000-7000-8000-0000000d0001';
      const String gone = '0193a1b2-0000-7000-8000-00000000a0e1';
      const String hint = 'sync2_device_hint/$device';
      storage.core.debugExecRaw(
        "INSERT INTO srs_meta (key, value) VALUES (?, '{}')",
        <Object>[hint],
      );
      await leaveStateOnly(gone);
      expect((await srsStoredProfiles(storage.core)).uids, <String>[liveUid]);
      final SrsProfileFootprint liveBefore = await footprintOf(liveUid);
      final int liveMeta = await metaOf(liveUid);

      expect(await vm.sweepOrphanProfileData(), 1);

      expect(await metaOf(gone), 0);
      expect(await metaOf(liveUid), liveMeta);
      expect(await hasMeta(hint), isTrue);
      expect(await footprintOf(liveUid), liveBefore);
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
      final SrsProfileFootprint liveAfter = await footprintOf(liveUid);
      expect(liveAfter.notes, liveBefore.notes + 1);

      // 已扫过：不再跑。
      expect(await vm.sweepOrphanProfileData(), 0);
      // 幂等：去掉完成标记硬再扫一遍，也没有可清的、什么都不变。
      storage.core.debugExecRaw(
        "DELETE FROM srs_meta WHERE key = 'profile_orphan_sweep_g4'",
      );
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
      expect(await vm.sweepOrphanProfileData(), 0);
      expect(await footprintOf(liveUid), liveAfter);
      expect(await metaOf(liveUid), liveMeta);
      expect(await hasMeta(hint), isTrue);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);
    },
  );

  test(
    'the state row of an unfinished merge target stays until the merge '
    'finishes; an unrelated state-only orphan is cleared meanwhile',
    () async {
      final ProfileViewModel vm = await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 0);
      // 迁移带过来的半截并入：标记在，目标 uid 在本机还没有集合，只剩它的本机状态行。
      const String target = '0193a1b2-0000-7000-8000-0000000002e0';
      const String gone = '0193a1b2-0000-7000-8000-0000000003e0';
      await leaveStateOnly(target);
      await leaveStateOnly(gone);
      storage.core.debugExecRaw(
        'INSERT INTO srs_meta (key, value) VALUES (?, ?)',
        <Object>[
          'profile_merge/$liveUid',
          '{"profileId":1,"newUid":"$target"}',
        ],
      );
      final SrsProfileFootprint liveBefore = await footprintOf(liveUid);
      final int liveMeta = await metaOf(liveUid);

      expect(await vm.sweepOrphanProfileData(), 1);

      expect(await metaOf(target), 1, reason: 'merge target is not an orphan');
      expect(await metaOf(gone), 0);
      expect(await footprintOf(liveUid), liveBefore);
      expect(await metaOf(liveUid), liveMeta, reason: 'merge marker kept');
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);

      // 并入不做了（标记撤掉）、目标 uid 也没成为本机 profile：下一次扫描才把它当无主清掉，并记完成。
      storage.core.debugExecRaw('DELETE FROM srs_meta WHERE key = ?', <Object>[
        'profile_merge/$liveUid',
      ]);
      expect(await vm.sweepOrphanProfileData(), 1);
      expect(await metaOf(target), 0);
      expect(await footprintOf(liveUid), liveBefore);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNotNull);
    },
  );

  test(
    'with no live profile uid to compare against the sweep deletes nothing',
    () async {
      await loadedVm();
      final String liveUid = await uidOf(await repo.getActiveProfileId());
      await activeStore();
      await seed(liveUid, notes: 1, reviews: 1);
      const String other = '0193a1b2-0000-7000-8000-0000000004d0';
      await seed(other, notes: 1, reviews: 0);
      final SrsProfileFootprint liveBefore = await footprintOf(liveUid);
      final SrsProfileFootprint otherBefore = await footprintOf(other);

      // 主库一行 profile 都没读出来：判定不了谁活着。
      expect(await newCleanup().sweepOrphans(const <ProfileRow>[]), 0);

      expect(await footprintOf(liveUid), liveBefore);
      expect(await footprintOf(other), otherBefore);
      expect((await srsStoredProfiles(storage.core)).orphanSweptAt, isNull);
      expect(backups.existsSync(), isFalse);
    },
  );

  // G9-5 复核：删 profile 时内核核对「用户确认的就是这个集合」（`profile_purge` 的 `collection`）。准备（给用户看规模、
  // 导出备份）之后、真正删除之前 profile 改绑到了别的集合（这里：本机目录名比对方大，按 D27 并入对方并改绑）——
  // 删除报错，库里这个 profile 的数据一条不少。
  test('G9-5: the purge checks the collection the user confirmed; a rebind in '
      'between makes it fail and deletes nothing', () async {
    await loadedVm();
    final int goneId = await repo.createProfile('B');
    final String goneUid = await uidOf(goneId);
    await activeStore();
    await seed(goneUid, notes: 2, reviews: 1);
    final ProfileRow row = (await repo.getAllProfiles()).firstWhere(
      (ProfileRow r) => r.id == goneId,
    );
    final ProfileDeletionCleanup cleanup = await newCleanup().prepare(row);
    final Map<String, Object?> adopted = storage.core.sync2(<String, Object?>{
      'op': 'collection_adopt',
      'profile': goneUid,
      'collection': '0193a1b2-0000-7000-8000-00000000f00d',
      'dir': '00000000-0000-7000-8000-000000000000',
      'confirmed': true,
      'now': DateTime(2026, 10, 27, 9, 31).millisecondsSinceEpoch,
    }).map;
    expect(adopted['outcome'], 'joined', reason: '$adopted');
    final SrsProfileFootprint before = await srsProfileFootprint(
      storage.core,
      goneUid,
    );
    expect(before.notes, 2);

    await expectLater(cleanup.run(), throwsA(anything));
    expect(await srsProfileFootprint(storage.core, goneUid), before);
  });
}
