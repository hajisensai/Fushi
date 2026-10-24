// 远端原盘（第二期）：host 把一张盘按「只读目录 + 文件清单」共享给已配对对端。
//
// 一份清单同时服务两条路：
//   - 整盘下载：client 按清单逐个文件 Range 续传，落地后就是一张本地原盘；
//   - 流式原盘菜单：client 的 libbluray / libdvdnav 不再读本地文件系统，读文件走
//     HTTP Range，列目录查这份清单（libmpv 补丁 `disc-navigation-state.patch`）。
//
// 清单里**只有相对路径**（正斜杠、无 `..`），host 的绝对路径从不下发；host 端的
// 文件服务也只认清单里列出的路径（白名单），不做任何路径拼接意义上的「穿越检查」。
//
// 收录哪些文件（2026-10-24 交接文档「第二期」）：
//   - 蓝光：`BDMV/` 整棵树、`CERTIFICATE/`（BD-J 证书，有就带）；`AACS/` **只在盘上
//     还有 AACS 密文码流时**才带——明文副本带着 `AACS/` 会让 client 的 libbluray 去
//     加载 libaacs，按加密盘处理，而它根本不需要密钥。
//   - DVD：`VIDEO_TS/` 整个目录（CSS 由 libdvdcss 在 client 侧处理）。
//   - 镜像（`.iso`）：就是一个文件。
//
// 纯 Dart、不碰 Flutter（引擎纯度守卫）。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_encryption.dart'
    show isAacsEncryptedStreamFile, isBdavStreamPath;
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart'
    show findDvdVideoTsIfo, isDiscImagePath;

/// 清单格式版本。改字段语义就加一，client 认不得的版本按「host 太新」处理。
const int kDiscShareManifestVersion = 1;

/// 一份清单最多收录的文件数。真实 BD 几百个、DVD 几十个；上万个就不是一张盘。
const int kDiscShareMaxFiles = 20000;

/// 盘的形态：目录树，或单个镜像文件。
enum DiscShareLayout { directory, image }

/// 清单里的一个文件。
class DiscShareFile {
  const DiscShareFile({
    required this.path,
    required this.size,
    required this.modifiedAt,
  });

  /// 相对盘根的路径，正斜杠分隔（`BDMV/STREAM/00000.m2ts`）。
  final String path;

  /// 字节数。
  final int size;

  /// 最后修改时刻（毫秒），续传验证器的一部分。
  final int modifiedAt;

  /// 与 `/files/` 端点的 ETag 同一口径：size 或 mtime 变了，旧 `.part` 不再续。
  String get etag => '"disc-$size-$modifiedAt"';

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'size': size,
    'modifiedAt': modifiedAt,
  };

  static DiscShareFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? path = json['path'];
    final Object? size = json['size'];
    final Object? modifiedAt = json['modifiedAt'];
    if (path is! String || !isSafeDiscSharePath(path)) return null;
    if (size is! int || size < 0) return null;
    if (modifiedAt is! int) return null;
    return DiscShareFile(path: path, size: size, modifiedAt: modifiedAt);
  }
}

/// 一张被共享的盘。
class DiscShareManifest {
  const DiscShareManifest({
    required this.discKey,
    required this.name,
    required this.format,
    required this.layout,
    required this.aacs,
    required this.files,
  });

  /// 盘身份：host 盘根绝对路径的 SHA-1（不下发路径本身）。同一张盘的几条标题拿到
  /// 同一个键，client 据此把「下载整张盘」去重成一个任务。
  final String discKey;

  /// 盘目录名（`Disc 2`）或镜像文件名（`MOVIE.iso`）——落地到 client 时用它命名。
  final String name;
  final DiscFormat format;
  final DiscShareLayout layout;

  /// 清单里带了 `AACS/`：盘上仍有密文，client 打开前要从自己的 KEYDB 取这张盘的
  /// 密钥（与本地加密盘同一策略）。
  final bool aacs;
  final List<DiscShareFile> files;

  int get totalBytes =>
      files.fold<int>(0, (int sum, DiscShareFile f) => sum + f.size);

