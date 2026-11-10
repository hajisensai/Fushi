// 复习翻日时刻的待写标记（`srs_day_rollover_pending::<uid>`）与已见修改记录（`srs_day_rollover_seen::<uid>`）
// 是这台设备自己的状态（BUG-4284 / PR #3130）：按前缀登记进 [PrefRedactionPolicy.deviceLocalKeyPrefixes]，
// 于是与其它设备本地键走同一个谓词——备份导出剔除、恢复保留本机值、不进 Profile 快照 / 分享、不经设置同步出境。
//
// 走真实的 BackupService.createBackup → BackupRestoreService.restoreBackup。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/settings_sync.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

const String _pending = '${kSrsDayRolloverPendingPrefKeyPrefix}profile-a';
const String _seen = '${kSrsDayRolloverSeenPrefKeyPrefix}profile-a';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_day_rollover_prefs_');
  });

  tearDown(() => cleanupTempDir(tmp));

  Future<Directory> dir(String name) =>
      Directory(p.join(tmp.path, name)).create(recursive: true);

  test('两个前缀登记为设备本地：备份 / Profile 快照与分享 / 设置同步共用的谓词都认它们', () {
    for (final String key in <String>[_pending, _seen]) {
      expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue);
      expect(ProfileKeys.isExcludedPref(key), isTrue);
      expect(PortableSettingsPolicy.isPortable(key), isFalse);
    }
  });

  /// 来源设备：带着待写标记、已见记录与一条普通设置，经真实导出得到一个备份包。
  Future<String> exportFromDevice() async {
    final Directory src = await dir('src');
    final FushiDatabase db = FushiDatabase(src.path);
    await db.setPrefTyped<int>(_pending, 6);
    await db.setPrefTyped<String>(_seen, 'edit-from-src');
    await db.setPrefTyped<int>('reader_font_size', 19);
    final String zipPath = p.join(tmp.path, 'backup.zip');
    await BackupService(
      db: db,
      dbDirectory: src.path,
      appVersion: '1.0.0',
    ).createBackup(zipPath);
    await db.close();
    return zipPath;
  }

  test('导出的包里没有这两个键（直接解包检查，不经导入侧）', () async {
    final String zipPath = await exportFromDevice();
    final Directory unpacked = await dir('unpacked');
    final ArchiveFile entry = ZipDecoder()
        .decodeBytes(File(zipPath).readAsBytesSync())
        .files
        .firstWhere((ArchiveFile f) => f.name == fushiDatabaseFileName);
    File(
      p.join(unpacked.path, fushiDatabaseFileName),
    ).writeAsBytesSync(entry.content as List<int>);
    final FushiDatabase packed = FushiDatabase(unpacked.path);
    addTearDown(packed.close);
    expect(await packed.getPref(_pending), isNull);
    expect(await packed.getPref(_seen), isNull);
    expect(await packed.getPref('reader_font_size'), isNotNull);
  });

  test('带着待写标记做备份 → 恢复到一份全新偏好后标记不存在', () async {
    final String zipPath = await exportFromDevice();
    final Directory fresh = await dir('fresh');
    await FushiDatabase(fresh.path).close();

    await BackupRestoreService.restoreBackup(
      dbDirectory: fresh.path,
      zipPath: zipPath,
    );

    final FushiDatabase restored = FushiDatabase(fresh.path);
    addTearDown(restored.close);
    expect(await restored.getPref(_pending), isNull);
    expect(await restored.getPref(_seen), isNull);
    expect(
      await restored.getPrefTyped<int>('reader_font_size', 0),
      19,
      reason: '普通设置照常恢复',
    );
  });

  test('恢复时保留本机自己的标记（与其它设备本地键同一对称规则）', () async {
    final String zipPath = await exportFromDevice();
    final Directory device = await dir('device');
    final FushiDatabase local = FushiDatabase(device.path);
    await local.setPrefTyped<int>(_pending, 2);
    await local.close();

    await BackupRestoreService.restoreBackup(
      dbDirectory: device.path,
      zipPath: zipPath,
    );

    final FushiDatabase restored = FushiDatabase(device.path);
    addTearDown(restored.close);
    expect(await restored.getPrefTyped<int>(_pending, -1), 2);
    expect(await restored.getPref(_seen), isNull);
  });
}
