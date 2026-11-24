// 追踪站点的「不合并」系列卡清单（`media_tracking_<site>_book_series_merge_declined_v1`，BUG-5373）
// 存的是本机合集自增 id：按后缀登记进 [PrefRedactionPolicy.deviceLocalKeySuffixes]，与其它设备本地键
// 走同一个谓词——备份导出剔除、恢复保留本机值、不进 Profile 快照 / 分享、不经设置同步出境。
// 键名直接取 [TrackingProviderPrefKeys]（含 Bangumi 冻结名与插件站点的展开名），键形一改这里就跟着红。
//
// 走真实的 BackupService.createBackup → BackupRestoreService.restoreBackup。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/settings_sync.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show kTrackingProviderBangumi;
import 'package:fushi_engine/media/tracking/media_tracking_service.dart'
    show TrackingProviderPrefKeys;
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

final String _plugin = TrackingProviderPrefKeys.forProvider(
  'bookmeter',
).seriesMergeDeclined;
final String _bangumi = TrackingProviderPrefKeys.forProvider(
  kTrackingProviderBangumi,
).seriesMergeDeclined;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_series_declined_');
  });

  tearDown(() => cleanupTempDir(tmp));

  Future<Directory> dir(String name) =>
      Directory(p.join(tmp.path, name)).create(recursive: true);

  test('各站点的「不合并」键都是设备本地：备份 / Profile / 设置同步共用的谓词都认', () {
    for (final String key in <String>[_plugin, _bangumi]) {
      expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue);
      expect(ProfileKeys.isExcludedPref(key), isTrue);
      expect(PortableSettingsPolicy.isPortable(key), isFalse);
    }
  });

  test('同站点的其它追踪键不被后缀误伤', () {
    final TrackingProviderPrefKeys keys = TrackingProviderPrefKeys.forProvider(
      'bookmeter',
    );
    expect(
      PrefRedactionPolicy.isDeviceLocalOrCredential(keys.enabled),
      isFalse,
    );
  });

  /// 来源设备：带着「不合并」清单与一条普通设置，经真实导出得到一个备份包。
  Future<String> exportFromDevice() async {
    final Directory src = await dir('src');
    final FushiDatabase db = FushiDatabase(src.path);
    await db.setPref(_plugin, '3,7');
    await db.setPref(_bangumi, '5');
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

  test('导出的包里没有「不合并」清单（直接解包检查，不经导入侧）', () async {
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
    expect(await packed.getPref(_plugin), isNull);
    expect(await packed.getPref(_bangumi), isNull);
    expect(await packed.getPref('reader_font_size'), isNotNull);
  });

  test('恢复到别的设备：保留那台设备自己的清单，不换成来源设备的合集 id', () async {
    final String zipPath = await exportFromDevice();
    final Directory device = await dir('device');
    final FushiDatabase local = FushiDatabase(device.path);
    await local.setPref(_plugin, '42');
    await local.close();

    await BackupRestoreService.restoreBackup(
      dbDirectory: device.path,
      zipPath: zipPath,
    );

    final FushiDatabase restored = FushiDatabase(device.path);
    addTearDown(restored.close);
    expect(await restored.getPref(_plugin), '42');
    expect(await restored.getPref(_bangumi), isNull);
    expect(
      await restored.getPrefTyped<int>('reader_font_size', 0),
      19,
      reason: '普通设置照常恢复',
    );
  });
}