  /// 按相对路径找文件（精确匹配）。
  DiscShareFile? fileAt(String path) {
    for (final DiscShareFile file in files) {
      if (file.path == path) return file;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kDiscShareManifestVersion,
    'discKey': discKey,
    'name': name,
    'format': format.name,
    'layout': layout.name,
    'aacs': aacs,
    'files': <Map<String, Object?>>[
      for (final DiscShareFile file in files) file.toJson(),
    ],
  };

  /// 严格解析：任一字段不合法（包括任一路径不安全）整份拒收，返回 null。清单来自
  /// 网络，宁可报「对端清单无效」也不落一张缺文件的盘。
  static DiscShareManifest? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['version'] != kDiscShareManifestVersion) return null;
    final Object? discKey = json['discKey'];
    final Object? name = json['name'];
    final Object? rawFiles = json['files'];
    final DiscFormat? format = _enumByName(DiscFormat.values, json['format']);
    final DiscShareLayout? layout = _enumByName(
      DiscShareLayout.values,
      json['layout'],
    );
    if (discKey is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(discKey)) {
      return null;
    }
    if (name is! String || !isSafeDiscShareName(name)) return null;
    if (format == null || layout == null) return null;
    if (rawFiles is! List ||
        rawFiles.isEmpty ||
        rawFiles.length > kDiscShareMaxFiles) {
      return null;
    }
    final List<DiscShareFile> files = <DiscShareFile>[];
    final Set<String> seen = <String>{};
    for (final Object? raw in rawFiles) {
      final DiscShareFile? file = DiscShareFile.fromJson(raw);
      if (file == null || !seen.add(file.path.toLowerCase())) return null;
      files.add(file);
    }
    if (layout == DiscShareLayout.image &&
        (files.length != 1 || files.single.path.contains('/'))) {
      return null;
    }
    return DiscShareManifest(
      discKey: discKey,
      name: name,
      format: format,
      layout: layout,
      aacs: json['aacs'] == true,
      files: files,
    );
  }
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  for (final T value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// 相对路径是否可以安全地落到任何盘根之下：非空、正斜杠分隔、每段非空且不是
/// `.` / `..`、不含反斜杠 / 盘符冒号 / 控制字符。
bool isSafeDiscSharePath(String path) {
  if (path.isEmpty || path.length > 512) return false;
  if (path.startsWith('/') || path.contains('\\') || path.contains(':')) {
    return false;
  }
  for (final int unit in path.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return false;
  }
  for (final String segment in path.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
    if (!isSafeDiscShareName(segment)) return false;
  }
  return true;
}

/// 单个文件 / 目录名是否可以直接拿来在 client 上命名（Windows 规则最严，按它判）。
bool isSafeDiscShareName(String name) {
  if (name.isEmpty || name.length > 255) return false;
  if (name == '.' || name == '..') return false;
  if (name.endsWith('.') || name.endsWith(' ')) return false;
  return !RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name);
}

/// 盘身份：盘根绝对路径（规范化后）的 SHA-1。
String discShareKeyForRoot(String discRoot) =>
    sha1.convert(utf8.encode(p.normalize(p.absolute(discRoot)))).toString();

