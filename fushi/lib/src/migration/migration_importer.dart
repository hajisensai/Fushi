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
  const MigrationScanResult({
    required this.ready,
    required this.problems,
    this.storagePermissionGranted = true,
  });

  /// 缺「所有文件访问权限」时的结果：**不逐批扫**。
  ///
  /// 没权限时每一批都会在读清单那一步抛 `PathAccessException`，逐批扫的产物是
  /// N 条一模一样的「清单损坏」——既是假话（文件没坏），又把唯一该做的动作
  /// （去授权）淹没在批次列表里。所以把它提升成结果的顶层状态。
  const MigrationScanResult.permissionDenied()
      : ready = const <MigrationImportBatch>[],
        problems = const <String, List<String>>{},
        storagePermissionGranted = false;

  final List<MigrationImportBatch> ready;

  /// 批名 → 人类可读问题列表（归档缺失/损坏/清单坏）。
  final Map<String, List<String>> problems;

  /// 是否持有读中转目录所需的「所有文件访问权限」。
  final bool storagePermissionGranted;

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

  /// 中转目录里**是否存在**待导入数据。廉价：只看文件在不在。
  ///
  /// 与 [scan] 的分工是硬性的：这个回答「要不要显示导入入口」这种布尔问题，
  /// [scan] 回答「这些归档能不能信」。用 [scan] 去答布尔问题的代价是把中转目录
  /// 全量算一遍 SHA-256——实测 11GB 库让手机 CPU 满载跑近 7 分钟，而首页 banner
  /// 在 `initState` 和**每次回前台**都会问一次。用户什么都没干，手机一直在发烫。
  bool hasTransferData(Directory transferDir) {
    if (!transferDir.existsSync()) return false;
    try {
      return transferDir
          .listSync()
          .whereType<File>()
          .any((File f) => f.path.endsWith('.zip'));
    } on FileSystemException {
      // 列不出来 ≠ 没有（缺「所有文件访问权限」时就会这样）。这里返回 false
      // 会把入口藏起来，用户再也走不到能授权的那个页面去。保守显示。
      return true;
    }
  }

  /// 扫描中转目录：对每个 `<batch>.zip` + `<batch>.manifest.json` 齐全的批次
  /// 做归档完整性校验。缺清单/缺归档/校验不符 → 记入 problems。
  ///
  /// [onProgress] 在**每批开始校验前**回调 `(批次, 已完成数, 总数)`。这一步要对
  /// 中转目录全量算 SHA-256（实测 11GB 库在手机上要好几分钟，纯 Dart crypto 比
  /// 原生慢一个量级），调用方必须据此显示进度——只给一个转圈，用户无法把「正在
  /// 校验」和「卡死了」区分开。
  ///
  /// [permissionGranted] 传 false 表示缺「所有文件访问权限」：直接短路返回
  /// [MigrationScanResult.permissionDenied]，**不逐批扫**。否则每批都会在读清单
  /// 那一步抛 `PathAccessException`，产出 N 条一模一样的「清单损坏」——文件明明
  /// 完好，却告诉用户数据坏了，把他推向「重新导出」这条毫无用处的路。
  Future<MigrationScanResult> scan(
    Directory transferDir, {
    bool permissionGranted = true,
    void Function(MigrationBatch batch, int done, int total)? onProgress,
  }) async {
    if (!permissionGranted) {
      return const MigrationScanResult.permissionDenied();
    }
    final List<MigrationImportBatch> ready = <MigrationImportBatch>[];
    final Map<String, List<String>> problems = <String, List<String>>{};
    if (!transferDir.existsSync()) {
      return MigrationScanResult(ready: ready, problems: problems);
    }
    int done = 0;
    for (final MigrationBatch batch in MigrationBatch.values) {
      onProgress?.call(batch, done, MigrationBatch.values.length);
      done++;
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
      } on FileSystemException catch (e) {
        // 读不到 ≠ 内容坏了。中转目录是老包创建的，分区存储下没有「所有文件
        // 访问权限」就会在这里抛 PathAccessException——报「损坏」会把用户推去
        // 重新导出，而重导多少次都一样。
        problems[batch.name] = <String>['无法读取清单（权限或 IO 错误）: $e'];
        continue;
      } catch (e) {
        problems[batch.name] = <String>['清单损坏: $e'];
        continue;
      }
      final List<String> archiveProblems;
      try {
        archiveProblems = await manifest.verifyArchive(archive);
      } on FileSystemException catch (e) {
        // 同上：读归档本身也可能因权限失败。这里不兜住的话，异常会炸穿整个
        // scan，连「哪一批出问题」都丢掉。
        problems[batch.name] = <String>['无法读取归档（权限或 IO 错误）: $e'];
        continue;
      }
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
