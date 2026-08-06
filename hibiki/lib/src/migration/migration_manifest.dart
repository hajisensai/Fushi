import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// 跨包名迁移（Hibiki → Fushi）单批次清单。
///
/// 设计（改名迁移计划 P1-2）：导出侧为每个批次归档生成一份 JSON 清单，导入侧
/// （Fushi）在解包前后据此逐项校验，**任一项不符即判该批失败、保留中转文件、
/// 绝不进入卸载流程**。
///
/// v1 完整性模型（对计划的显式偏差，理由见迁移计划 §P1-2 更新）：
/// - 归档级 `size` + `sha256`（防中转目录截断/损坏/被第三方改动）——不做逐
///   entry 哈希：archive 3.x 逐 entry 取 content 需整块载入内存，书籍/有声书
///   批次可达 GB 级；整档哈希对传输完整性的防护等价。
/// - DB 批次另带 [tableCounts]（对计划列出的 14 张表逐表 COUNT），导入合并后
///   语义校验行数。
class MigrationManifest {
  const MigrationManifest({
    required this.version,
    required this.batch,
    required this.sourcePackage,
    required this.sourceAppVersion,
    required this.sourceSchemaVersion,
    required this.createdAt,
    required this.archiveSize,
    required this.archiveSha256,
    required this.tableCounts,
  });

  /// 清单格式版本；当前恒为 [currentVersion]。
  final int version;

  /// 批次名（`MigrationBatch.name`）。
  final String batch;

  /// 导出方包名（`app.fushi.reader`；用于导入侧甄别来源）。
  final String sourcePackage;

  /// 导出方 app 版本字符串。
  final String sourceAppVersion;

  /// 导出方 DB schema 版本；不含 DB 的批次为 null。
  final int? sourceSchemaVersion;

  /// 导出完成时刻（epoch 毫秒）。
  final int createdAt;

  /// 归档字节数。
  final int archiveSize;

  /// 归档整文件 SHA-256（十六进制小写）。
  final String archiveSha256;

  /// DB 内受核对表的行数（仅含 DB 的批次非空）。
  final Map<String, int> tableCounts;

  static const int currentVersion = 1;

