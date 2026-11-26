/// 还原点页 / 控制通道要列的全部「能回到过去」的副本：还原点存储里的点（更新前、回滚前、
/// 定时、操作前；默认目录与自定义文件夹），加上存量的两种整库副本——覆盖导入前快照
/// （`fushi.db.pre-overwrite.bak`）与「检查数据库」的备份（`fushi.db.check-bak-<ms>.db`）。
///
/// 存量副本原样留在原处、按原有规则过期 / 删除，这里只是一并列出来，能「补回缺少的内容」、
/// 导出、删除；「替换」只对还原点存储里的点开放（回滚日志认的是还原点 id）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 一条副本的来源。
enum RestorePointEntrySource {
  /// 还原点存储里的点（[RestorePointEntry.point] 非空）。
  store,

  /// 覆盖导入成功后保留的覆盖前快照。
  preOverwrite,

  /// 「检查数据库」动手前的整库备份。
  databaseCheck,
}

/// 还原点页的一行。
class RestorePointEntry {
  const RestorePointEntry({
    required this.id,
    required this.source,
    required this.path,
    required this.createdAt,
    required this.sizeBytes,
    this.point,
    this.schema,
  });

  /// 还原点 id，或存量副本的文件名。
  final String id;
  final RestorePointEntrySource source;

  /// 还原点目录，或存量副本文件。
  final String path;
  final DateTime createdAt;
  final int sizeBytes;
  final RestorePoint? point;

  /// 主库副本的 schema（还原点元数据里的；存量副本为 null = 未读）。
  final int? schema;

  /// 种类名（还原点的 wire 名，或 `pre_overwrite` / `db_check`），控制通道与测试用。
  String get kindName => switch (source) {
    RestorePointEntrySource.store => point!.kind.wire,
    RestorePointEntrySource.preOverwrite => 'pre_overwrite',
    RestorePointEntrySource.databaseCheck => 'db_check',
  };

  /// 主库原始副本（能直接当库打开的那份）；定时备份是 zip，没有。
  String? get rawMainDatabasePath => switch (source) {
    RestorePointEntrySource.store => point!.rawDatabasePath(
      RestorePointDatabase.fushi,
    ),
    _ => path,
  };

  /// 定时还原点的整包备份 zip。
  String? get archivePath => point?.archivePath;

  /// 这一行里的主库副本本版本打不打得开（schema 在可升级区间、不比本版本新）。schema 未知
  /// （存量副本、损坏库的回滚前副本记的 0）按「打得开」对待以外的情况见 [canReplace]。
  bool get schemaSupported {
    final int? s = schema;
    if (s == null) return true;
    return s >= kMinSupportedSchemaVersion && s <= kFushiDbSchemaVersion;
  }

  /// 「补回缺少的内容」：有主库副本（或 zip 里有）且本版本打得开。
  bool get canFillIn =>
      (rawMainDatabasePath != null || archivePath != null) && schemaSupported;

  /// 「替换」：只对还原点存储里的点，且 schema 确知可用。
  bool get canReplace =>
      source == RestorePointEntrySource.store &&
      (rawMainDatabasePath != null ||
          archivePath != null ||
          point!.rawDatabasePath(RestorePointDatabase.srs) != null) &&
      schema != null &&
      schema! > 0 &&
      schemaSupported;
}

/// 列出 [dbDirectory] 下的全部副本，新的在前。[extraRoots] 是另外的还原点根（自动备份的自定义
/// 文件夹）；与默认目录相同或不存在的忽略。
List<RestorePointEntry> listRestorePointEntries({
  required String dbDirectory,
  List<String> extraRoots = const <String>[],
}) {
  final List<RestorePointEntry> out = <RestorePointEntry>[];
  final RestorePointStore main = RestorePointStore(dbDirectory);
  final Set<String> seenRoots = <String>{p.normalize(main.root)};
  final List<RestorePointStore> stores = <RestorePointStore>[
    main,
    for (final String root in extraRoots)
      if (seenRoots.add(p.normalize(root)))
        RestorePointStore(dbDirectory, rootDirectory: root),
  ];
  for (final RestorePointStore store in stores) {
    for (final RestorePoint point in store.list()) {
      out.add(
        RestorePointEntry(
          id: point.id,
          source: RestorePointEntrySource.store,
          path: point.directory,
          createdAt: point.createdAt.toLocal(),
          sizeBytes: point.totalBytes,
          point: point,
          schema: point.fromSchema,
        ),
      );
    }
  }
  final Directory dir = Directory(dbDirectory);
  if (dir.existsSync()) {
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      final RestorePointEntrySource? source =
          name == databasePreOverwriteSnapshotFileName
          ? RestorePointEntrySource.preOverwrite
          : isDatabaseCheckBackupFileName(name)
          ? RestorePointEntrySource.databaseCheck
          : null;
      if (source == null) continue;
      final FileStat st = e.statSync();
      out.add(
        RestorePointEntry(
          id: name,
          source: source,
          path: e.path,
          createdAt: _checkBackupTime(name) ?? st.modified,
          sizeBytes: st.size,
        ),
      );
    }
  }
  out.sort(
    (RestorePointEntry a, RestorePointEntry b) =>
        b.createdAt.compareTo(a.createdAt),
  );
  return out;
}

/// `fushi.db.check-bak-<ms>.db` 里的时刻。
DateTime? _checkBackupTime(String name) {
  final RegExpMatch? m = RegExp(r'check-bak-(\d+)\.db$').firstMatch(name);
  if (m == null) return null;
  final int? ms = int.tryParse(m.group(1)!);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

/// 删掉一行：还原点删目录，存量副本删文件。
void deleteRestorePointEntry(RestorePointEntry entry) {
  if (entry.source == RestorePointEntrySource.store) {
    final Directory dir = Directory(entry.path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    return;
  }
  final File f = File(entry.path);
  if (f.existsSync()) f.deleteSync();
}
