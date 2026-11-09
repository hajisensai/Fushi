/// 把下载好的新版发布包换进正在运行的安装目录。
///
/// 做法（Linux / Windows 同一套）：新包解压到安装目录里的暂存目录（同一卷，rename
/// 不跨盘），再逐个文件「旧文件改名成 `*.fushi-old` → 新文件改名到位」。Windows
/// 不许覆盖或删除正在运行的 exe / 已加载的 DLL，但允许改名，所以必须先挪开再放入。
/// 动文件前先写换包日志；任何一步失败（含进程中途被杀，下次启动时）都按日志逆序
/// 还原，安装目录回到更新前的样子。
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

/// 换包日志：动第一个文件前写下整份计划，全部换完后删除。启动时还在 = 上次换到
/// 一半进程没了。
const String kServerUpdateJournalFile = '.fushi_update_journal.json';

/// 被挪开的旧文件后缀。
const String kServerUpdateOldSuffix = '.fushi-old';

/// 还原时删不掉（正在运行）的新文件改名挪开用的后缀。
const String kServerUpdateRollbackSuffix = '.fushi-rollback';

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

/// 一步换文件：[rel] 相对安装目录；[hadOld] = 换之前安装目录里已有同名文件（要先挪成
/// `*.fushi-old`）。
typedef _SwapStep = ({String rel, bool hadOld});

/// 把 [newBundle]（解压树里的 `fushi_server/`）里的每个文件换进 [installRoot]。
/// 成功后 [newBundle] 被掏空；失败抛出前已还原。
///
/// 崩溃安全：动第一个文件之前先把整份计划写进换包日志
/// [kServerUpdateJournalFile]，全部换完、待删清单落盘之后才删日志（删日志即提交）。
/// 中途进程被杀 / 断电，下次启动 [cleanupAfterServerUpdate] 见到日志就按它逆序还原，
/// 安装目录不会停在新旧混合的状态。[debugAfterStep] 是测试缝（第 i 步换完后调）。
Future<void> swapServerBundle({
  required Directory newBundle,
  required Directory installRoot,
  Future<void> Function(int step)? debugAfterStep,
}) async {
  final List<String> rels = <String>[
    for (final FileSystemEntity e in newBundle.listSync(recursive: true))
      if (e is File) p.relative(e.path, from: newBundle.path),
  ]..sort();
  if (rels.isEmpty) {
    throw const ServerUpdateException('bad_package', 'empty bundle');
  }
  // 1. 定计划。目标位置是目录等非文件 → 什么都不动直接拒（没法「挪开再放入」）。
  final List<_SwapStep> steps = <_SwapStep>[];
  for (final String rel in rels) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      p.join(installRoot.path, rel),
      followLinks: false,
    );
    if (type == FileSystemEntityType.directory) {
      throw ServerUpdateException(
        'install_failed',
        '$rel is a directory in the install dir',
      );
    }
    steps.add((rel: rel, hadOld: type != FileSystemEntityType.notFound));
  }
  // 2. 上次清理没删掉的同名旧文件先删：日志里每个 `*.fushi-old` 都必须是这一轮挪出来
  //    的，否则还原会把更早的版本放回去。
  try {
    for (final _SwapStep step in steps) {
      final File stale = File(_backupOf(installRoot, step.rel));
      if (stale.existsSync()) await stale.delete();
    }
  } on FileSystemException catch (e) {
    throw ServerUpdateException('install_failed', '$e');
  }
  // 3. 先落日志再动文件。
  final File journal = File(p.join(installRoot.path, kServerUpdateJournalFile));
  await _writeJsonAtomic(journal, <String, Object?>{
    'version': 1,
    'steps': <Object?>[
      for (final _SwapStep s in steps)
        <String, Object?>{'rel': s.rel, 'had_old': s.hadOld},
    ],
  });
  // 4. 逐个「旧的挪开 → 新的放入」。
  try {
    for (int i = 0; i < steps.length; i++) {
      final _SwapStep step = steps[i];
      final String dest = p.join(installRoot.path, step.rel);
      await Directory(p.dirname(dest)).create(recursive: true);
      if (step.hadOld) {
        await File(dest).rename(_backupOf(installRoot, step.rel));
      }
      await File(p.join(newBundle.path, step.rel)).rename(dest);
      await debugAfterStep?.call(i);
    }
  } catch (e) {
    final _RollBack rb = await _rollBack(installRoot, steps);
    for (final String path in rb.setAside) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // 下次启动按日志 / 清单再删。
      }
    }
    if (rb.failed == 0) {
      try {
        await journal.delete();
      } on FileSystemException {
        // 留着也无害：下次启动再按它还原一遍（幂等）。
      }
    }
    if (e is ServerUpdateException) rethrow;
    throw ServerUpdateException('install_failed', '$e');
  }
  // 5. 待删清单落盘，再删日志（提交点）。
  await _writeJsonAtomic(
    File(p.join(installRoot.path, kServerUpdateCleanupFile)),
    <String>[
      for (final _SwapStep s in steps)
        if (s.hadOld) _backupOf(installRoot, s.rel),
    ],
  );
  await journal.delete();
}

