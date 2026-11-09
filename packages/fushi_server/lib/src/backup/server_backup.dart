/// 服务端整机备份 / 还原（`fushi_server backup`、admin API `/api/admin/backups`）。
///
/// 备份的是**这台服务端自己**：换机器 / 重装 / 回滚时原样恢复，而不是 app 的
/// 「备份 → 在另一台设备上合并」那套（那套与 app 的模块、SRS、本地音频强耦合，见
/// `fushi/lib/src/sync/backup_service.dart`）。包是一个 zip：
///
/// ```
/// manifest.json                 格式标记、创建时间、数据库 schema、是否含 documents/
/// config/fushi_server.yaml      配置文件（含 admin_token / 凭据——备份文件要当密钥保管）
/// data/support/fushi.db         数据库：`VACUUM INTO` 出的一致快照（serve 在跑也安全）
/// data/support/srs.db           复习库（有才带）：Rust `VACUUM INTO` 的一致快照，设备本地表照留
///                               （整机还原是同一台设备，同步游标 / 设备 id 要原样回来）
/// data/<其余数据目录文件>        互联身份 / TLS / 配对、词典、任务、寄存的配置方案……
/// ```
///
/// 不进包：`tmp/`、`logs/`、`backups/`（备份自己）、数据目录锁文件、主库与复习库的
/// `-wal` / `-shm` / `-journal`（快照已含）。`documents/`（书 / 封面 / 有声书 / 下载）
/// 体积大，可用 `includeDocuments: false` 跳过——只剩设置与状态，还原后库里的条目会
/// 指向缺失的文件，需要重新扫描 / 下载。
///
/// 还原只在离线时做（拿数据目录锁，serve 在跑就拒绝）：新数据先解到旁边的暂存目录，
/// 再把现有数据目录的内容整体挪到 `<data_dir>.pre-restore-<时间>/`，最后把暂存内容
/// 挪进来；任何一步失败都挪回去。旧数据不删，确认无误后由用户自己删。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_storage.dart' show kSrsDatabaseFileName;
import 'package:fushi_engine/utils/archive/native_zip.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_data_lock.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;
import 'package:path/path.dart' as p;
import 'package:fushi_server/src/server_language.dart';

/// manifest 里的格式标记。
const String kServerBackupFormat = 'fushi_server_backup';

/// 当前包格式版本（读侧只认 ≤ 它的）。
const int kServerBackupFormatVersion = 1;

const String _manifestEntry = 'manifest.json';
const String _configEntry = 'config/fushi_server.yaml';
const String _dataPrefix = 'data/';

/// 数据目录里不进备份的顶层项。
const Set<String> _excludedTopLevel = <String>{
  'tmp',
  'logs',
  kServerBackupDirName,
  kServerLockFileName,
};

/// 数据目录下存放 admin API 生成的备份的子目录。
const String kServerBackupDirName = 'backups';

/// 主库、复习库及其伴生文件（快照替代它们）。
final Set<String> _liveDbFiles = <String>{
  for (final String db in <String>[fushiDatabaseFileName, kSrsDatabaseFileName])
    for (final String suffix in <String>['', '-wal', '-shm', '-journal'])
      '$db$suffix',
};

/// 把复习库一致地快照到 [path]（必须不存在）。serve 在跑时由 `ServerSrs.snapshotInto` 走它那份打开的连接。
typedef ServerSrsSnapshot = Future<void> Function(String path);

/// 没有在跑的复习库连接时（离线 `backup create`）：临时打开 srs.db 快照完就关。
Future<void> _snapshotSrsOffline(String source, String path) =>
    Isolate.run<void>(() {
      final SrsCore core = SrsCore.open(source);
      try {
        core.snapshotInto(path, stripDeviceLocal: false);
      } finally {
        core.close();
      }
    });

class ServerBackupException implements Exception {
  const ServerBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份包的 manifest。
class ServerBackupManifest {
  const ServerBackupManifest({
    required this.formatVersion,
    required this.createdAt,
    required this.schemaVersion,
    required this.includesDocuments,
    required this.hasConfig,
  });

  final int formatVersion;
  final DateTime createdAt;
  final int schemaVersion;
  final bool includesDocuments;
  final bool hasConfig;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': kServerBackupFormat,
    'formatVersion': formatVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'schemaVersion': schemaVersion,
    'includesDocuments': includesDocuments,
    'hasConfig': hasConfig,
  };

