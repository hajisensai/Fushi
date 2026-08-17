/// 发现页导入计划的执行层：把 [DiscoveryImportPlan] 落到各域导入器。
///
/// 域导入器以函数端口（[DiscoveryDomainImporters]）注入——执行层不 import
/// 任何域代码，测试用假导入器即可覆盖全部编排；生产装配见
/// `discovery_import_production.dart`。
library;

import 'dart:io';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';

/// 各域导入器端口。返回值约定：入库成功返回身份键（bookKey/exe 路径），
/// 因重复被跳过返回 null；失败抛异常。
class DiscoveryDomainImporters {
  const DiscoveryDomainImporters({
    required this.importEpub,
    required this.importText,
    required this.importPdf,
    required this.importAudiobook,
    required this.registerGameExes,
  });

  final Future<String?> Function(String filePath) importEpub;
  final Future<String?> Function(String filePath) importText;
  final Future<String?> Function(String filePath) importPdf;
  final Future<String?> Function(AlignAudiobookPlan plan) importAudiobook;

  /// 返回真正新登记的条目数（查重后可能为 0）。
  final Future<int> Function(List<String> exePaths) registerGameExes;
}

/// 计划执行器：分类 → （需要时）解压 → 重分类 → 调域导入器。
class DiscoveryImportExecutor {
  DiscoveryImportExecutor({
    required DiscoveryDomainImporters importers,
    DiscoveryArchiveExtractor? extractor,
  })  : _importers = importers,
        _extractor = extractor ?? DiscoveryArchiveExtractor();

  final DiscoveryDomainImporters _importers;
  final DiscoveryArchiveExtractor _extractor;

  /// [DiscoveryDownloadQueue] 的 importer 端口（`DiscoveryDownloadImporter`）。
  Future<DiscoveryImportOutcome> importDownload(
    DiscoveryDownloadTask task,
    File file,
  ) =>
      importFile(task.item.kind, file);

  Future<DiscoveryImportOutcome> importFile(
    DiscoveryMediaKind kind,
    File file,
  ) async {
    DiscoveryImportPlan plan = classifyDiscoveryFile(kind, file.path);
    if (plan is ExtractArchivePlan) {
      final String stem = _stemOf(file.path);
      final Directory extracted = await _extractor.extract(
        plan.archivePath,
        intoDir: '${file.parent.path}${Platform.pathSeparator}$stem',
      );
      final List<String> paths = <String>[];
      final Map<String, int> sizes = <String, int>{};
      for (final FileSystemEntity entity
          in extracted.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          paths.add(entity.path);
          sizes[entity.path] = entity.lengthSync();
        }
      }
      plan = classifyDiscoveryDirectory(kind, paths, fileSizes: sizes);
    }
    return _execute(plan);
  }

  Future<DiscoveryImportOutcome> _execute(DiscoveryImportPlan plan) async {
    switch (plan) {
      case ImportEpubPlan():
        return _single(await _importers.importEpub(plan.filePath));
      case ConvertTextPlan():
        return _single(await _importers.importText(plan.filePath));
      case ImportPdfPlan():
        return _single(await _importers.importPdf(plan.filePath));
      case AlignAudiobookPlan():
        return _single(await _importers.importAudiobook(plan));
      case RegisterGameExesPlan():
        final int registered = await _importers.registerGameExes(plan.exePaths);
        return DiscoveryImportOutcome(
          importedCount: registered,
          summary: registered > 0 ? _fileName(plan.exePaths.first) : null,
        );
      case MultiPlan():
        int imported = 0;
        final List<String> keys = <String>[];
        for (final DiscoveryImportPlan child in plan.children) {
          final DiscoveryImportOutcome outcome = await _execute(child);
          imported += outcome.importedCount;
          final String? summary = outcome.summary;
          if (summary != null) keys.add(summary);
        }
        return DiscoveryImportOutcome(
          importedCount: imported,
          summary: keys.isEmpty ? null : keys.join(' / '),
        );
      case UnsupportedPlan():
        throw DiscoveryImportBlockedException(plan.blocker);
      case ExtractArchivePlan():
        // 分类目录树不会再产出压缩包计划（嵌套压缩包 v1 不递归解）。
        throw StateError('nested archive plans are not executable');
    }
  }

  static DiscoveryImportOutcome _single(String? key) => DiscoveryImportOutcome(
        importedCount: key == null ? 0 : 1,
        summary: key,
      );

  static String _stemOf(String path) {
    final String base = _fileName(path);
    final int dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }

  static String _fileName(String path) {
    final String normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}
