/// 封面文件落盘（tmp + rename，写稳后再替换）**并驱逐该路径的解码缓存**。
///
/// 这是 BUG-1118 不变量「这条路径上的图变了就得驱逐」的唯一写侧实现：app 的
/// `MediaCoverService.applyCoverBytes` / `applyCoverFile` 是它的薄委派，引擎里的
/// 下载路（`video_cover_extractor`）直接调它。驱逐经 [evictImageCacheForFile]
/// 装配点回到 Flutter（app 绑成双键 evict；无头服务端是 no-op）。写盘与驱逐必须在
/// 同一个函数里——拆开就是当年「落盘后忘 evict」回归的形状。
///
/// BUG-2496 起这里还是「**落盘的必须是可解码图片**」的唯一判据：HTML 错误页存成
/// `.jpg`、连接中断的半截 JPEG、ffmpeg 写一半被掐——这些文件一到渲染层就是
/// `FlutterError: resolving an image codec / Invalid image data`，而渲染层只判
/// `existsSync`，坏文件会在每次重建时反复解码反复报错。判据放在写侧唯一入口
/// （[isDecodableImageBytes]），所有写入方——内存字节、拷文件、外部进程 staged
/// 文件——都过同一道门，而不是每个调用点各写一遍校验（那正是漏掉三处的形状）。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_platform_hooks.dart';

int _temporarySerial = 0;

/// 写入方交来的字节不是可解码图片（或是截断的 JPEG/PNG）。
class CoverImageInvalidException implements Exception {
  const CoverImageInvalidException(this.reason);

  final String reason;

  @override
  String toString() => 'CoverImageInvalidException: $reason';
}

/// 字节是否像一张 Flutter 能解码的**完整**图片。
///
/// 头部魔数：JPEG / PNG / GIF / WebP / BMP。尾部完整性：JPEG 必须在末尾（容忍少量
/// 填充）出现 EOI `FF D9`，PNG 必须以 IEND chunk 收尾——这两种是所有封面产线的
/// 输出格式，也是「写一半被掐」最常见的受害者；截断的 JPEG 头部完全合法，只查魔数
/// 抓不住。GIF / WebP / BMP 只查头（尾部无固定标记，且不是本仓任何产线的输出）。
bool isDecodableImageBytes(List<int> bytes) {
  if (bytes.length < 12) return false;
  // JPEG: FF D8 FF ... FF D9
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return _endsWithMarker(bytes, const <int>[0xFF, 0xD9], slack: 64);
  }
  // PNG: 89 50 4E 47 0D 0A 1A 0A ... "IEND" AE 42 60 82
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return _endsWithMarker(bytes, const <int>[
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ], slack: 0);
  }
  // GIF: "GIF8"
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // WebP: "RIFF" .... "WEBP"
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  // BMP: "BM"
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  return false;
}

/// [marker] 是否出现在 [bytes] 末尾 [slack] 字节范围内（含紧贴末尾）。
bool _endsWithMarker(List<int> bytes, List<int> marker, {required int slack}) {
  final int last = bytes.length - marker.length;
  final int first = last - slack < 0 ? 0 : last - slack;
  for (int start = last; start >= first; start--) {
    bool hit = true;
    for (int i = 0; i < marker.length; i++) {
      if (bytes[start + i] != marker[i]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// 文件版 [isDecodableImageBytes]：只读头尾各 4KB，不整文件进内存。
Future<bool> isDecodableImageFile(File file) async {
  final int length = await file.length();
  if (length < 12) return false;
  const int window = 4096;
  final RandomAccessFile raf = await file.open();
  try {
    final List<int> head = await raf.read(window < length ? window : length);
    if (length <= window) return isDecodableImageBytes(head);
    await raf.setPosition(length - window);
    final List<int> tail = await raf.read(window);
    return isDecodableImageBytes(<int>[...head, ...tail]);
  } finally {
    await raf.close();
  }
}

/// 给 [destPath] 派生一个**同扩展名**的 staged 临时路径，供外部进程（ffmpeg）直接
/// 写入后交给 [publishStagedCoverFile] 发布。扩展名必须保留在末尾：ffmpeg 按输出
/// 扩展名选编码器，`cover.jpg.tmp.123` 会让它报「无法猜测输出格式」。
String stagedCoverPath(String destPath) {
  final int dot = destPath.lastIndexOf('.');
  final int slash = destPath.lastIndexOf(Platform.pathSeparator);
  final int altSlash = destPath.lastIndexOf('/');
  final int sep = slash > altSlash ? slash : altSlash;
  final String ext = dot > sep ? destPath.substring(dot) : '';
  final String stem = dot > sep ? destPath.substring(0, dot) : destPath;
  return '$stem.tmp.$pid.${_temporarySerial++}$ext';
}

/// 把已写好的 staged 文件（见 [stagedCoverPath]）校验后原子发布到 [destPath] 并驱逐
/// 解码缓存。校验不过则删掉 staged、**不动**旧封面、抛 [CoverImageInvalidException]。
Future<void> publishStagedCoverFile({
  required File staged,
  required String destPath,
}) async {
  try {
    if (!await isDecodableImageFile(staged)) {
      throw CoverImageInvalidException(
        'staged cover ${staged.path} is not a complete decodable image',
      );
    }
    final File dest = File(destPath);
    if (await dest.exists()) await dest.delete();
    await staged.rename(destPath);
    await evictImageCacheForFile(dest);
  } catch (_) {
    await _deleteQuietly(staged);
    rethrow;
  }
}

Future<void> writeCoverBytesAtomically({
  required List<int> bytes,
  required String destPath,
}) async {
  if (!isDecodableImageBytes(bytes)) {
    throw CoverImageInvalidException(
      '${bytes.length} bytes for $destPath are not a complete decodable image',
    );
  }
  final File tmp = File('$destPath.tmp.$pid.${_temporarySerial++}');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    final File dest = File(destPath);
    if (await dest.exists()) await dest.delete();
    await tmp.rename(destPath);
    await evictImageCacheForFile(dest);
  } catch (_) {
    await _deleteQuietly(tmp);
    rethrow;
  }
}

Future<void> copyCoverFileAtomically({
  required File source,
  required String destPath,
}) async {
  if (!await isDecodableImageFile(source)) {
    throw CoverImageInvalidException(
      'source ${source.path} is not a complete decodable image',
    );
  }
  final File tmp = File('$destPath.tmp.$pid.${_temporarySerial++}');
  try {
    await source.copy(tmp.path);
    final File dest = File(destPath);
    if (await dest.exists()) await dest.delete();
    await tmp.rename(destPath);
    await evictImageCacheForFile(dest);
  } catch (_) {
    await _deleteQuietly(tmp);
    rethrow;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // .tmp 清理失败不掩盖原始异常。
  }
}
