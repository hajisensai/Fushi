// 复习备份控制器：从外部文件恢复别的 profile 的备份（采用身份 / 换化身 / 失败回滚 / 本机已有该 profile）。
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
import 'package:path/path.dart' as p;

import 'srs_test_support.dart';

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
  late int profileId;
  late SrsDbStore current;
  late File backupFile;
  late String backupUid;
  late String noteId;
  int reopenFailures = 0;

  Future<SrsDbStore> openCurrent() async => SrsDbStore.open(
    db: local,
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
    final SrsDbStore src = await SrsDbStore.open(
      db: source,
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
    final QueryRow c = await local
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
}
