/// 把一张图片写进系统剪贴板。
///
/// 走的是本仓自有的 [FushiChannels.clipboardImage]（`copyImageFile`，入参
/// `{'path': <本地文件路径>}`）——这条通道本来只有 Windows 实现（WIC 解码 →
/// 32bpp BGRA → `SetClipboardData(CF_DIB)`，阅读器内联图与插画查看器在用），本文件
/// 把「给我一段 PNG 字节，帮我放进剪贴板」这一步收敛成一个入口，供视频截图复用。
///
/// 为什么契约是**文件路径**而不是字节：Windows 那份已在生产跑的实现吃的就是路径，
/// 而 Android 侧写剪贴板本来就要经 `FileProvider` 的 `content://` URI（也从文件来）。
/// 统一成路径，五端各自的 handler 都最短，且不用把几 MB 图片字节抬过 method channel。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 临时 PNG 的落点子目录（在系统临时目录下）。
const String _kClipboardImageDirName = 'clipboard_image';

/// 把 [pngBytes] 放进系统剪贴板；平台没实现这条通道时返回 false。
///
/// 返回值区分的是「这个平台压根不支持」（false，调用方给一句可理解的提示）与
/// 「支持但这次失败了」（抛出，调用方把原因显示出来）。**不吞异常**：静默失败会让
/// 用户以为复制成功了，粘贴时才发现什么都没有。
///
/// 临时文件不立即删除：Android 的剪贴板存的是 `content://` URI **引用**，删掉文件
/// 粘贴就成空的。改为每次写入前清掉上一轮的残留——旧图的引用在复制新图后失效，这是
/// 用户预期内的。
Future<bool> copyImageToClipboard(Uint8List pngBytes) async {
  if (pngBytes.isEmpty) return false;
  final Directory tmpDir = await getTemporaryDirectory();
  final Directory dir = Directory(p.join(tmpDir.path, _kClipboardImageDirName));
  if (!await dir.exists()) await dir.create(recursive: true);
  _purge(dir);

  final File file = File(
    p.join(dir.path, 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png'),
  );
  await file.writeAsBytes(pngBytes);
  try {
    await FushiChannels.clipboardImage.invokeMethod<void>(
      'copyImageFile',
      <String, String>{'path': file.path},
    );
    return true;
  } on MissingPluginException {
    // 这个平台还没接这条通道。删掉刚写的临时文件——没人会来读它。
    try {
      await file.delete();
    } catch (_) {}
    return false;
  }
}

/// 清掉上一轮留下的临时图（尽力而为；正被剪贴板引用的文件在 Windows 上可能删不掉）。
void _purge(Directory dir) {
  try {
    for (final FileSystemEntity entity in dir.listSync()) {
      try {
        entity.deleteSync(recursive: true);
      } catch (_) {}
    }
  } catch (_) {}
}
