import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 跨包名迁移必须把「设备本地」数据一起搬走（改名迁移 · BUG-1476 次因）。
///
/// 共享备份剥离设备本地表与凭据类 pref 是对的——那个前提是「产物会离开本机」。
/// 迁移不是：同一台机器、同一个用户、只换包名。沿用剥离的后果是用户迁完必须
/// 手工重配互联配对、同步后端、漫画源。所以导出侧要能显式关掉剥离，且**默认
/// 仍然剥**（普通备份行为一步不变）。
Future<String> _extractDbFromZip(String zipPath, Directory into) async {
  final InputFileStream input = InputFileStream(zipPath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    for (final ArchiveFile f in archive) {
      if (f.name == 'hibiki.db') {
        final String out = p.join(into.path, 'hibiki.db');
        await File(out).writeAsBytes(f.content as List<int>);
        return out;
      }
    }
  } finally {
    input.closeSync();
  }
  throw StateError('备份归档里没有 hibiki.db');
}

Future<Map<String, String>> _prefsInBackup(
    String zipPath, Directory workDir) async {
  final String dbFile = await _extractDbFromZip(zipPath, workDir);
  final HibikiDatabase db = HibikiDatabase(p.dirname(dbFile));
  try {
    return await db.getAllPrefs();
  } finally {
    await db.close();
  }
}

void main() {
  late Directory srcDir;
  late Directory zipDir;

  setUp(() async {
    srcDir = await Directory.systemTemp.createTemp('mig_src_');
    zipDir = await Directory.systemTemp.createTemp('mig_zip_');
  });

  tearDown(() async {
    for (final Directory d in <Directory>[srcDir, zipDir]) {
      if (d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  Future<void> seedDeviceLocalPref(HibikiDatabase db) => db.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>['download_save_root', '/storage/emulated/0/Download'],
      );

  test('默认导出仍然剥掉设备本地 pref（普通备份行为不变）', () async {
    final HibikiDatabase src = HibikiDatabase(srcDir.path);
    await seedDeviceLocalPref(src);
    final String zip = p.join(zipDir.path, 'shared.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).createBackup(zip);
    await src.close();

    final Directory work = await Directory.systemTemp.createTemp('mig_w1_');
    addTearDown(() {
      if (work.existsSync()) {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
    final Map<String, String> prefs = await _prefsInBackup(zip, work);
    expect(prefs.containsKey('download_save_root'), isFalse,
        reason: '共享备份会离开本机，设备本地/凭据类 pref 必须继续被剥');
  });

  test('迁移导出保留设备本地 pref（同机换包名，剥了用户就得重配）', () async {
    final HibikiDatabase src = HibikiDatabase(srcDir.path);
    await seedDeviceLocalPref(src);
    final String zip = p.join(zipDir.path, 'migration.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).createBackup(zip, keepDeviceLocalData: true);
    await src.close();

    final Directory work = await Directory.systemTemp.createTemp('mig_w2_');
    addTearDown(() {
      if (work.existsSync()) {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
    final Map<String, String> prefs = await _prefsInBackup(zip, work);
    expect(prefs['download_save_root'], '/storage/emulated/0/Download',
        reason: '迁移必须把设备本地数据一起搬走，否则互联/同步/漫画源全要重配');
  });
}
