/// 复习（SRS）卡片的媒体存储：`<app 支持目录>/srs_media/<profileUid>/`。
///
/// 文件名 = 内容 sha1（40 位小写十六进制）+ 原扩展名：同一份字节无论从哪条路进来
/// （制卡、Anki 包导入、AnkiConnect storeMediaFile）都落成同一个文件，天然去重；
/// 字段里的 `<img src>` / `[sound:]` 引用的就是这个名字。
///
/// 只有复习模块开着、真的要读写媒体时才会构造它（见 `srsMediaStoreProvider`），
/// 模块关着时这个目录根本不会被创建。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 支持目录下的媒体根目录名。
const String kSrsMediaDirName = 'srs_media';

final RegExp _extensionPattern = RegExp(r'^[a-z0-9]{1,10}$');
final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:');

/// 一个 profile 的 SRS 媒体目录。
class SrsMediaStore {
  SrsMediaStore(this.root);

  /// 本 profile 的媒体目录（`.../srs_media/<profileUid>`）。
  final Directory root;

  /// [supportRoot] 下全部 profile 的媒体根（`<support>/srs_media`，不创建）。
  /// 备份的「复习」类别按这个根原样打包 / 恢复各 profile 子目录。
  static Directory mediaRootFor(Directory supportRoot) =>
      Directory(p.join(supportRoot.path, kSrsMediaDirName));

  /// [supportRoot] 下某 profile 的媒体目录（不创建）。
  static Directory directoryFor(Directory supportRoot, String profileUid) =>
      Directory(p.join(mediaRootFor(supportRoot).path, profileUid));

  /// 按内容给出存储文件名：sha1(bytes) + [originalName] 的扩展名（小写；不合法时省略）。
  static String contentName(String originalName, List<int> bytes) {
    final String digest = sha1.convert(bytes).toString();
    final String ext = extensionOf(originalName);
    return ext.isEmpty ? digest : '$digest.$ext';
  }

  /// [name] 的扩展名（小写、不含点；只认 1–10 位字母数字，否则为空串）。
  static String extensionOf(String name) {
    final String base = name.split(RegExp(r'[\\/]')).last;
    final int dot = base.lastIndexOf('.');
    if (dot <= 0 || dot == base.length - 1) return '';
    final String ext = base.substring(dot + 1).toLowerCase();
    return _extensionPattern.hasMatch(ext) ? ext : '';
  }

  /// 是否是可以在本目录里直接解析的裸文件名（拒绝路径分隔符、`.`/`..`、盘符、控制字符）。
  static bool isSafeName(String name) {
    if (name.isEmpty || name.length > 255) return false;
    if (name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(r'\')) return false;
    if (_drivePrefix.hasMatch(name)) return false;
    for (final int c in name.codeUnits) {
      if (c < 0x20 || c == 0x7f) return false;
    }
    return true;
  }

  /// 存一份字节，返回存储后的文件名（同内容已存在时不重写）。
  Future<String> store(String name, Uint8List bytes) async {
    final String stored = contentName(name, bytes);
    final File target = File(p.join(root.path, stored));
    if (await target.exists() && await target.length() == bytes.length) {
      return stored;
    }
    await root.create(recursive: true);
    // 先写临时文件再改名：进程中途被杀不会留下一个半截的「内容哈希」文件。
    final File tmp = File(
      '${target.path}.${Random().nextInt(1 << 30).toRadixString(36)}.tmp',
    );
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // 并发写同一内容（Windows 上目标已存在时 rename 失败）：内容一样，留现有的即可。
      if (await tmp.exists()) await tmp.delete();
      if (!await target.exists()) rethrow;
    }
    return stored;
  }

  /// 读一个本地文件存进来（文件不存在返回 null）。
  Future<String?> storeFile(File file, {String? name}) async {
    if (!await file.exists()) return null;
    return store(name ?? p.basename(file.path), await file.readAsBytes());
  }

  /// 文件名对应的本地文件（名字不安全时为 null；不检查存在性）。
  File? resolve(String name) {
    if (!isSafeName(name)) return null;
    return File(p.join(root.path, name));
  }

  /// 读一个媒体文件；不存在 / 名字不安全时返回 null。
  Future<Uint8List?> load(String name) async {
    final File? file = resolve(name);
    if (file == null || !await file.exists()) return null;
    return file.readAsBytes();
  }
}
