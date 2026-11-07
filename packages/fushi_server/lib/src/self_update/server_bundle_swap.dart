/// 把下载好的新版发布包换进正在运行的安装目录。
///
/// 做法（Linux / Windows 同一套）：新包解压到安装目录里的暂存目录（同一卷，rename
/// 不跨盘），再逐个文件「旧文件改名成 `*.fushi-old` → 新文件改名到位」。Windows
/// 不许覆盖或删除正在运行的 exe / 已加载的 DLL，但允许改名，所以必须先挪开再放入。
/// 任何一步失败按日志逆序还原，安装目录回到更新前的样子。
///
/// 只动新包里有的文件（`bin/`、`lib/`、`share/`、`README.md`、`release.json`）：
/// 配置文件、数据目录即使就放在安装目录里也不会被碰到。旧文件留到下次启动由
/// [cleanupAfterServerUpdate] 删除（此刻它们可能还被本进程占着）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 安装目录里的暂存目录名（下载包与解压树都在这里）。
const String kServerUpdateStagingDir = '.fushi_update';

/// 换包后留下的「待删旧文件」清单。
const String kServerUpdateCleanupFile = '.fushi_update_cleanup.json';

/// 被挪开的旧文件后缀。
const String kServerUpdateOldSuffix = '.fushi-old';

/// 发布包解压后的顶层目录名（`release-server.yml` 打包时的 `stage/fushi_server`）。
const String kServerBundleDirName = 'fushi_server';

/// 解包器：把 [archive] 解到 [destination]（测试缝；生产 = 系统 `tar`）。
typedef ServerArchiveExtractor =
    Future<void> Function(File archive, Directory destination);

/// 系统 `tar` 解包：Linux 解 `.tar.gz`（保留可执行位）；Windows 10+ 自带的
/// `System32\tar.exe`（bsdtar）能解 `.zip`。Windows 上显式用 System32 那份——PATH 上
/// 的 GNU tar（Git Bash）不认 zip。
Future<void> extractServerArchiveWithTar(
  File archive,
  Directory destination,
) async {
  await destination.create(recursive: true);
  final String tar = Platform.isWindows
      ? p.join(
          Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'System32',
          'tar.exe',
        )
      : 'tar';
  final ProcessResult r = await Process.run(tar, <String>[
    '-xf',
    archive.path,
    '-C',
    destination.path,
  ]);
  if (r.exitCode != 0) {
    throw ServerUpdateException(
      'extract_failed',
      'tar exited ${r.exitCode}: ${r.stderr}',
    );
  }
}

class ServerUpdateException implements Exception {
  const ServerUpdateException(this.code, [this.detail]);

  /// 写进 [HostUpdateStatus.error] 的短代码。
  final String code;
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'ServerUpdateException($code)' : '$code: $detail';
}

/// 把 [newBundle]（解压树里的 `fushi_server/`）里的每个文件换进 [installRoot]。
/// 成功后 [newBundle] 被掏空；失败抛出前已还原。
Future<void> swapServerBundle({
  required Directory newBundle,
  required Directory installRoot,
}) async {
  final List<String> rels = <String>[
    for (final FileSystemEntity e in newBundle.listSync(recursive: true))
      if (e is File) p.relative(e.path, from: newBundle.path),
  ]..sort();
  if (rels.isEmpty) {
    throw const ServerUpdateException('bad_package', 'empty bundle');
  }
  final List<String> backups = <String>[];
  final List<({String dest, String? backup})> done =
      <({String dest, String? backup})>[];
  try {
    for (final String rel in rels) {
      final String dest = p.join(installRoot.path, rel);
      await Directory(p.dirname(dest)).create(recursive: true);
      String? backup;
      if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
        backup = '$dest$kServerUpdateOldSuffix';
        final File stale = File(backup);
        if (stale.existsSync()) await stale.delete();
        await File(dest).rename(backup);
        backups.add(backup);
      }
      try {
        await File(p.join(newBundle.path, rel)).rename(dest);
      } catch (_) {
        if (backup != null) await File(backup).rename(dest);
        rethrow;
      }
      done.add((dest: dest, backup: backup));
    }
  } catch (e) {
    for (final ({String dest, String? backup}) step in done.reversed) {
      try {
        await File(step.dest).delete();
        if (step.backup != null) await File(step.backup!).rename(step.dest);
      } catch (_) {
        // 尽力还原；下面抛出原始错误。
      }
    }
    if (e is ServerUpdateException) rethrow;
    throw ServerUpdateException('install_failed', '$e');
  }
  await File(
    p.join(installRoot.path, kServerUpdateCleanupFile),
  ).writeAsString(jsonEncode(backups));
}

/// 启动时调：删上一次换包留下的旧文件与暂存目录。失败只返回没删掉的条数，不抛。
Future<int> cleanupAfterServerUpdate(Directory installRoot) async {
  int failed = 0;
  final File manifest = File(
    p.join(installRoot.path, kServerUpdateCleanupFile),
  );
  if (manifest.existsSync()) {
    List<Object?> listed = const <Object?>[];
    try {
      final Object? decoded = jsonDecode(await manifest.readAsString());
      if (decoded is List) listed = decoded;
    } on FormatException {
      listed = const <Object?>[];
    }
    for (final Object? path in listed) {
      // 只删安装目录里、带旧文件后缀的条目：清单被改过也删不到别处。
      if (path is! String ||
          !path.endsWith(kServerUpdateOldSuffix) ||
          !p.isWithin(installRoot.path, path)) {
        continue;
      }
      try {
        final File f = File(path);
        if (f.existsSync()) await f.delete();
      } on FileSystemException {
        failed++;
      }
    }
    if (failed == 0) await manifest.delete();
  }
  final Directory staging = Directory(
    p.join(installRoot.path, kServerUpdateStagingDir),
  );
  if (staging.existsSync()) {
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      failed++;
    }
  }
  return failed;
}