  static ServerBackupManifest parse(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw ServerBackupException(
        tr('manifest.json 不是 JSON', 'manifest.json is not JSON'),
      );
    }
    if (json is! Map || json['format'] != kServerBackupFormat) {
      throw ServerBackupException(
        tr('不是 fushi_server 备份包', 'Not a fushi_server backup archive'),
      );
    }
    final Object? version = json['formatVersion'];
    final Object? schema = json['schemaVersion'];
    final DateTime? created = DateTime.tryParse('${json['createdAt']}');
    if (version is! int || schema is! int || created == null) {
      throw ServerBackupException(
        tr('manifest.json 字段不全', 'manifest.json is missing fields'),
      );
    }
    return ServerBackupManifest(
      formatVersion: version,
      createdAt: created,
      schemaVersion: schema,
      includesDocuments: json['includesDocuments'] == true,
      hasConfig: json['hasConfig'] == true,
    );
  }
}

/// 本构建的数据库 schema 版本。
int currentServerSchemaVersion() {
  final FushiDatabase probe = FushiDatabase.forTesting(NativeDatabase.memory());
  final int v = probe.schemaVersion;
  // 没跑过查询的库不会真打开连接；close 只是放掉执行器。
  probe.close();
  return v;
}

/// 生成一份备份到 [output]（先写 `.partial`，成功后改名）。返回写出的文件。
///
/// [db] 是正在用的库（serve 在跑时就是它那份连接）：`VACUUM INTO` 在它上面跑，
/// 得到一致快照，不用停服。复习库同理：[snapshotSrs] 给了（serve 在跑、复习库开着）就走那份连接，
/// 否则 `support/srs.db` 存在时临时打开它出快照。
Future<File> createServerBackup({
  required FushiDatabase db,
  required String dataDir,
  required File? configFile,
  required File output,
  bool includeDocuments = true,
  ServerSrsSnapshot? snapshotSrs,
  DateTime? now,
}) async {
  final Directory data = Directory(dataDir);
  final Directory scratch = Directory(p.join(dataDir, 'tmp'));
  await scratch.create(recursive: true);
  final File snapshot = File(
    p.join(scratch.path, 'backup-${DateTime.now().microsecondsSinceEpoch}.db'),
  );
  final File srsSnapshot = File('${snapshot.path}.srs');
  final File liveSrs = File(p.join(dataDir, 'support', kSrsDatabaseFileName));
  final File partial = File('${output.path}.partial');
  try {
    await db.customStatement(
      "VACUUM INTO '${snapshot.path.replaceAll("'", "''")}'",
    );
    bool hasSrs = false;
    if (snapshotSrs != null) {
      await snapshotSrs(srsSnapshot.path);
      hasSrs = true;
    } else if (liveSrs.existsSync()) {
      await _snapshotSrsOffline(liveSrs.path, srsSnapshot.path);
      hasSrs = true;
    }
    final Map<String, String> entries = <String, String>{
      '${_dataPrefix}support/$fushiDatabaseFileName': snapshot.path,
      if (hasSrs)
        '${_dataPrefix}support/$kSrsDatabaseFileName': srsSnapshot.path,
      for (final MapEntry<String, String> e in _dataFiles(
        data,
        includeDocuments: includeDocuments,
      ).entries)
        e.key: e.value,
    };
    final bool hasConfig = configFile != null && configFile.existsSync();
    if (hasConfig) entries[_configEntry] = configFile.path;
    final ServerBackupManifest manifest = ServerBackupManifest(
      formatVersion: kServerBackupFormatVersion,
      createdAt: now ?? DateTime.now(),
      schemaVersion: db.schemaVersion,
      includesDocuments: includeDocuments,
      hasConfig: hasConfig,
    );
    await output.parent.create(recursive: true);
    // 包里有 admin_token、TLS 私钥、配对令牌、排行榜恢复码：先建空文件收紧到属主
    // 读写再写内容（打开已存在文件写入不改权限，rename 也保留），不留可读窗口。
    await partial.writeAsBytes(const <int>[], flush: true);
    await restrictServerBackupPath(partial.path, '600');
    await _writeZip(
      outputPath: partial.path,
      manifestJson: jsonEncode(manifest.toJson()),
      entries: entries,
    );
    if (output.existsSync()) await output.delete();
    return await partial.rename(output.path);
  } finally {
    if (snapshot.existsSync()) await snapshot.delete();
    if (srsSnapshot.existsSync()) await srsSnapshot.delete();
    if (partial.existsSync()) await partial.delete();
  }
}

