// Electron asar 归档的只读访问：解析头、按成员 offset/size 精确读一个成员。
//
// 格式（Chromium Pickle 包着 JSON 头）：
//   u32 4 | u32 header_size | u32 payload_size | u32 json_length | JSON | 对齐填充 | 文件数据
// 文件数据基址 = 8 + header_size；成员 `{"size": n, "offset": "<十进制字符串>"}` 的
// offset 相对该基址；`"unpacked": true` 的成员不在包里，而在同级 `<包名>.unpacked/` 目录；
// `"link"` 成员（符号链接）不跟随。目录成员是 `{"files": {...}}`。

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 头 JSON 的长度上限（带全部文件索引，大游戏也就几 MB；超过视为不是 asar）。
const int kAsarMaxHeaderJsonBytes = 64 * 1024 * 1024;

/// asar 里的一个文件成员。
class AsarMember {
  /// 创建成员描述。
  const AsarMember({
    required this.path,
    required this.size,
    required this.offset,
    required this.unpacked,
  });

  /// 包内相对路径（`/` 分隔）。
  final String path;

  /// 字节数。
  final int size;

  /// 相对文件数据基址的偏移（unpacked 成员无意义，为 0）。
  final int offset;

  /// 是否在 `<包名>.unpacked/` 目录里。
  final bool unpacked;
}

/// 一个已解析头的 asar 归档。
class AsarArchive {
  AsarArchive._({
    required this.path,
    required this.dataBase,
    required this.fileLength,
    required Map<String, Object?> root,
  }) : _root = root;

  /// 归档文件路径。
  final String path;

  /// 文件数据基址（= 8 + header_size）。
  final int dataBase;

  /// 打开时的归档文件长度（成员越界校验用）。
  final int fileLength;

  final Map<String, Object?> _root;

  /// 顶层条目名。
  Set<String> get topLevelEntries {
    final Object? files = _root['files'];
    return files is Map<String, Object?> ? files.keys.toSet() : <String>{};
  }

  /// 同步解析 [asarPath] 的头；不是合法 asar 返回 null。只读文件头，不读整包。
  static AsarArchive? openSync(String asarPath) {
    RandomAccessFile? raf;
    try {
      raf = File(asarPath).openSync();
      final int length = raf.lengthSync();
      final Uint8List head = raf.readSync(16);
      if (head.length < 16) return null;
      final ByteData data = ByteData.sublistView(head);
      if (data.getUint32(0, Endian.little) != 4) return null;
      final int headerSize = data.getUint32(4, Endian.little);
      final int jsonLength = data.getUint32(12, Endian.little);
      if (jsonLength <= 0 || jsonLength > kAsarMaxHeaderJsonBytes) return null;
      final int dataBase = 8 + headerSize;
      if (dataBase < 16 + jsonLength || dataBase > length) return null;
      final Uint8List jsonBytes = raf.readSync(jsonLength);
      if (jsonBytes.length != jsonLength) return null;
      final Object? decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['files'] is! Map<String, Object?>) return null;
      return AsarArchive._(
        path: asarPath,
        dataBase: dataBase,
        fileLength: length,
        root: decoded,
      );
    } on Object {
      return null;
    } finally {
      raf?.closeSync();
    }
  }

  /// [openSync] 放到后台 isolate（头 JSON 可达数 MB，不在 UI isolate 上解析）。
  static Future<AsarArchive?> open(String asarPath) =>
      Isolate.run(() => openSync(asarPath));

  /// 按包内相对路径（`/` 或 `\` 分隔）找文件成员；不存在 / 是目录 / 是链接 /
  /// 字段不合法 / 越界返回 null。
  AsarMember? member(String relativePath) {
    final List<String> segments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((String s) => s.isNotEmpty && s != '.')
        .toList();
    if (segments.isEmpty || segments.contains('..')) return null;
    Map<String, Object?> node = _root;
    for (final String segment in segments) {
      final Object? files = node['files'];
      if (files is! Map<String, Object?>) return null;
      final Object? child = files[segment];
      if (child is! Map<String, Object?>) return null;
      node = child;
    }
    if (node.containsKey('files') || node.containsKey('link')) return null;
    final Object? size = node['size'];
    if (size is! int || size < 0) return null;
    final bool unpacked = node['unpacked'] == true;
    if (unpacked) {
      return AsarMember(
        path: segments.join('/'),
        size: size,
        offset: 0,
        unpacked: true,
      );
    }
    final Object? rawOffset = node['offset'];
    final int? offset = rawOffset is String
        ? int.tryParse(rawOffset)
        : (rawOffset is int ? rawOffset : null);
    if (offset == null || offset < 0) return null;
    if (dataBase + offset + size > fileLength) return null;
    return AsarMember(
      path: segments.join('/'),
      size: size,
      offset: offset,
      unpacked: false,
    );
  }

  /// 读成员原始字节：包内成员按 `dataBase + offset` 精确读 `size` 字节；unpacked 成员
  /// 读 `<归档>.unpacked/<成员>` 且大小必须与头一致。读不全 / 超 [maxBytes] 返回 null。
  Future<Uint8List?> read(AsarMember member, {required int maxBytes}) async {
    if (member.size > maxBytes) return null;
    if (member.unpacked) {
      final File file = File(
        '$path.unpacked${Platform.pathSeparator}'
        '${member.path.replaceAll('/', Platform.pathSeparator)}',
      );
      try {
        final Uint8List bytes = await file.readAsBytes();
        return bytes.length == member.size ? bytes : null;
      } on FileSystemException {
        return null;
      }
    }
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      await raf.setPosition(dataBase + member.offset);
      final Uint8List bytes = await raf.read(member.size);
      return bytes.length == member.size ? bytes : null;
    } on FileSystemException {
      return null;
    } finally {
      await raf?.close();
    }
  }
}
