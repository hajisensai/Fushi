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
import 'package:fushi/src/srs/srs_media_store.dart';
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

  ProfileViewModel newVm() => ProfileViewModel(
    repo,
    () async {},
    ProfileDraftCoordinator(),
    deletionCascade: SrsProfileCleanup(
      SrsProfileCleanupDeps(
        storage: () async => storage,
        activeStore: activeStore,
        deviceId: () async => 'dev',
        supportRoot: () async => support,
        backupRoot: () => backupRoot(),
        clock: () => DateTime(2026, 10, 27, 9, 30, 5),
      ),
    ),
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
        .customSelect(sql, variables: <Variable<Object>>[Variable<String>(uid)])
        .getSingle();
    return r.read<int>('c');
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
}
