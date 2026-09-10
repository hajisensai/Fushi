/// 封面文件落盘（tmp + rename，写稳后再替换）**并驱逐该路径的解码缓存**。
///
/// 这是 BUG-1118 不变量「这条路径上的图变了就得驱逐」的唯一写侧实现：app 的
/// `MediaCoverService.applyCoverBytes` / `applyCoverFile` 是它的薄委派，引擎里的
/// 下载路（`video_cover_extractor`）直接调它。驱逐经 [evictImageCacheForFile]
/// 装配点回到 Flutter（app 绑成双键 evict；无头服务端是 no-op）。写盘与驱逐必须在
/// 同一个函数里——拆开就是当年「落盘后忘 evict」回归的形状。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_platform_hooks.dart';

int _temporarySerial = 0;

Future<void> writeCoverBytesAtomically({
  required List<int> bytes,
  required String destPath,
}) async {
  final File tmp = File('$destPath.tmp.$pid.${_temporarySerial++}');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    final File dest = File(destPath);
    if (await dest.exists()) await dest.delete();
    await tmp.rename(destPath);
    await evictImageCacheForFile(dest);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // .tmp 清理失败不掩盖原始写盘异常。
    }
    rethrow;
  }
}

Future<void> copyCoverFileAtomically({
  required File source,
  required String destPath,
}) async {
  final File tmp = File('$destPath.tmp.$pid.${_temporarySerial++}');
  try {
    await source.copy(tmp.path);
    final File dest = File(destPath);
    if (await dest.exists()) await dest.delete();
    await tmp.rename(destPath);
    await evictImageCacheForFile(dest);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // .tmp 清理失败不掩盖原始写盘异常。
    }
    rethrow;
  }
}