/// 数据目录里要进包的文件：zip 条目名 → 源路径。
Map<String, String> _dataFiles(
  Directory data, {
  required bool includeDocuments,
}) {
  final Map<String, String> out = <String, String>{};
  if (!data.existsSync()) return out;
  for (final FileSystemEntity top in data.listSync(followLinks: false)) {
    final String name = p.basename(top.path);
    if (_excludedTopLevel.contains(name)) continue;
    if (!includeDocuments && name == 'documents') continue;
    final Iterable<FileSystemEntity> files = top is Directory
        ? top.listSync(recursive: true, followLinks: false)
        : <FileSystemEntity>[top];
    for (final FileSystemEntity f in files) {
      if (f is! File) continue;
      final String rel = p.relative(f.path, from: data.path);
      final List<String> parts = p.split(rel);
      if (parts.length == 2 &&
          parts.first == 'support' &&
          _liveDbFiles.contains(parts.last)) {
        continue;
      }
      out['$_dataPrefix${parts.join('/')}'] = f.path;
    }
  }
  return out;
}

/// 在后台 isolate 写 zip（大文件 STORE 流式、CRC 走原生；manifest 原生 deflate）。
/// 参数全是可跨 isolate 的值，别在这里引用外层对象。
Future<void> _writeZip({
  required String outputPath,
  required String manifestJson,
  required Map<String, String> entries,
}) => Isolate.run(() {
  final ZipFileEncoder encoder = ZipFileEncoder()..create(outputPath);
  try {
    encoder.addArchiveFile(
      nativeDeflatedArchiveFile(_manifestEntry, utf8.encode(manifestJson)),
    );
    for (final MapEntry<String, String> e in entries.entries) {
      final File f = File(e.value);
      // 备份期间被删掉的文件（serve 在跑时的临时产物）直接跳过。
      if (!f.existsSync()) continue;
      addFileStored(encoder, f, e.key);
    }
  } finally {
    encoder.closeSync();
  }
});

/// 读备份包的 manifest（不解包）。
ServerBackupManifest readServerBackupManifest(File backup) {
  final InputFileStream input = InputFileStream(backup.path);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    final ArchiveFile? entry = archive.findFile(_manifestEntry);
    if (entry == null) {
      throw ServerBackupException(
        tr('包里没有 manifest.json', 'The archive has no manifest.json'),
      );
    }
    return ServerBackupManifest.parse(utf8.decode(entry.content as List<int>));
  } on FormatException {
    throw ServerBackupException(tr('不是有效的 zip', 'Not a valid zip'));
  } finally {
    input.closeSync();
  }
}

/// 还原结果。
class ServerRestoreResult {
  const ServerRestoreResult({
    required this.manifest,
    required this.previousData,
    required this.previousConfig,
  });

  final ServerBackupManifest manifest;

  /// 还原前的数据目录内容挪到了这里（没有旧数据时为 null）。
  final Directory? previousData;

  /// 还原前的配置文件副本（没还原配置时为 null）。
  final File? previousConfig;
}

