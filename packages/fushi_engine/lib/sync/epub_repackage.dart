/// 已解压 EPUB 目录 → 单文件 .epub 的重打包（从 app 的 sync_manager.dart 抽出：
/// 互联 host 导出书籍与云同步导出共用，引擎侧不能依赖 sync_manager 那一整套
/// 云盘后端）。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Re-package an extracted book directory back into a single `.epub` at
/// [outputPath]. Hibiki stores imported books EXTRACTED (the extract dir is a
/// valid EPUB layout: `mimetype` + `META-INF/` + OPF + content) and keeps no
/// standalone `.epub` on disk, so content sync must rebuild one to upload
/// (BUG-088). Entries are rooted at the zip top (`includeDirName: false`) so
/// `mimetype` / `META-INF` sit at the archive root and the result re-imports
/// cleanly via [EpubImporter] on the other device.
///
/// Returns true if an archive was written; false when [extractDir] is empty or
/// absent (nothing to package).
Future<bool> repackageExtractedEpub(
  String extractDir,
  String outputPath,
) async {
  final Directory? dir = resolveExtractedEpubRoot(extractDir);
  if (dir == null) return false;
  final ZipFileEncoder encoder = ZipFileEncoder();
  encoder.create(outputPath);
  try {
    encoder.addDirectory(dir, includeDirName: false);
  } finally {
    encoder.close();
  }
  return true;
}

/// Returns the directory whose root is a valid extracted EPUB layout.
///
/// Some older/restored rows can point [extractDir] at a parent directory while
/// the actual EPUB root lives in its only child. Readers may still work if they
/// use cached DB paths, but sync export must package the true root so
/// `META-INF/container.xml` is at the archive top.
Directory? resolveExtractedEpubRoot(String extractDir) {
  if (extractDir.isEmpty) return null;
  final Directory dir = Directory(extractDir);
  if (!dir.existsSync()) return null;
  if (_hasEpubContainer(dir)) return dir;

  final List<Directory> children = dir
      .listSync(followLinks: false)
      .whereType<Directory>()
      .where(_hasEpubContainer)
      .toList();
  if (children.length == 1) return children.single;
  return null;
}

bool _hasEpubContainer(Directory dir) =>
    File(p.join(dir.path, 'META-INF', 'container.xml')).existsSync();
