import 'dart:io';

import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_manifest.dart';
import 'package:path/path.dart' as p;

/// 中转目录里一个待导入批次的解析结果。
class MigrationImportBatch {
  const MigrationImportBatch({
    required this.batch,
    required this.archivePath,
    required this.manifest,
  });

  final MigrationBatch batch;
  final String archivePath;
  final MigrationManifest manifest;
}

/// 扫描/校验结果：可导入批次 + 逐批问题（问题批**保留文件**，供老包重传）。
class MigrationScanResult {
  const MigrationScanResult({required this.ready, required this.problems});

  final List<MigrationImportBatch> ready;

  /// 批名 → 人类可读问题列表（归档缺失/损坏/清单坏）。
  final Map<String, List<String>> problems;

  bool get hasAnything => ready.isNotEmpty || problems.isNotEmpty;
}

/// Fushi 侧迁移导入器（改名迁移计划 P2-2）。
///
/// 职责：扫描老包写下的中转目录（`Documents/Hibiki/migration/`）→ 逐批
/// 归档完整性校验（清单 sha256+size）→ 交给调用方走 `BackupService.
/// mergeRestoreBackup` 逐批合并 → 合并后行数聚合校验 → 删除已导入批次文件。
/// **任一校验不符：该批标记失败、保留中转文件、绝不进入卸载流程**（计划红线）。
///
/// 不依赖 intent extra——用户手动点开 Fushi 也能触发（启动扫描 + 设置入口）。
class MigrationImporter {
  const MigrationImporter();

  /// 扫描中转目录：对每个 `<batch>.zip` + `<batch>.manifest.json` 齐全的批次
  /// 做归档完整性校验。缺清单/缺归档/校验不符 → 记入 problems。
  Future<MigrationScanResult> scan(Directory transferDir) async {
    final List<MigrationImportBatch> ready = <MigrationImportBatch>[];
    final Map<String, List<String>> problems = <String, List<String>>{};
    if (!transferDir.existsSync()) {
      return MigrationScanResult(ready: ready, problems: problems);
    }
    for (final MigrationBatch batch in MigrationBatch.values) {
      final File archive = File(
          p.join(transferDir.path, MigrationExporter.archiveNameFor(batch)));
      final File manifestFile = File(
          p.join(transferDir.path, MigrationExporter.manifestNameFor(batch)));
      if (!archive.existsSync() && !manifestFile.existsSync()) {
        continue; // 该批不存在（如 localAudio 默认不导）。
      }
      if (!manifestFile.existsSync()) {
        problems[batch.name] = <String>['清单缺失: ${manifestFile.path}'];
        continue;
      }
      final MigrationManifest manifest;
      try {
        manifest = MigrationManifest.decode(manifestFile.readAsStringSync());
      } catch (e) {
        problems[batch.name] = <String>['清单损坏: $e'];
        continue;
      }
      final List<String> archiveProblems =
          await manifest.verifyArchive(archive);
      if (archiveProblems.isNotEmpty) {
        problems[batch.name] = archiveProblems;
        continue;
      }
      ready.add(MigrationImportBatch(
        batch: batch,
        archivePath: archive.path,
        manifest: manifest,
      ));
    }
    return MigrationScanResult(ready: ready, problems: problems);
  }

  /// 全部已验证批次的行数聚合期望：同一张表取各批清单的最大值（core 行随每批
  /// 重复携带，内容行只在自己批次里非零；merge 幂等 upsert 后最终库应逐表
  /// **不少于**该期望）。
  static Map<String, int> aggregateExpectedCounts(
      Iterable<MigrationImportBatch> batches) {
    final Map<String, int> expected = <String, int>{};
    for (final MigrationImportBatch b in batches) {
      for (final MapEntry<String, int> e in b.manifest.tableCounts.entries) {
        final int prev = expected[e.key] ?? 0;
        if (e.value > prev) expected[e.key] = e.value;
      }
    }
    return expected;
  }

  /// 导入后聚合校验：目标库逐表行数不得低于 [expected]；返回差异描述（空=过）。
  static List<String> verifyImportedCounts({
    required String dbPath,
    required Map<String, int> expected,
  }) {
    final Map<String, int> actual = MigrationManifest.countTablesInDb(dbPath);
    final List<String> problems = <String>[];
    for (final MapEntry<String, int> e in expected.entries) {
      final int got = actual[e.key] ?? 0;
      if (got < e.value) {
        problems.add('表 ${e.key} 行数不足: 期望≥${e.value} 实际 $got');
      }
    }
    return problems;
  }

  /// 删除一个已成功导入批次的中转文件（归档 + 清单）。
  void deleteBatchFiles(Directory transferDir, MigrationBatch batch) {
    for (final String name in <String>[
      MigrationExporter.archiveNameFor(batch),
      MigrationExporter.manifestNameFor(batch),
    ]) {
      final File f = File(p.join(transferDir.path, name));
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// 全部批次导入完成后的中转目录收尾：只剩 state.json 等辅助文件时整目录删除；
  /// 仍有问题批（保留待重传）则不动。
  void cleanupTransferDirIfEmpty(Directory transferDir) {
    if (!transferDir.existsSync()) return;
    final bool hasBatchFiles = transferDir
        .listSync()
        .whereType<File>()
        .any((File f) => f.path.endsWith('.zip'));
    if (!hasBatchFiles) {
      try {
        transferDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
