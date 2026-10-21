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

  /// [root] 已建好（批量存媒体时不必每个文件都 create 一次）。
  bool _rootReady = false;

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
  ///
  /// 不逐文件 fsync：Windows 上每次 FlushFileBuffers 约 2 ms 且按卷串行，从 Anki 迁移
  /// 4 万个媒体时光这一项就要 80 秒（并发也只快 1.4 倍）。改名前不落盘的代价是断电后
  /// 可能留下「名字对、内容没写进去」的文件；名字就是内容哈希，所以已存在的同名文件要
  /// 核对内容（不只比长度），不对就重写——下次存同一份内容（重新迁移 / 重新导入）即自愈。
  /// 进程被杀（非断电）时系统缓存照样写回，先写临时文件再改名保证不出现半截文件。
  ///
  /// 同一份内容并发存（Anki 集合里常有多个文件名同一内容，迁移时并发预存）只有一个
  /// 写入者，其余等它（[_writing]）：否则一个在改名、另一个在核对读同一个目标文件，
  /// Windows 上会撞共享冲突。
  Future<String> store(String name, Uint8List bytes) {
    final String digest = sha1.convert(bytes).toString();
    final String ext = extensionOf(name);
    final String stored = ext.isEmpty ? digest : '$digest.$ext';
    return _writing[stored] ??= _write(stored, digest, bytes);
  }

  /// 进行中的写入（按存储文件名）。
  final Map<String, Future<String>> _writing = <String, Future<String>>{};

  Future<String> _write(String stored, String digest, Uint8List bytes) async {
    try {
      final File target = File(p.join(root.path, stored));
      final bool exists = await target.exists();
      if (exists &&
          await target.length() == bytes.length &&
          sha1.convert(await target.readAsBytes()).toString() == digest) {
        return stored;
      }
      if (!_rootReady) {
        await root.create(recursive: true);
        _rootReady = true;
      }
      // 先写临时文件再改名：进程中途被杀不会留下一个半截的「内容哈希」文件。
      final File tmp = File(
        '${target.path}.${Random().nextInt(1 << 30).toRadixString(36)}.tmp',
      );
      try {
        await tmp.writeAsBytes(bytes);
      } on PathNotFoundException {
        // 目录在本实例建好之后被删了（恢复备份会整体替换媒体目录）：重建再写。
        await root.create(recursive: true);
        await tmp.writeAsBytes(bytes);
      }
      // 同名但内容不对（断电留下的坏文件）：先删掉，改名才会替换它。
      if (exists && await target.exists()) await target.delete();
      try {
        await tmp.rename(target.path);
      } on FileSystemException {
        // 别的进程同时写了同一内容（Windows 上目标已存在时改名失败）：内容一样，留现有的。
        if (await tmp.exists()) await tmp.delete();
        if (!await target.exists()) rethrow;
      }
      return stored;
    } finally {
      _writing.remove(stored);
    }
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
