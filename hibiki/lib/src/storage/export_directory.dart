import 'dart:io';

import 'package:path/path.dart' as p;

/// 导出目录（制卡图片/音频、thumbnail.jpg 等导出物落点）的目录名。
///
/// W2-4：新名 `fushiExport`；历史名 `hibikiExport` 由 [prepareExportDirectoryAt]
/// 在启动准备目录时就地改名。导出物路径不入库，无 DB 改写面。
const String kExportDirectoryName = 'fushiExport';

/// 存量旧目录名。旧字面量只允许活在本迁移文件与 `AppPaths` 的双名迁移白名单
/// （数据根搬迁在旧目录尚未改名成功时仍须认它）。
const String kLegacyExportDirectoryName = 'hibikiExport';

/// 在 [appDirectoryPath]（documents 根）下准备导出目录：先做存量改名迁移
/// （新目录不存在且旧目录存在时 rename，同根同盘 O(1)、内容原样保留），再确保
/// 新目录存在。改名失败（句柄占用等）不阻塞：上报 [onMigrationError] 后退回
/// 用新名建目录，旧目录留待下次启动再试——导出物是临时产物，不值得为它中断
/// 启动。幂等：改名成功后旧目录消失，后续调用只剩 exists 短路。
///
/// media-scanner 排除是平台服务职责，归调用方（`AppModel`）。
Directory prepareExportDirectoryAt(
  String appDirectoryPath, {
  void Function(Object error, StackTrace stack)? onMigrationError,
}) {
  final String directoryPath = p.join(appDirectoryPath, kExportDirectoryName);
  final Directory exportDirectory = Directory(directoryPath);
  if (!exportDirectory.existsSync()) {
    final Directory legacy =
        Directory(p.join(appDirectoryPath, kLegacyExportDirectoryName));
    if (legacy.existsSync()) {
      try {
        legacy.renameSync(directoryPath);
      } catch (e, stack) {
        onMigrationError?.call(e, stack);
      }
    }
  }
  if (!exportDirectory.existsSync()) {
    exportDirectory.createSync(recursive: true);
  }
  return exportDirectory;
}
