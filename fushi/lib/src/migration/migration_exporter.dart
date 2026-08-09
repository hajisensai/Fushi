import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/migration/migration_manifest.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:path/path.dart' as p;

/// 迁移批次（改名迁移计划 P1-1）。顺序即导出顺序：DB/设置最小批先行，
/// 大文件树随后；`videos` 永不打包（原文件在共享目录，DB 存绝对路径，
/// Fushi 侧靠路径 rebase 接上）。
enum MigrationBatch {
  /// 进度 + 统计 + 设置 + Profile（无文件树，体积最小，最先到手）。
  core,

  /// 词典资源树。
  dictionaries,

  /// 书籍内容树（epub + 解包内容 + 封面）。
  books,

  /// 有声书音频 + 对齐文件。
  audiobooks,

  /// 自定义字体。
  fonts,

  /// 本地发音库（大，默认关）。
  localAudio,
}

/// 每批的 [BackupService] 类别集合。
///
/// 每批都带核心四类（progress/statistics/settings/profiles）：DB 始终整库随
/// 归档走，[BackupService] 的防幽灵语义会把「本批未带文件树」的内容行从 DB
/// 复制件剥除（如 books 未勾 → epub_books 行不travel），因此各内容行恰好随
/// **自己的批次**落地，合并引擎按业务键幂等 upsert，多批导入互不覆盖。
Set<BackupCategory> categoriesForBatch(MigrationBatch batch) {
  const Set<BackupCategory> core = <BackupCategory>{
    BackupCategory.progress,
    BackupCategory.statistics,
    BackupCategory.settings,
    BackupCategory.profiles,
  };
  return switch (batch) {
    MigrationBatch.core => core,
    MigrationBatch.dictionaries => <BackupCategory>{
        ...core,
        BackupCategory.dictionary
      },
    MigrationBatch.books => <BackupCategory>{...core, BackupCategory.books},
    MigrationBatch.audiobooks => <BackupCategory>{
        ...core,
        BackupCategory.audiobooks
      },
    MigrationBatch.fonts => <BackupCategory>{...core, BackupCategory.fonts},
    MigrationBatch.localAudio => <BackupCategory>{
        ...core,
        BackupCategory.localAudio
      },
  };
}

/// 一次迁移导出的批次规划。
class MigrationPlan {
  const MigrationPlan({required this.batches});

  final List<MigrationBatch> batches;
}

/// 单批导出结果。
class MigrationBatchResult {
  const MigrationBatchResult({
    required this.batch,
    required this.archivePath,
    required this.manifestPath,
    required this.manifest,
  });

  final MigrationBatch batch;
  final String archivePath;
  final String manifestPath;
  final MigrationManifest manifest;
}

/// 中转目录里的断点状态（`state.json`）。中断后从第一个未完成批继续。
class MigrationExportState {
  MigrationExportState({required this.completed});

  final Set<String> completed;

  static const String fileName = 'state.json';

  static MigrationExportState read(Directory transferDir) {
    final File f = File(p.join(transferDir.path, fileName));
    if (!f.existsSync()) return MigrationExportState(completed: <String>{});
    try {
      final Map<String, Object?> json =
          jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final Object? list = json['completed'];
      return MigrationExportState(
        completed: list is List ? list.cast<String>().toSet() : <String>{},
      );
    } catch (_) {
      // 状态文件损坏时从头来（导出幂等，只是多花时间），不让迁移卡死。
      return MigrationExportState(completed: <String>{});
    }
  }

  void write(Directory transferDir) {
    File(p.join(transferDir.path, fileName)).writeAsStringSync(
      jsonEncode(<String, Object?>{'completed': completed.toList()}),
      flush: true,
    );
  }
}

/// 跨包名迁移导出器（改名迁移计划 P1-1）。
///
/// 复用 [BackupService.createBackup] 按批次导出到中转目录；每批写
/// `<batch>.zip` + `<batch>.manifest.json`，完成后把批名记入 `state.json`
/// （断点续传）。导入方（Fushi）确认一批校验通过后删除该批文件。
class MigrationExporter {
  MigrationExporter({
    required BackupService backupService,
    required Directory transferDir,
    required String sourcePackage,
    required String sourceAppVersion,
    required int Function() nowMs,
  })  : _backup = backupService,
        _transferDir = transferDir,
        _sourcePackage = sourcePackage,
        _sourceAppVersion = sourceAppVersion,
        _nowMs = nowMs;

  final BackupService _backup;
  final Directory _transferDir;
  final String _sourcePackage;
  final String _sourceAppVersion;
  final int Function() _nowMs;

  static String archiveNameFor(MigrationBatch batch) => '${batch.name}.zip';

  static String manifestNameFor(MigrationBatch batch) =>
      '${batch.name}.manifest.json';

  /// 规划要导出的批次：核心批恒在；[includeLocalAudio] 默认关（计划 P1-1）。
  ///
  /// 空批（如没有有声书）也照常导出——其归档只带 DB 核心行，导入侧零成本，
  /// 换来「批次集合恒定」这个更简单的完成判据（没有特殊情况）。
  MigrationPlan planBatches({required bool includeLocalAudio}) {
    final List<MigrationBatch> batches = <MigrationBatch>[
      MigrationBatch.core,
      MigrationBatch.dictionaries,
      MigrationBatch.books,
      MigrationBatch.audiobooks,
      MigrationBatch.fonts,
      if (includeLocalAudio) MigrationBatch.localAudio,
    ];
    return MigrationPlan(batches: batches);
  }

  /// 导出单批：写归档 → 生成清单 → 记断点。已完成的批直接跳过（幂等），
  /// 返回 null 表示本批此前已完成且文件仍在。
  Future<MigrationBatchResult?> exportBatch(MigrationBatch batch) async {
    _transferDir.createSync(recursive: true);
    final MigrationExportState state = MigrationExportState.read(_transferDir);
    final String archivePath = p.join(_transferDir.path, archiveNameFor(batch));
    final String manifestPath =
        p.join(_transferDir.path, manifestNameFor(batch));
    if (state.completed.contains(batch.name) &&
        File(archivePath).existsSync() &&
        File(manifestPath).existsSync()) {
      return null;
    }
    // 半成品清理：上次中断可能留下损坏 zip。
    for (final String path in <String>[archivePath, manifestPath]) {
      final File f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    await _backup.createBackup(
      archivePath,
      categories: categoriesForBatch(batch),
    );
    final MigrationManifest manifest =
        await MigrationManifest.computeForArchive(
      archivePath: archivePath,
      batchName: batch.name,
      sourcePackage: _sourcePackage,
      sourceAppVersion: _sourceAppVersion,
      nowMs: _nowMs(),
      archiveContainsDb: true,
    );
    File(manifestPath).writeAsStringSync(manifest.encode(), flush: true);
    state.completed.add(batch.name);
    state.write(_transferDir);
    return MigrationBatchResult(
      batch: batch,
      archivePath: archivePath,
      manifestPath: manifestPath,
      manifest: manifest,
    );
  }
}
