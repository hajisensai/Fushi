/// 封面文件落盘（tmp + rename，写稳后再替换）。
///
/// 从 app 的 `MediaCoverService.applyCoverBytes` / `applyCoverFile` 抽出的纯 IO
/// 一半；app 的两个静态方法委派到这里，然后各自再做图片缓存驱逐（那是 Flutter
/// 的事，引擎不管）。
library;

import 'dart:io';

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
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // .tmp 清理失败不掩盖原始写盘异常。
    }
    rethrow;
  }
}
