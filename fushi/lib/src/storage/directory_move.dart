import 'dart:io';

import 'package:path/path.dart' as p;

/// 复制中的临时文件后缀：先写它再原子改名成正式名，中断留下的半截文件不会冒充
/// 成品（下次合并时被同名覆盖）。
const String kDirectoryCopyPartSuffix = '.fushi-part';

/// 把 [source] 整棵树**合并**进 [destination]（不删源）。
///
/// - 目标里已有的同名文件被覆盖（上一次中断留下的可能是半截）；
/// - 每个文件先写 `<名>.fushi-part` 再改名，任何时刻目标里的正式名都是完整文件；
/// - 目标里多出来的文件原样保留（合并语义：中断后重来不丢已搬好的部分）。
///
/// 失败直接抛 [FileSystemException]（调用方报原因给用户，不静默）。
Future<void> copyTreeMerging(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final FileSystemEntity entity in source.list(followLinks: false)) {
    final String name = p.basename(entity.path);
    final String targetPath = p.join(destination.path, name);
    if (entity is Directory) {
      await copyTreeMerging(entity, Directory(targetPath));
    } else if (entity is File) {
      if (name.endsWith(kDirectoryCopyPartSuffix)) continue;
      final File part = File('$targetPath$kDirectoryCopyPartSuffix');
      await entity.copy(part.path);
      final File target = File(targetPath);
      if (await target.exists()) await target.delete();
      await part.rename(targetPath);
    }
  }
}

/// 目录搬家：目标不存在时先试 `rename`（同卷 O(1)），跨卷（`rename` 抛
/// [FileSystemException]）或目标已有内容（半次搬家中断过）时退回
/// [copyTreeMerging] + 删源。
Future<void> moveDirectoryMerging(
  Directory source,
  Directory destination,
) async {
  await destination.parent.create(recursive: true);
  if (!await destination.exists()) {
    try {
      await source.rename(destination.path);
      return;
    } on FileSystemException {
      // 跨卷：走复制。
    }
  }
  await copyTreeMerging(source, destination);
  await source.delete(recursive: true);
}

/// [directory] 是否存在且至少含一个文件（空目录树不算「有内容」）。
Future<bool> directoryHasFiles(Directory directory) async {
  if (!await directory.exists()) return false;
  await for (final FileSystemEntity entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) return true;
  }
  return false;
}
