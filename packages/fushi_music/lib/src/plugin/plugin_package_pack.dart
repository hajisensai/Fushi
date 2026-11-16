import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 把一个已安装插件的目录（`<插件根>/<id>/`，含 `files.json` / `signature.json`）原样打回
/// `.fushiplug` 包，供互联「来源共享」把 host 上装好的插件发给自己的其它设备。
///
/// 包内路径 = 相对 [dir] 的路径（`/` 分隔）。不做任何筛选：已装目录的内容必须与
/// `files.json` 逐个对上（多一个少一个都拒装），接收端照常走 inspect → install 的完整
/// 校验，摘要与 host 上用户确认过的那份对不上就不装。目录不存在返回 null。
Future<Uint8List?> packInstalledPluginDirectory(Directory dir) async {
  if (!dir.existsSync()) return null;
  final String root = dir.absolute.path;
  final Archive archive = Archive();
  final List<File> files = <File>[
    for (final FileSystemEntity e in dir.listSync(recursive: true))
      if (e is File) e,
  ]..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String relative = file.absolute.path
        .substring(root.length)
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp('^/+'), '');
    if (relative.isEmpty) continue;
    final Uint8List bytes = await file.readAsBytes();
    archive.addFile(ArchiveFile(relative, bytes.length, bytes));
  }
  final List<int>? encoded = ZipEncoder().encode(archive);
  return encoded == null ? null : Uint8List.fromList(encoded);
}
