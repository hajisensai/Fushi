/// 发现页下载物的解压原语：薄包装 [ArchiveUnpacker]（导入链路唯一的解包点）。
///
/// zip / 7z（含加密包）由 Rust 胖核心 `fushi_compute` 解，五端都有；RAR 交 7-Zip 命令行
/// （Windows 随包分发完整 `7z.exe + 7z.dll`，定位顺序见 [SevenZipLocator]），找不到 →
/// [DiscoveryImportBlocker.archiveToolMissing]。加密包经 [ArchivePasswordProvider] 要口令，
/// 拿不到口令 → [DiscoveryImportBlocker.archivePasswordRequired]。
///
/// 条目路径带 `..` / 绝对路径一律拒绝（zip-slip）——下载物来自外部站点，属不可信输入。
library;

import 'dart:io';

import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/utils/archive/archive_unpacker.dart';

export 'package:fushi_engine/utils/archive/archive_unpacker.dart'
    show sanitizeArchiveEntryPath;

/// 测试注入口：替换真实子进程执行。
typedef DiscoveryProcessRunner = ArchiveProcessRunner;

class DiscoveryArchiveExtractor {
  DiscoveryArchiveExtractor({
    DiscoveryProcessRunner? runProcess,
    String? sevenZipOverride,
    ArchivePasswordProvider? passwords,
    ArchiveUnpacker? unpacker,
  }) : _unpacker =
           unpacker ??
           ArchiveUnpacker(
             runProcess: runProcess,
             sevenZipOverride: sevenZipOverride,
             passwords: passwords,
           );

  final ArchiveUnpacker _unpacker;

  /// 定位 7-Zip 命令行（RAR 用），见 [SevenZipLocator]。
  Future<String?> findSevenZip() => _unpacker.sevenZipLocator.find();

  /// 解压 [archivePath] 到 [intoDir]（不存在会创建；已存在则并入）。成功返回解出的目录。
  Future<Directory> extract(
    String archivePath, {
    required String intoDir,
  }) async {
    try {
      final ArchiveUnpackResult result = await _unpacker.extract(
        archivePath,
        intoDir: intoDir,
      );
      return result.directory;
    } on ArchiveUnpackException catch (e) {
      throw DiscoveryImportBlockedException(switch (e.failure) {
        ArchiveUnpackFailure.toolMissing =>
          DiscoveryImportBlocker.archiveToolMissing,
        ArchiveUnpackFailure.passwordRequired ||
        ArchiveUnpackFailure.passwordCancelled =>
          DiscoveryImportBlocker.archivePasswordRequired,
        ArchiveUnpackFailure.missingVolume =>
          DiscoveryImportBlocker.archiveVolumesMissing,
        _ => DiscoveryImportBlocker.archiveExtractionFailed,
      }, '${e.failure.name}${e.detail == null ? '' : ': ${e.detail}'}');
    }
  }
}
