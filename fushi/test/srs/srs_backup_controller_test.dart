// 复习备份控制器：从外部文件恢复别的 profile 的备份（采用身份 / 换化身 / 失败回滚 / 本机已有该 profile）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_backup.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;

import 'srs_test_support.dart';

/// list() 卡在 [gate] 上的备份库：模拟「控制器在 await 期间被释放」。
class _GatedBackups extends SrsBackupStore {
  _GatedBackups({
    required super.root,
    required super.profileUid,
    required super.mediaDir,
    required this.gate,
  });

  final Future<void> gate;

  @override
  Future<List<SrsBackupInfo>> list() async {
    await gate;
    return super.list();
  }
}

Future<int> _insertProfile(FushiDatabase db, String name) async {
  final int now = DateTime.now().millisecondsSinceEpoch;
  await db.customStatement(
    'INSERT INTO profiles (name, created_at, updated_at) VALUES (?, ?, ?)',
    <Object>[name, now, now],
  );
  final QueryRow r = await db
      .customSelect(
        'SELECT id FROM profiles WHERE name = ?',
        variables: <Variable<Object>>[Variable<String>(name)],
      )
      .getSingle();
  return r.read<int>('id');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  late FushiDatabase local;
  late SrsStorage localSrs;
  late int profileId;
  late SrsDbStore current;
  late File backupFile;
  late String backupUid;
  late String noteId;
  int reopenFailures = 0;

  Future<SrsDbStore> openCurrent() async => SrsDbStore.open(
    db: localSrs.db,
    core: localSrs.core,
    profileUid: await local.profileUidOf(profileId),
    deviceId: 'dev',
    engine: const SrsTestEngine(),
  );

  SrsBackupStore backupsOf(String uid) => SrsBackupStore(
    root: Directory(p.join(tmp.path, 'srs_backups')),
    profileUid: uid,
    mediaDir: Directory(p.join(tmp.path, 'srs_media', uid)),
  );

  late SrsBackupController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('srs_bk_ctl_');
    reopenFailures = 0;
    // 另一台设备：一个有笔记的 profile，做一份备份。
    final FushiDatabase source = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final int srcId = await _insertProfile(source, '日语');
    backupUid = await source.profileUidOf(srcId);
    final SrsStorage sourceSrs = await openSrsTestStorage();
    final SrsDbStore src = await SrsDbStore.open(
      db: sourceSrs.db,
      core: sourceSrs.core,
      profileUid: backupUid,
      deviceId: 'other',
      engine: const SrsTestEngine(),
    );
    noteId = await src.createNote(
      noteTypeId: src.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(backupUid, 'Expression'): '雪',
      },
    );
    final SrsBackupInfo info = await SrsBackupStore(
      root: Directory(p.join(tmp.path, 'source_backups')),
      profileUid: backupUid,
      mediaDir: Directory(p.join(tmp.path, 'none')),
    ).create(src, kind: SrsBackupKind.manual, profileName: '日语');
    backupFile = info.file;
    await source.close();

    // 本机：新装，一个空 profile。
    local = FushiDatabase.forTesting(NativeDatabase.memory());
    localSrs = await openSrsTestStorage();
    profileId = await _insertProfile(local, '默认');
    current = await openCurrent();
    controller = SrsBackupController(
      readStore: () async => current,
      readBackups: () async => backupsOf(current.profileUid),
      autoEnabled: () => true,
      limits: () => const SrsBackupLimits(),
      profileName: (String uid) async => '默认',
    );
  });

  tearDown(() async {
    controller.dispose();
    await local.close();
    await tmp.delete(recursive: true);
  });

  Future<SrsBackupRestoreOutcome?> restoreFile() => controller.restoreFile(
    backupFile,
    db: local,
    srs: localSrs,
    activeProfileId: () async => profileId,
    reopenStore: () async {
      if (reopenFailures > 0) {
        reopenFailures--;
        throw StateError('injected reopen failure');
      }
      current = await openCurrent();
    },
  );

  test('新装设备：采用备份的 profile 身份、换新的写入者化身，再恢复', () async {
    final String oldWriter = current.writerId;
    final SrsBackupRestoreOutcome? r = await restoreFile();
    expect(r, isNotNull);
    expect(await local.profileUidOf(profileId), backupUid);
    expect(current.profileUid, backupUid);
    expect((await current.note(noteId))!.deletedAt, isNull);
    final int incarnation = int.parse(current.writerId.split('#').last);
    expect(incarnation, greaterThan(1000000), reason: '不沿用 dev#1 这类小号');
    expect(current.writerId, isNot(oldWriter));
    expect(
      (await current.unpublishedEvents()).map((e) => e.id),
      contains(noteId),
    );
  });

  test('采用后恢复失败：uid 换回原来的，库里不留备份 profile 的行', () async {
    final String originalUid = current.profileUid;
    reopenFailures = 1;
    await expectLater(restoreFile(), throwsStateError);
    expect(await local.profileUidOf(profileId), originalUid);
    expect(current.profileUid, originalUid);
    final QueryRow c = await localSrs.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_entities WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(backupUid)],
        )
        .getSingle();
    expect(c.read<int>('c'), 0);
  });

  test('备份属于本机另一个 profile：提示切过去，不再采用（uid 唯一）', () async {
    final int other = await _insertProfile(local, '日语');
    await local.adoptProfileUid(other, backupUid);
    await expectLater(
      restoreFile(),
      throwsA(
        isA<SrsRestoreOtherLocalProfile>().having(
          (SrsRestoreOtherLocalProfile e) => e.profileName,
          'profileName',
          '日语',
        ),
      ),
    );
    expect(current.profileUid, isNot(backupUid));
  });

  test('当前 profile 已有用户笔记：拒绝，数据不混进来', () async {
    await current.createNote(
      noteTypeId: current.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(current.profileUid, 'Expression'): '雨',
      },
    );
    await expectLater(restoreFile(), throwsA(isA<SrsRestoreProfileMismatch>()));
    expect(await current.note(noteId), isNull);
  });

  group('自动备份定时器', () {
    const int base = 1760000000000;
    late int nowMs;
    late SrsBackupLimits limits;
    late bool auto;
    late SrsBackupController c;

    Future<void> addNote(String text) => current.createNote(
      noteTypeId: current.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(current.profileUid, 'Expression'): text,
      },
    );

    setUp(() {
      nowMs = base;
      limits = const SrsBackupLimits();
      auto = true;
      c = SrsBackupController(
        readStore: () async => current,
        readBackups: () async => backupsOf(current.profileUid),
        autoEnabled: () => auto,
        limits: () => limits,
        profileName: (String uid) async => '默认',
        nowMs: () => nowMs,
      );
    });
    tearDown(() => c.dispose());

    test('间隔变更：作废按旧间隔挂起的定时器，按新间隔重排；关掉开关只作废', () async {
      await addNote('雪');
      expect(await c.backupNow(), isNotNull);
      await addNote('雨');

      nowMs = base + 60 * 1000;
      await c.scheduleCheck();
      expect(c.pendingTimerDueAtMs, base + 30 * 60 * 1000);

      // 改成 60 分钟：旧定时器（30 分钟到点）作废，按新间隔重排。
      limits = const SrsBackupLimits(intervalMinutes: 60);
      await c.reschedule();
      expect(c.pendingTimerDueAtMs, base + 60 * 60 * 1000);

      // 改成 5 分钟、且已过 10 分钟：新间隔下早该备份了 → 立即备份，不再挂定时器。
      nowMs = base + 10 * 60 * 1000;
      limits = const SrsBackupLimits(intervalMinutes: 5);
      await c.reschedule();
      expect(c.pendingTimerDueAtMs, isNull);
      expect(await backupsOf(current.profileUid).list(), hasLength(2));

      // 关掉自动备份：挂起的定时器作废，不再排。
      await addNote('風');
      nowMs = base + 11 * 60 * 1000;
      await c.scheduleCheck();
      expect(c.pendingTimerDueAtMs, isNotNull);
      auto = false;
      await c.reschedule();
      expect(c.pendingTimerDueAtMs, isNull);
    });

    test('await 期间控制器被释放：不再挂定时器', () async {
      await addNote('雪');
      await backupsOf(
        current.profileUid,
      ).create(current, kind: SrsBackupKind.manual, profileName: '默认');
      final Completer<void> gate = Completer<void>();
      final SrsBackupController gated = SrsBackupController(
        readStore: () async => current,
        readBackups: () async => _GatedBackups(
          root: Directory(p.join(tmp.path, 'srs_backups')),
          profileUid: current.profileUid,
          mediaDir: Directory(p.join(tmp.path, 'srs_media')),
          gate: gate.future,
        ),
        autoEnabled: () => true,
        limits: () => const SrsBackupLimits(),
        profileName: (String uid) async => '默认',
      );
      final Future<void> pending = gated.scheduleCheck();
      await Future<void>.delayed(Duration.zero);
      gated.dispose();
      gate.complete();
      await pending;
      expect(gated.pendingTimerDueAtMs, isNull);
    });
  });

  group('BUG-3579：自动备份给 SRS 界面让路', () {
    Future<void> addNote(String word) => current.createNote(
      noteTypeId: current.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(current.profileUid, 'Expression'): word,
      },
    );

    test('在用时不做自动备份；不用了立即补一份', () async {
      await addNote('雨');
      controller.onSrsInUse();
      expect(await controller.autoBackup(), isNull);
      expect(await backupsOf(current.profileUid).list(), isEmpty);
      controller.onSrsIdle();
      // onSrsIdle 的补备份排在串行队列里：再排一次就等到它做完。
      await controller.autoBackup();
      expect(await backupsOf(current.profileUid).list(), hasLength(1));
    });

    test('读快照中途叫停：不留备份与暂存文件，事务结束、库照常可读', () async {
      await addNote('雪');
      final SrsBackupStore backups = backupsOf(current.profileUid);
      int asked = 0;
      await expectLater(
        backups.create(
          current,
          kind: SrsBackupKind.auto,
          profileName: '默认',
          shouldStop: () => ++asked > 1,
        ),
        throwsA(isA<SrsBackupCancelled>()),
      );
      expect(asked, 2, reason: '第一页读完就停');
      expect(await backups.list(), isEmpty);
      final List<FileSystemEntity> left = backups.profileDir.existsSync()
          ? backups.profileDir.listSync()
          : const <FileSystemEntity>[];
      expect(left, isEmpty, reason: '暂存文件已删');
      expect(await current.deckSummaries(), isNotEmpty);
    });

    test('上一次没做完留下的暂存文件，下一次备份时清掉', () async {
      await addNote('風');
      final SrsBackupStore backups = backupsOf(current.profileUid);
      await backups.profileDir.create(recursive: true);
      final File staleEvents = File(
        p.join(backups.profileDir.path, '.old-auto.events.tmp'),
      )..writeAsStringSync('x');
      final File staleTimes = File(
        p.join(backups.profileDir.path, '.old-auto.server_times.tmp'),
      )..writeAsStringSync('x');
      await backups.create(
        current,
        kind: SrsBackupKind.manual,
        profileName: '默认',
      );
      expect(staleEvents.existsSync(), isFalse);
      expect(staleTimes.existsSync(), isFalse);
      expect(await backups.list(), hasLength(1));
    });
  });
}