/// 把 [backup] 还原到 [dataDir]（调用方已持有数据目录锁，且库没打开）。
///
/// [configFile] 非 null 且包里带配置时，配置也还原：旧配置先存成
/// `<config>.pre-restore-<时间>`，新配置的 `data_dir` 改成本机这份（包里那份是
/// 备份机器上的绝对路径）。
Future<ServerRestoreResult> restoreServerBackup({
  required File backup,
  required String dataDir,
  required File? configFile,
  DateTime? now,
}) async {
  final ServerBackupManifest manifest = readServerBackupManifest(backup);
  if (manifest.formatVersion > kServerBackupFormatVersion) {
    throw ServerBackupException(
      tr(
        '备份包格式 v${manifest.formatVersion} 比本版本新，先升级 fushi_server',
        'Backup format v${manifest.formatVersion} is newer than this version; upgrade fushi_server first',
      ),
    );
  }
  final int schema = currentServerSchemaVersion();
  if (manifest.schemaVersion > schema) {
    throw ServerBackupException(
      tr(
        '备份里的数据库 schema v${manifest.schemaVersion} 比本版本（v$schema）新，'
            '先升级 fushi_server 再还原',
        'The database schema v${manifest.schemaVersion} in the backup is newer than this version (v$schema); '
            'upgrade fushi_server before restoring',
      ),
    );
  }
  final String stamp = _stamp(now ?? DateTime.now());
  final Directory data = Directory(dataDir);
  final Directory staging = Directory('$dataDir.restore-$stamp');
  final Directory previous = Directory('$dataDir.pre-restore-$stamp');
  if (staging.existsSync() || previous.existsSync()) {
    throw ServerBackupException(
      tr(
        '目标已存在：${staging.path} / ${previous.path}',
        'Target already exists: ${staging.path} / ${previous.path}',
      ),
    );
  }
  try {
    // 暂存目录先建好并收紧：解出来的凭据文件在恢复权限前不对其他用户可见。
    await staging.create(recursive: true);
    await restrictServerBackupPath(staging.path, '700');
    final _ExtractedBackup extracted = await _extractInIsolate(
      backup.path,
      staging.path,
    );
    await _restoreOwnerOnlyModes(extracted.ownerOnlyModes);
    // 配置在动数据目录之前解析：包里配置坏了要在「什么都没改」时就拒绝，
    // 不能换完数据才发现配置写不回去。
    final String? configText = extracted.config;
    ServerConfig? restored;
    if (configFile != null && configText != null) {
      try {
        restored = ServerConfig.parse(
          configText,
          configDir: configFile.parent.path,
        ).copyWith(dataDir: dataDir);
      } on FormatException catch (e) {
        throw ServerBackupException(
          tr(
            '包里的配置文件无效：${e.message}',
            'Invalid config file in the archive: ${e.message}',
          ),
        );
      }
    }
    final List<String> moved = <String>[];
    final List<String> placed = <String>[];
    await data.create(recursive: true);
    try {
      for (final FileSystemEntity e in data.listSync(followLinks: false)) {
        if (p.basename(e.path) == kServerLockFileName) continue;
        await previous.create(recursive: true);
        await e.rename(p.join(previous.path, p.basename(e.path)));
        moved.add(p.basename(e.path));
      }
      for (final FileSystemEntity e in staging.listSync(followLinks: false)) {
        await e.rename(p.join(dataDir, p.basename(e.path)));
        placed.add(p.basename(e.path));
      }
    } catch (e) {
      for (final String name in placed.reversed) {
        await _entity(p.join(dataDir, name)).delete(recursive: true);
      }
      for (final String name in moved.reversed) {
        await _entity(
          p.join(previous.path, name),
        ).rename(p.join(dataDir, name));
      }
      if (previous.existsSync() && previous.listSync().isEmpty) {
        await previous.delete();
      }
      throw ServerBackupException(
        tr('还原失败，已恢复原数据：$e', 'Restore failed, original data recovered: $e'),
      );
    }
    File? previousConfig;
    if (configFile != null && restored != null) {
      if (configFile.existsSync()) {
        previousConfig = await configFile.copy(
          '${configFile.path}.pre-restore-$stamp',
        );
      }
      await restored.save(configFile);
    }
    return ServerRestoreResult(
      manifest: manifest,
      previousData: moved.isEmpty ? null : previous,
      previousConfig: previousConfig,
    );
  } finally {
    if (staging.existsSync()) await staging.delete(recursive: true);
  }
}

FileSystemEntity _entity(String path) =>
    FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);

/// 解包结果：包里的配置文本（没有为 null）+ 备份时只给属主读写的文件（解出路径 →
/// 权限位）。
class _ExtractedBackup {
  const _ExtractedBackup(this.config, this.ownerOnlyModes);

  final String? config;
  final Map<String, int> ownerOnlyModes;
}

/// 后台 isolate 解包。只传字符串：闭包别捕获调用方的局部变量（同 app 的 BUG-1929）。
Future<_ExtractedBackup> _extractInIsolate(
  String backupPath,
  String stagingPath,
) => Isolate.run(() => _extractBackup(backupPath, stagingPath));

