import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show Uint8List, debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// TODO-901：Windows 桌面换图标后，把桌面 / 开始菜单的快捷方式（.lnk）图标同步成
/// 用户当前选的图。纯 Dart 侧负责 PNG → 多尺寸 .ico 编码 + 落盘（带内容哈希文件
/// 名绕 explorer 图标缓存），再经 `app.hibiki/window` channel 的 `setShortcutIcon`
/// 让原生侧 IShellLink 改写 .lnk 的 IconLocation。
///
/// 仅 Windows 有意义；其它平台 [syncWindowsShortcutIcons] 直接 no-op。
///
/// 失败（编码失败 / channel 未实现 / 找不到 .lnk）一律降级为静默 debugPrint，不抛
/// 错、不影响已经成功应用的运行时窗口图标（`setWindowIcon`）。

/// 多尺寸 .ico 包含的方形边长（资源管理器在不同视图 / DPI 取不同尺寸；缺 256 在大
/// 图标视图会糊或回退到 exe 嵌入图标）。
const List<int> kShortcutIcoSizes = <int>[16, 32, 48, 256];

/// 把源 PNG（或任意 image 库可解码的图片字节）编码成单个**多尺寸** .ico 字节。
///
/// 解码源图 → 对 [kShortcutIcoSizes] 每个边长 `copyResize` 出一帧 → 用
/// `IcoEncoder().encodeImages(...)`（**不是**顶层 `encodeIco` 单尺寸）打包成一个
/// 含 4 个目录项的 .ico。源图大于 256 不是问题（会被 resize 下来），但绝不能把
/// >256 的原图直接喂 encoder（库内部 `width > 256` 会 throw）。
///
/// 解码失败返回 null（调用方据此降级，不写文件、不调 channel）。
Uint8List? buildMultiSizeIco(Uint8List sourceBytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(sourceBytes);
  } catch (_) {
    // image 库对部分畸形字节会 throw（而非返回 null），统一降级为不可解码。
    return null;
  }
  if (decoded == null) {
    return null;
  }
  // 每个尺寸 copyResize 后 PNG 压缩（Vista+ 的 .ico 支持 PNG 帧）。手写 ICO 容器
  // （ICONDIR 头 + 16 字节目录项 + 帧数据），避免引 image 库未导出的 IcoEncoder
  // 内部文件（implementation_imports lint）。等价于 IcoEncoder().encodeImages。
  final List<Uint8List> frames = <Uint8List>[
    for (final int size in kShortcutIcoSizes)
      Uint8List.fromList(
        img.encodePng(
          img.copyResize(
            decoded,
            width: size,
            height: size,
            interpolation: img.Interpolation.average,
          ),
        ),
      ),
  ];

  const int kHeaderSize = 6;
  const int kEntrySize = 16;
  final int count = frames.length;
  int offset = kHeaderSize + count * kEntrySize;

  final BytesBuilder body = BytesBuilder();
  final ByteData header = ByteData(kHeaderSize + count * kEntrySize);
  header.setUint16(0, 0, Endian.little); // reserved
  header.setUint16(2, 1, Endian.little); // type: 1 = icon
  header.setUint16(4, count, Endian.little); // image count
  for (int i = 0; i < count; i++) {
    final int size = kShortcutIcoSizes[i];
    // ICO 规范：256 在单字节宽/高里存 0。
    final int dim = size >= 256 ? 0 : size;
    final int entry = kHeaderSize + i * kEntrySize;
    header.setUint8(entry, dim); // width
    header.setUint8(entry + 1, dim); // height
    header.setUint8(entry + 2, 0); // color count (0 = >=256 colors)
    header.setUint8(entry + 3, 0); // reserved
    header.setUint16(entry + 4, 0, Endian.little); // color planes (PNG: 0)
    header.setUint16(entry + 6, 32, Endian.little); // bits per pixel
    header.setUint32(entry + 8, frames[i].length, Endian.little); // data size
    header.setUint32(entry + 12, offset, Endian.little); // data offset
    offset += frames[i].length;
  }
  body.add(header.buffer.asUint8List());
  for (final Uint8List frame in frames) {
    body.add(frame);
  }
  return body.toBytes();
}

/// .ico 内容哈希派生的稳定文件名（前 16 位十六进制即可避撞，足够区分换图）。
///
/// 文件名带内容哈希是为了让 IconLocation 指向「新路径」从而绕过 explorer 对同名
/// 文件的图标缓存（见 plan §5）。纯函数，便于单测。
String shortcutIcoFileName(Uint8List icoBytes) {
  final String digest = sha1.convert(icoBytes).toString();
  return 'shortcut_icon_${digest.substring(0, 16)}.ico';
}

/// 把 [icoBytes] 写到 app support 目录下「带内容哈希」的 .ico 文件，返回绝对路径。
///
/// 写新文件前清理目录里其它 `shortcut_icon_*.ico` 旧版（哈希命名会留旧文件，避免
/// app support 目录膨胀；当前内容对应的同名文件保留，幂等不重复写）。
Future<String> writeShortcutIcoFile(Uint8List icoBytes) async {
  final Directory dir = await getApplicationSupportDirectory();
  final String name = shortcutIcoFileName(icoBytes);
  final File dest = File('${dir.path}${Platform.pathSeparator}$name');
  // 清理旧 shortcut_icon_*.ico（保留当前要写的这个）。
  try {
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final String base = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last
          : '';
      if (base.startsWith('shortcut_icon_') &&
          base.endsWith('.ico') &&
          base != name) {
        try {
          await entity.delete();
        } on FileSystemException {
          // 被占用 / 已删，忽略。
        }
      }
    }
  } on FileSystemException {
    // 目录列举失败不阻断写入。
  }
  await dest.writeAsBytes(icoBytes, flush: true);
  return dest.path;
}

const MethodChannel _windowChannel = MethodChannel('app.hibiki/window');

/// 换图标后同步桌面 / 开始菜单快捷方式图标（仅 Windows，其它平台 no-op）。
///
/// [sourceBytes] 是用户当前图标的原始图片字节（preset 走 `rootBundle.load`，custom
/// 走文件读字节）。流程：编码多尺寸 .ico → 写带哈希文件 → 经 channel 让原生改 .lnk。
///
/// 任一步失败只 debugPrint 降级，不抛错（与现有「换图标」体感一致，不弹错误 toast）。
Future<void> syncWindowsShortcutIcons(Uint8List sourceBytes) async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    final Uint8List? ico = buildMultiSizeIco(sourceBytes);
    if (ico == null) {
      debugPrint('syncWindowsShortcutIcons: 源图解码失败，跳过 .lnk 同步');
      return;
    }
    final String icoPath = await writeShortcutIcoFile(ico);
    // 注意：入参 key 是 'iconPath'（与 setWindowIcon 的 'path' 不同，别混）。
    await _windowChannel.invokeMethod<dynamic>(
      'setShortcutIcon',
      <String, String>{'iconPath': icoPath},
    );
  } on PlatformException catch (e) {
    debugPrint('syncWindowsShortcutIcons: 原生改 .lnk 失败：$e');
  } on MissingPluginException catch (e) {
    debugPrint('syncWindowsShortcutIcons: setShortcutIcon 未实现：$e');
  } catch (e) {
    debugPrint('syncWindowsShortcutIcons: 同步快捷方式图标异常：$e');
  }
}
