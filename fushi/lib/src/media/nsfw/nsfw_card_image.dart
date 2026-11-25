/// 从 NSFW 作品制卡时的卡图模糊（拍板台 w04vrhUAaX：「这本书制卡时卡上的封面也一起
/// 模糊」）。开关是独立偏好「制卡图片也模糊」（`blur_nsfw_card_images`，默认关：卡里
/// 存的是模糊图，以后取消 NSFW 也恢复不了已制的卡）。
///
/// 接在各来源组 `AnkiMiningContext.coverPath` 的最后一步：小说阅读器（书封）、收藏夹
/// 批量制卡（书封）、漫画阅读器（页图 / 裁切图）。模糊副本由 fushi_engine
/// [blurImageForNsfwAsync]（原生缩放内核）生成，落在系统临时目录，按源字节哈希复用。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/nsfw_image_blur.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';
import 'package:path/path.dart' as p;

/// 卡图该用的路径：[blurCardImages] 关、[path] 为 null、或宿主不是 NSFW 时原样返回
/// [path]；否则返回模糊副本的路径。
///
/// **fail-closed**：判定或模糊任何一步失败都返回 null（这张卡不带图）并记诊断，绝不
/// 退回原图——用户开这个开关就是不想让 NSFW 图进卡。
Future<String?> resolveNsfwCardImagePath({
  required FushiDatabase db,
  required String? path,
  required bool blurCardImages,
  required TagHostKind kind,
  required String? entryKey,
  bool alsoNsfw = false,
}) async {
  if (path == null || !blurCardImages) return path;
  try {
    final bool nsfw =
        alsoNsfw ||
        (entryKey != null && await isMediaNsfwEffective(db, kind, entryKey));
    if (!nsfw) return path;
    return await writeNsfwBlurredCardImage(path);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('resolveNsfwCardImagePath', error, stack);
    return null;
  }
}

/// 模糊副本文件名里的参数段：模糊参数（采样长边 / 输出长边）一变，旧副本的名字
/// 就对不上，不会被当成新参数的结果复用。
String get nsfwCardImageParamsTag =>
    's${kNsfwBlurSampleEdge}o$kNsfwBlurOutputEdge';

/// [sourceBytes] 的模糊副本在 [dir] 下的文件名：源字节 SHA-1 + [nsfwCardImageParamsTag]。
String nsfwCardImageFileName(Uint8List sourceBytes) =>
    '${sha1.convert(sourceBytes)}_$nsfwCardImageParamsTag.jpg';

/// 把 [sourcePath] 的图写成模糊副本（JPEG），返回副本路径；图解不开返回 null。
/// 同一份源字节、同一套模糊参数只算一次（[nsfwCardImageFileName]，已存在直接复用）。
/// 副本落在系统临时目录，由系统临时目录清理回收。
Future<String?> writeNsfwBlurredCardImage(String sourcePath) async {
  final Uint8List bytes = await File(sourcePath).readAsBytes();
  final Directory dir = Directory(
    p.join(Directory.systemTemp.path, 'fushi_nsfw_card_images'),
  );
  final File out = File(p.join(dir.path, nsfwCardImageFileName(bytes)));
  if (out.existsSync()) return out.path;
  final Uint8List? blurred = await blurImageForNsfwAsync(bytes);
  if (blurred == null) {
    ErrorLogService.instance.logDiagnostic(
      'writeNsfwBlurredCardImage',
      'card image not decodable (${p.extension(sourcePath)}), image omitted',
    );
    return null;
  }
  await dir.create(recursive: true);
  // 先写临时名再改名：并发的两次制卡不会读到写了一半的文件。
  final File partial = File(
    '${out.path}.${DateTime.now().microsecondsSinceEpoch}',
  );
  await partial.writeAsBytes(blurred, flush: true);
  try {
    await partial.rename(out.path);
  } on FileSystemException {
    // Windows 上目标已存在时改名失败：另一次制卡刚写好同一份副本，用它即可。
    if (!out.existsSync()) rethrow;
    await partial.delete();
  }
  return out.path;
}