/// 把包里 `data/` 下的条目解到 [stagingPath]。越界条目（zip-slip）直接判坏包。
///
/// 条目带着备份时的 unix 权限位（[addFileStored] 写进 zip）。解出的文件一律按 umask
/// 落盘，所以把「组 / 其他用户无任何权限」的那批（TLS 私钥、配对令牌、排行榜账户、
/// 媒体服务器凭据……都按 0600 落盘）记下来，由调用方恢复——否则还原一次凭据就变成
/// 其他用户可读。
_ExtractedBackup _extractBackup(String backupPath, String stagingPath) {
  Directory(stagingPath).createSync(recursive: true);
  final InputFileStream input = InputFileStream(backupPath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    String? config;
    bool sawDb = false;
    final Map<String, int> ownerOnly = <String, int>{};
    for (final ArchiveFile f in archive.files) {
      if (f.name == _configEntry) {
        config = utf8.decode(f.content as List<int>);
        continue;
      }
      if (!f.isFile || f.isSymbolicLink || !f.name.startsWith(_dataPrefix)) {
        continue;
      }
      final String rel = f.name.substring(_dataPrefix.length);
      final String? target = zipEntryOutputPath(stagingPath, rel);
      if (target == null) {
        throw ServerBackupException(
          tr(
            '包里有越界路径：${f.name}',
            'The archive contains an out-of-bounds path: ${f.name}',
          ),
        );
      }
      final bool isDb = rel == 'support/$fushiDatabaseFileName';
      Directory(p.dirname(target)).createSync(recursive: true);
      extractZipEntryToFile(f, target);
      if (isDb) {
        _checkSqliteHeader(target);
        sawDb = true;
      }
      final int perm = f.mode & 0x1FF;
      if (perm != 0 && (perm & 0x3F) == 0) ownerOnly[target] = perm;
    }
    if (!sawDb) {
      throw ServerBackupException(tr('包里没有数据库', 'The archive has no database'));
    }
    return _ExtractedBackup(config, ownerOnly);
  } finally {
    input.closeSync();
  }
}

/// SQLite 3 数据库文件头（16 字节，含结尾的 NUL）。
const String _sqliteHeader = 'SQLite format 3\u0000';

/// 包里的数据库不是 SQLite 文件就判坏包：换进数据目录之前拒绝，而不是换完才在
/// 下次启动时打不开库。
void _checkSqliteHeader(String path) {
  final RandomAccessFile raf = File(path).openSync();
  try {
    final List<int> head = raf.readSync(_sqliteHeader.length);
    if (String.fromCharCodes(head) != _sqliteHeader) {
      throw ServerBackupException(
        tr(
          '包里的数据库不是有效的 SQLite 文件',
          'The database in the archive is not a valid SQLite file',
        ),
      );
    }
  } finally {
    raf.closeSync();
  }
}

/// POSIX 上把 [path] 设成 [mode]（八进制串，如 `600` / `700`）。备份包与暂存目录装着
/// 全部凭据，chmod 失败就报错，不留一份其他用户可读的副本（与 `sync_commands.dart`
/// 落 token 同一条纪律）。Windows 没有 chmod，靠用户目录 ACL。
Future<void> restrictServerBackupPath(String path, String mode) async {
  if (Platform.isWindows) return;
  final ProcessResult r = await Process.run('chmod', <String>[mode, path]);
  if (r.exitCode != 0) {
    throw ServerBackupException(
      tr(
        'chmod $mode 失败（${r.stderr}）：$path',
        'chmod $mode failed (${r.stderr}): $path',
      ),
    );
  }
}

/// 按 [modes]（路径 → 权限位）恢复属主专用文件的权限，同一权限位合成一次 chmod。
Future<void> _restoreOwnerOnlyModes(Map<String, int> modes) async {
  if (Platform.isWindows || modes.isEmpty) return;
  final Map<int, List<String>> byMode = <int, List<String>>{};
  for (final MapEntry<String, int> e in modes.entries) {
    (byMode[e.value] ??= <String>[]).add(e.key);
  }
  for (final MapEntry<int, List<String>> e in byMode.entries) {
    final String mode = e.key.toRadixString(8);
    final ProcessResult r = await Process.run('chmod', <String>[
      mode,
      ...e.value,
    ]);
    if (r.exitCode != 0) {
      throw ServerBackupException(
        tr('chmod $mode 失败（${r.stderr}）', 'chmod $mode failed (${r.stderr})'),
      );
    }
  }
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// admin API 生成的备份文件名。
String serverBackupFileName(DateTime t) =>
    'fushi_server-backup-${_stamp(t)}.zip';