/// 为 [discRoot]（含 `BDMV` / `VIDEO_TS` 的目录，或 DVD `.iso`）建清单；不是一张
/// 认得出的盘返回 null。[isEncryptedStream] 可注入（测试）。
Future<DiscShareManifest?> buildDiscShareManifest(
  String discRoot, {
  Future<bool> Function(String streamPath) isEncryptedStream =
      isAacsEncryptedStreamFile,
}) async {
  final DiscFormat? format = await readDiscFormatAtRoot(discRoot);
  if (format == null) return null;
  final String key = discShareKeyForRoot(discRoot);
  final String name = p.basename(p.normalize(discRoot));
  if (!isSafeDiscShareName(name)) return null;
  if (isDiscImagePath(discRoot) &&
      FileSystemEntity.typeSync(discRoot) == FileSystemEntityType.file) {
    final File image = File(discRoot);
    return DiscShareManifest(
      discKey: key,
      name: name,
      format: format,
      layout: DiscShareLayout.image,
      aacs: false,
      files: <DiscShareFile>[_fileEntry(image, name)],
    );
  }
  final List<DiscShareFile> files = <DiscShareFile>[];
  bool aacs = false;
  if (format == DiscFormat.dvd) {
    final String? ifo = findDvdVideoTsIfo(discRoot);
    if (ifo == null) return null;
    _collectTree(discRoot, p.dirname(ifo), files);
    if (files.isEmpty) return null;
  } else {
    final String? bdmv = _childDirectory(discRoot, 'BDMV');
    if (bdmv == null) return null;
    _collectTree(discRoot, bdmv, files);
    final String? certificate = _childDirectory(discRoot, 'CERTIFICATE');
    if (certificate != null) _collectTree(discRoot, certificate, files);
    final String? aacsDir = _childDirectory(discRoot, 'AACS');
    if (aacsDir != null &&
        await _hasEncryptedStream(files, discRoot, isEncryptedStream)) {
      _collectTree(discRoot, aacsDir, files);
      aacs = true;
    }
  }
  if (files.length > kDiscShareMaxFiles) return null;
  files.sort((DiscShareFile a, DiscShareFile b) => a.path.compareTo(b.path));
  return DiscShareManifest(
    discKey: key,
    name: name,
    format: format,
    layout: DiscShareLayout.directory,
    aacs: aacs,
    files: files,
  );
}

/// 盘根下名为 [name] 的子目录（精确大小写优先，再退大小写不敏感）。
String? _childDirectory(String root, String name) {
  final Directory exact = Directory(p.join(root, name));
  if (exact.existsSync()) return exact.path;
  try {
    for (final FileSystemEntity entity in Directory(
      root,
    ).listSync(followLinks: false)) {
      if (entity is Directory &&
          p.basename(entity.path).toUpperCase() == name.toUpperCase()) {
        return entity.path;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// 把 [directory] 下的所有普通文件（递归，不跟符号链接）按相对 [root] 的路径收进
/// [out]。名字不能安全落地的文件跳过——那不是盘的一部分。
void _collectTree(String root, String directory, List<DiscShareFile> out) {
  final List<FileSystemEntity> entities;
  try {
    entities = Directory(
      directory,
    ).listSync(recursive: true, followLinks: false);
  } on FileSystemException {
    return;
  }
  for (final FileSystemEntity entity in entities) {
    if (entity is! File) continue;
    final String relative = p
        .relative(entity.path, from: root)
        .split(p.separator)
        .join('/');
    if (!isSafeDiscSharePath(relative)) continue;
    out.add(_fileEntry(entity, relative));
    if (out.length > kDiscShareMaxFiles) return;
  }
}

DiscShareFile _fileEntry(File file, String relative) {
  final FileStat stat = file.statSync();
  return DiscShareFile(
    path: relative,
    size: stat.size,
    modifiedAt: stat.modified.millisecondsSinceEpoch,
  );
}

/// 菜单也会读标题表引用不到的码流，所以每一段码流都算（与本地菜单会话
/// `prepareBlurayMenuAacs` 同一口径）。
Future<bool> _hasEncryptedStream(
  List<DiscShareFile> files,
  String root,
  Future<bool> Function(String streamPath) isEncryptedStream,
) async {
  for (final DiscShareFile file in files) {
    if (!isBdavStreamPath(file.path)) continue;
    if (await isEncryptedStream(
      p.joinAll(<String>[root, ...file.path.split('/')]),
    )) {
      return true;
    }
  }
  return false;
}

/// host 端把清单路径映射回本机绝对路径。**只认清单里列出的路径**；不在清单里的
/// 一律 null（包括任何构造出来的穿越路径）。
String? resolveDiscShareFilePath(
  String discRoot,
  DiscShareManifest manifest,
  String relativePath,
) {
  final DiscShareFile? file = manifest.fileAt(relativePath);
  if (file == null) return null;
  if (manifest.layout == DiscShareLayout.image) return discRoot;
  return p.joinAll(<String>[discRoot, ...file.path.split('/')]);
}