  /// 计划 P1-2 点名的行数核对表（SQL 表名）。导出方 schema 缺某表时跳过该表
  /// （老版本升级路径），导入侧只比对双方都有的键。
  static const List<String> countedTables = <String>[
    'epub_books',
    'video_books',
    'reader_positions',
    'bookmarks',
    'reading_statistics',
    'reading_hourly_logs',
    'video_watch_statistics',
    'mining_statistics',
    'mined_sentences',
    'favorite_words',
    'profiles',
    'profile_settings',
    'media_type_profiles',
    'book_profiles',
  ];

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'batch': batch,
        'sourcePackage': sourcePackage,
        'sourceAppVersion': sourceAppVersion,
        'sourceSchemaVersion': sourceSchemaVersion,
        'createdAt': createdAt,
        'archiveSize': archiveSize,
        'archiveSha256': archiveSha256,
        'tableCounts': tableCounts,
      };

  factory MigrationManifest.fromJson(Map<String, Object?> json) {
    final Object? counts = json['tableCounts'];
    return MigrationManifest(
      version: (json['version'] as num).toInt(),
      batch: json['batch'] as String,
      sourcePackage: json['sourcePackage'] as String,
      sourceAppVersion: json['sourceAppVersion'] as String,
      sourceSchemaVersion: (json['sourceSchemaVersion'] as num?)?.toInt(),
      createdAt: (json['createdAt'] as num).toInt(),
      archiveSize: (json['archiveSize'] as num).toInt(),
      archiveSha256: json['archiveSha256'] as String,
      tableCounts: counts is Map
          ? counts.map((Object? k, Object? v) =>
              MapEntry<String, int>(k as String, (v as num).toInt()))
          : const <String, int>{},
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static MigrationManifest decode(String text) =>
      MigrationManifest.fromJson(json.decode(text) as Map<String, Object?>);

  /// 流式计算文件 SHA-256（十六进制小写），不整块载入内存。
  static Future<String> sha256OfFile(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 对归档做完整性校验（size + sha256）；一致返回空列表，否则返回人类可读的
  /// 差异描述（导入侧直接展示/记日志）。
  Future<List<String>> verifyArchive(File archive) async {
    final List<String> problems = <String>[];
    if (!archive.existsSync()) {
      return <String>['归档不存在: ${archive.path}'];
    }
    final int size = await archive.length();
    if (size != archiveSize) {
      problems.add('归档字节数不符: 期望 $archiveSize 实际 $size');
    }
    final String digest = await sha256OfFile(archive);
    if (digest != archiveSha256) {
      problems.add('归档 SHA-256 不符: 期望 $archiveSha256 实际 $digest');
    }
    return problems;
  }

  /// 与导入后重算的行数逐键比对（只比双方都有的表，见 [countedTables] 说明）；
  /// 一致返回空列表。
  List<String> diffTableCounts(Map<String, int> actual) {
    final List<String> problems = <String>[];
    for (final MapEntry<String, int> e in tableCounts.entries) {
      final int? got = actual[e.key];
      if (got == null) continue;
      if (got != e.value) {
        problems.add('表 ${e.key} 行数不符: 期望 ${e.value} 实际 $got');
      }
    }
    return problems;
  }

  /// 打开一个 SQLite 库并对 [countedTables] 里存在的表逐表 COUNT。
  ///
  /// [dbPath] 必须是**未被占用**的库文件（导出复制件 / 导入落地件）。
  static Map<String, int> countTablesInDb(String dbPath) {
    final sqlite.Database db =
        sqlite.sqlite3.open(dbPath, mode: sqlite.OpenMode.readOnly);
    try {
      final Set<String> existing = db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((sqlite.Row r) => r['name'] as String)
          .toSet();
      final Map<String, int> counts = <String, int>{};
      for (final String table in countedTables) {
        if (!existing.contains(table)) continue;
        final sqlite.ResultSet rs =
            db.select('SELECT COUNT(*) AS c FROM "$table"');
        counts[table] = (rs.first['c'] as num).toInt();
      }
      return counts;
    } finally {
      db.dispose();
    }
  }

  /// 读取 SQLite 库的 `PRAGMA user_version`（Drift schema 版本落在这里）。
  static int schemaVersionOfDb(String dbPath) {
    final sqlite.Database db =
        sqlite.sqlite3.open(dbPath, mode: sqlite.OpenMode.readOnly);
    try {
      return (db.select('PRAGMA user_version').first.values.first as num)
          .toInt();
    } finally {
      db.dispose();
    }
  }

  /// 从批次归档提取 DB（若含）并计算行数/版本。返回 (tableCounts,
  /// schemaVersion)；归档不含 [dbEntryName] 时返回空表 + null。
  ///
  /// 单独解出 DB entry 到临时目录再打开（DB 通常几十 MB，可接受）。
  static Future<(Map<String, int>, int?)> countsFromArchive(
    String archivePath, {
    String dbEntryName = 'hibiki.db',
  }) async {
    final InputFileStream input = InputFileStream(archivePath);
    Directory? tmp;
    try {
      final Archive zip = ZipDecoder().decodeBuffer(input);
      final ArchiveFile? entry = zip.files.cast<ArchiveFile?>().firstWhere(
          (ArchiveFile? f) => f!.name == dbEntryName,
          orElse: () => null);
      if (entry == null) return (const <String, int>{}, null);
      tmp = await Directory.systemTemp.createTemp('fushi_migration_manifest_');
      final String dbPath = p.join(tmp.path, dbEntryName);
      final OutputFileStream out = OutputFileStream(dbPath);
      entry.writeContent(out);
      await out.close();
      return (countTablesInDb(dbPath), schemaVersionOfDb(dbPath));
    } finally {
      await input.close();
      if (tmp != null) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 为已写好的批次归档生成清单（真相来自归档本身，不依赖导出时活库状态）。
  static Future<MigrationManifest> computeForArchive({
    required String archivePath,
    required String batchName,
    required String sourcePackage,
    required String sourceAppVersion,
    required int nowMs,
    bool archiveContainsDb = false,
    String dbEntryName = 'hibiki.db',
  }) async {
    final File archive = File(archivePath);
    final int size = await archive.length();
    final String digest = await sha256OfFile(archive);
    Map<String, int> counts = const <String, int>{};
    int? schemaVersion;
    if (archiveContainsDb) {
      (counts, schemaVersion) =
          await countsFromArchive(archivePath, dbEntryName: dbEntryName);
    }
    return MigrationManifest(
      version: currentVersion,
      batch: batchName,
      sourcePackage: sourcePackage,
      sourceAppVersion: sourceAppVersion,
      sourceSchemaVersion: schemaVersion,
      createdAt: nowMs,
      archiveSize: size,
      archiveSha256: digest,
      tableCounts: counts,
    );
  }
}