/// 启动时调用的结果。
typedef ServerUpdateCleanup = ({
  /// 没删掉 / 没还原成的条数（留到下次启动再试）。
  int failed,

  /// 上次换包没做完、这次按日志还原了。
  bool rolledBack,

  /// 还原动到了正在运行的可执行文件：此刻跑的是没换完的新版，必须重启才能回到旧版。
  bool restartRequired,
});

/// 启动时调：① 有换包日志（上次换到一半进程没了）→ 逆序还原；② 删上一次换包留下的
/// 旧文件与暂存目录。失败只计数，不抛。日志没还原完时不删暂存、不删日志，下次再来。
/// [runningExecutable] 是测试缝（默认当前进程的可执行文件）。
Future<ServerUpdateCleanup> cleanupAfterServerUpdate(
  Directory installRoot, {
  String? runningExecutable,
}) async {
  int failed = 0;
  bool rolledBack = false;
  bool restartRequired = false;
  final List<String> extraGarbage = <String>[];
  final File journal = File(p.join(installRoot.path, kServerUpdateJournalFile));
  if (journal.existsSync()) {
    final List<_SwapStep>? steps = _readJournal(journal, installRoot);
    if (steps == null) {
      // 读不懂的日志不敢瞎还原；保留现场（含暂存），只报出来。
      return (failed: 1, rolledBack: false, restartRequired: false);
    }
    final _RollBack rb = await _rollBack(installRoot, steps);
    final String exe = runningExecutable ?? Platform.resolvedExecutable;
    rolledBack = rb.reverted.isNotEmpty;
    restartRequired = rb.reverted.any((String d) => p.equals(d, exe));
    extraGarbage.addAll(rb.setAside);
    if (rb.failed > 0) {
      return (
        failed: rb.failed,
        rolledBack: rolledBack,
        restartRequired: restartRequired,
      );
    }
    try {
      await journal.delete();
    } on FileSystemException {
      return (
        failed: 1,
        rolledBack: rolledBack,
        restartRequired: restartRequired,
      );
    }
  }

  final File manifest = File(
    p.join(installRoot.path, kServerUpdateCleanupFile),
  );
  final List<Object?> listed = <Object?>[...extraGarbage];
  if (manifest.existsSync()) {
    try {
      final Object? decoded = jsonDecode(await manifest.readAsString());
      if (decoded is List) listed.addAll(decoded);
    } on FormatException {
      // 坏清单当空的。
    }
  }
  final List<String> left = <String>[];
  for (final Object? path in listed) {
    // 只删安装目录里、带换包后缀的条目：清单被改过也删不到别处。
    if (path is! String ||
        !(path.endsWith(kServerUpdateOldSuffix) ||
            path.endsWith(kServerUpdateRollbackSuffix)) ||
        !p.isWithin(installRoot.path, path)) {
      continue;
    }
    try {
      final File f = File(path);
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      left.add(path);
    }
  }
  failed += left.length;
  if (left.isEmpty) {
    if (manifest.existsSync()) await manifest.delete();
  } else {
    await _writeJsonAtomic(manifest, left);
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
  return (
    failed: failed,
    rolledBack: rolledBack,
    restartRequired: restartRequired,
  );
}

String _backupOf(Directory root, String rel) =>
    '${p.join(root.path, rel)}$kServerUpdateOldSuffix';

/// 还原结果：[reverted] = 动过的目标路径；[setAside] = 删不掉、改名挪开的新文件
/// （Windows 上正在运行的 exe 不能删，只能改名）；[failed] = 没还原成的步数。
typedef _RollBack = ({
  List<String> reverted,
  List<String> setAside,
  int failed,
});

/// 按 [steps] 逆序还原，幂等（已还原 / 还没换到的步骤自然跳过）：
///   * 原来有文件：`*.fushi-old` 还在 → 把占位的新文件挪走，旧文件改回原名；
///     不在 → 这一步还没换（或已还原），不动；
///   * 原来没有：现在有 → 是这一轮放进来的新文件，挪走。
Future<_RollBack> _rollBack(Directory root, List<_SwapStep> steps) async {
  final List<String> reverted = <String>[];
  final List<String> setAside = <String>[];
  int failed = 0;
  for (final _SwapStep step in steps.reversed) {
    final String dest = p.join(root.path, step.rel);
    final String backup = _backupOf(root, step.rel);
    try {
      final bool hasBackup =
          FileSystemEntity.typeSync(backup, followLinks: false) !=
          FileSystemEntityType.notFound;
      final bool hasDest =
          FileSystemEntity.typeSync(dest, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (step.hadOld && !hasBackup) continue;
      if (!step.hadOld && !hasDest) continue;
      if (hasDest) {
        final String? aside = await _removeOrSetAside(dest);
        if (aside != null) setAside.add(aside);
      }
      if (step.hadOld) await File(backup).rename(dest);
      reverted.add(dest);
    } on FileSystemException {
      failed++;
    }
  }
  return (reverted: reverted, setAside: setAside, failed: failed);
}

/// 删掉 [path]；删不掉（Windows 上正在运行的 exe / 已加载的 DLL）就改名成
/// `*.fushi-rollback` 挪开，返回挪去的路径。
Future<String?> _removeOrSetAside(String path) async {
  try {
    await File(path).delete();
    return null;
  } on FileSystemException {
    final String aside = '$path$kServerUpdateRollbackSuffix';
    final File stale = File(aside);
    if (stale.existsSync()) await stale.delete();
    await File(path).rename(aside);
    return aside;
  }
}

/// 解析换包日志；格式不对或条目越出安装目录 → null。
List<_SwapStep>? _readJournal(File journal, Directory root) {
  try {
    final Object? decoded = jsonDecode(journal.readAsStringSync());
    if (decoded is! Map || decoded['version'] != 1) return null;
    final Object? raw = decoded['steps'];
    if (raw is! List) return null;
    final List<_SwapStep> steps = <_SwapStep>[];
    for (final Object? e in raw) {
      if (e is! Map) return null;
      final Object? rel = e['rel'];
      final Object? hadOld = e['had_old'];
      if (rel is! String || hadOld is! bool) return null;
      if (p.isAbsolute(rel) || !p.isWithin(root.path, p.join(root.path, rel))) {
        return null;
      }
      steps.add((rel: rel, hadOld: hadOld));
    }
    return steps;
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// 先写临时文件再改名：被杀在半路也不会留下半截 JSON。
Future<void> _writeJsonAtomic(File file, Object? value) async {
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(value), flush: true);
  await tmp.rename(file.path);
}
