import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 弹弹play 文件识别哈希只读文件前 16 MiB（官方 `/api/v2/match` 约定）。
const int kDandanplayHashPrefixBytes = 16 * 1024 * 1024;

/// 弹弹play `/api/v2/match` 认的文件指纹：文件名（无扩展名）+ 前 16 MiB 的 md5 +
/// 文件字节数。
///
/// 抽到引擎层是为了让**持有文件的一端**算它：互联 client 远端流播时本机没有这个
/// 文件，弹幕匹配原本因此整条短路（BUG-3614）；host 用自己的文件算出指纹下发，
/// client 拿去问弹弹play，与「下载到本机再播」得到同一份匹配。
class DandanplayFileKey {
  const DandanplayFileKey({
    required this.fileName,
    required this.fileHash,
    required this.fileSize,
  });

  /// 去掉扩展名的文件名（弹弹play `fileName` 字段口径）。
  final String fileName;

  /// 文件前 [kDandanplayHashPrefixBytes] 字节的 md5（十六进制小写）。
  final String fileHash;

  /// 文件字节数。
  final int fileSize;

  Map<String, Object?> toJson() => <String, Object?>{
    'fileName': fileName,
    'fileHash': fileHash,
    'fileSize': fileSize,
  };

  /// 解析 wire JSON；缺字段 / 类型不对返回 null（调用方当作「拿不到指纹」）。
  static DandanplayFileKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? name = raw['fileName'];
    final Object? hash = raw['fileHash'];
    final Object? size = raw['fileSize'];
    if (name is! String || hash is! String || hash.isEmpty || size is! num) {
      return null;
    }
    return DandanplayFileKey(
      fileName: name,
      fileHash: hash,
      fileSize: size.toInt(),
    );
  }
}

/// [file] 前 [kDandanplayHashPrefixBytes] 字节的 md5。
Future<String> dandanplayFileHash(File file) async {
  final int length = file.lengthSync();
  final int end = math.min(length, kDandanplayHashPrefixBytes);
  final Digest digest = await md5.bind(file.openRead(0, end)).first;
  return digest.toString();
}

/// 现算 [file] 的弹弹play 指纹。
Future<DandanplayFileKey> dandanplayFileKeyOf(File file) async =>
    DandanplayFileKey(
      fileName: p.basenameWithoutExtension(file.path),
      fileHash: await dandanplayFileHash(file),
      fileSize: file.lengthSync(),
    );
