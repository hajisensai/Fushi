import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_engine/media/book_archive/book_archive_import.dart'
    show looksLikeBookArchive;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/drag_drop/drop_classification.dart';

/// 「拖进来的这个 `.zip` / `.rar` 是不是装着一批书」的预判，离开拖放回调的同步栈跑完
/// （zip 读中央目录在后台 isolate，rar 经 7-Zip 列目录是子进程）。结果喂回
/// [classifyDroppedFiles] 的 `isBookArchive` 查表谓词，分类函数保持纯函数。
///
/// [imageArchives] 是 `probeDroppedImageArchives` 的结果：已判成页图包的路径分类层
/// 先归漫画，这里不再白开一次包。[probe] 是测试缝，默认走引擎 [looksLikeBookArchive]。
Future<Map<String, bool>> probeDroppedBookArchives(
  List<String> paths, {
  Map<String, bool> imageArchives = const <String, bool>{},
  Future<bool> Function(String path)? probe,
}) async {
  final Future<bool> Function(String path) run = probe ?? looksLikeBookArchive;
  final Map<String, bool> results = <String, bool>{};
  for (final String path in paths) {
    if (results.containsKey(path) || imageArchives[path] == true) continue;
    final String extension = p.extension(path);
    if (extension.isEmpty) continue;
    if (!kDragBookArchiveProbeExtensions.contains(
      extension.substring(1).toLowerCase(),
    )) {
      continue;
    }
    results[path] = await _neverThrows(path, run);
  }
  return results;
}

/// 判定永不抛：判不出只是「不是一批书」，落回按扩展名的既有分类，不把整次拖放炸掉。
Future<bool> _neverThrows(
  String path,
  Future<bool> Function(String path) run,
) async {
  try {
    return await run(path);
  } catch (error, stackTrace) {
    debugPrint(
      '[fushi-drop] book archive probe failed for $path: $error\n$stackTrace',
    );
    return false;
  }
}
