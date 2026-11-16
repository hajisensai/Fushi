// 构建信息：包名与签名证书摘要，随「按构建信息下发的服务端通知」请求一起发出
// （服务端 services/leaderboard 的 /v1/notices）。
//
// 两个来源互相独立：
//   - h：Android PackageManager 报告的签名证书（update 通道的 `buildInfo` 方法，MainActivity.java）；
//   - k：Dart 直接解析已安装 base APK 的 APK Signing Block 得到的签名证书。
// 两者都是证书 DER 的小写十六进制 SHA-256。非 Android 平台两者为空；任何读取 / 解析失败都
// 退化成空列表，绝不抛。结果按进程缓存一份。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 本构建的标识信息。[id] 是 Android applicationId（其他平台为 null）。
class BuildInfo {
  const BuildInfo({
    this.id,
    this.h = const <String>[],
    this.k = const <String>[],
  });

  /// Android applicationId；非 Android 为 null。
  final String? id;

  /// PackageManager 报告的签名证书 SHA-256（小写十六进制）。
  final List<String> h;

  /// 从 base APK 的 APK Signing Block 解析出的签名证书 SHA-256（小写十六进制）。
  final List<String> k;
}

Future<BuildInfo>? _cachedBuildInfo;

/// 读本构建的 [BuildInfo]。永不抛；非 Android 返回 `const BuildInfo()`；按进程缓存。
Future<BuildInfo> readBuildInfo() => _cachedBuildInfo ??= _loadBuildInfo();

Future<BuildInfo> _loadBuildInfo() async {
  if (!Platform.isAndroid) return const BuildInfo();
  String? id;
  List<String> h = const <String>[];
  String? apkPath;
  try {
    final Map<Object?, Object?>? raw = await FushiChannels.update
        .invokeMethod<Map<Object?, Object?>>('buildInfo');
    if (raw != null) {
      final Object? rawId = raw['id'];
      if (rawId is String && rawId.isNotEmpty) id = rawId;
      final Object? rawH = raw['h'];
      if (rawH is List) {
        h = List<String>.unmodifiable(
          rawH.whereType<String>().map((String s) => s.toLowerCase()),
        );
      }
      final Object? rawApk = raw['apk'];
      if (rawApk is String && rawApk.isNotEmpty) apkPath = rawApk;
    }
  } on Object catch (e) {
    debugPrint('BuildInfo: channel unavailable. $e');
  }
  List<String> k = const <String>[];
  if (apkPath != null) {
    final String path = apkPath;
    try {
      k = await Isolate.run<List<String>>(() => readApkSignerCertDigests(path));
    } on Object catch (e) {
      debugPrint('BuildInfo: apk read failed. $e');
    }
  }
  return BuildInfo(id: id, h: h, k: k);
}

/// 按 [offset] 读 [length] 字节；越界或失败返回 null。
typedef ByteRangeReader = Uint8List? Function(int offset, int length);

/// 同步读 [apkPath] 的签名证书摘要，只读文件尾部需要的区段。失败返回空列表。
List<String> readApkSignerCertDigests(String apkPath) {
  RandomAccessFile? file;
  try {
    file = File(apkPath).openSync();
    final RandomAccessFile f = file;
    final int fileLength = f.lengthSync();
    return signerCertDigestsFromReader((int offset, int length) {
      if (offset < 0 || length < 0 || offset + length > fileLength) return null;
      f.setPositionSync(offset);
      final Uint8List bytes = f.readSync(length);
      return bytes.length == length ? bytes : null;
    }, fileLength);
  } on Object {
    return const <String>[];
  } finally {
    try {
      file?.closeSync();
    } on Object {
      // 关闭失败不影响结果。
    }
  }
}

/// 纯函数：从整份 APK 字节里解析签名证书摘要。失败返回空列表。
List<String> parseSignerCertDigests(Uint8List apkBytes) =>
    signerCertDigestsFromReader((int offset, int length) {
      if (offset < 0 || length < 0 || offset + length > apkBytes.length) {
        return null;
      }
      return Uint8List.sublistView(apkBytes, offset, offset + length);
    }, apkBytes.length);

const int _eocdMagic = 0x06054b50;
const int _eocdMinSize = 22;
const int _maxZipCommentSize = 0xffff;
const int _blockFooterSize = 24; // uint64 块大小 + 16 字节魔数
const int _maxBlockSize = 16 * 1024 * 1024;
const int _v2BlockId = 0x7109871a;
const int _v3BlockId = 0xf05368c0;
final Uint8List _blockMagic = Uint8List.fromList('APK Sig Block 42'.codeUnits);

/// 纯核心：EOCD → 中央目录偏移 → 24 字节块尾（魔数 "APK Sig Block 42"）→ 签名块，
/// 遍历 ID-值对，优先取 v3（0xf05368c0），否则 v2（0x7109871a）；每个 signer 取
/// signed data 里证书序列的第一张（即该 signer 自身证书，与 PackageManager 报告的一致），
/// 算 DER 的 SHA-256，按出现顺序去重。任何格式不符都返回空列表。
List<String> signerCertDigestsFromReader(ByteRangeReader read, int fileLength) {
  try {
    final int? cdOffset = _centralDirectoryOffset(read, fileLength);
    if (cdOffset == null || cdOffset < _blockFooterSize) {
      return const <String>[];
    }
    final Uint8List? footer = read(
      cdOffset - _blockFooterSize,
      _blockFooterSize,
    );
    if (footer == null) return const <String>[];
    for (int i = 0; i < 16; i++) {
      if (footer[8 + i] != _blockMagic[i]) return const <String>[];
    }
    final ByteData footerData = ByteData.sublistView(footer);
    final int? blockSize = _readUint64(footerData, 0);
    if (blockSize == null ||
        blockSize < _blockFooterSize ||
        blockSize > _maxBlockSize) {
      return const <String>[];
    }
    final int blockStart = cdOffset - blockSize - 8;
    if (blockStart < 0) return const <String>[];
    final Uint8List? block = read(blockStart, blockSize + 8);
    if (block == null) return const <String>[];
    final ByteData data = ByteData.sublistView(block);
    if (_readUint64(data, 0) != blockSize) return const <String>[];

    final int pairsEnd = block.length - _blockFooterSize;
    Uint8List? v2;
    Uint8List? v3;
    int pos = 8;
    while (pos < pairsEnd) {
      if (pairsEnd - pos < 8) return const <String>[];
      final int? pairLength = _readUint64(data, pos);
      if (pairLength == null ||
          pairLength < 4 ||
          pairLength > pairsEnd - pos - 8) {
        return const <String>[];
      }
      final int id = data.getUint32(pos + 8, Endian.little);
      final int valueStart = pos + 12;
      final int valueEnd = pos + 8 + pairLength;
      if (id == _v3BlockId) {
        v3 ??= Uint8List.sublistView(block, valueStart, valueEnd);
      } else if (id == _v2BlockId) {
        v2 ??= Uint8List.sublistView(block, valueStart, valueEnd);
      }
      pos = valueEnd;
    }
    final Uint8List? scheme = v3 ?? v2;
    if (scheme == null) return const <String>[];
    return _signerCertDigests(scheme);
  } on Object {
    return const <String>[];
  }
}

/// 读 EOCD 拿中央目录偏移；找不到或越界返回 null。
int? _centralDirectoryOffset(ByteRangeReader read, int fileLength) {
  if (fileLength < _eocdMinSize) return null;
  final int tailLength = fileLength < _eocdMinSize + _maxZipCommentSize
      ? fileLength
      : _eocdMinSize + _maxZipCommentSize;
  final int tailStart = fileLength - tailLength;
  final Uint8List? tail = read(tailStart, tailLength);
  if (tail == null) return null;
  final ByteData data = ByteData.sublistView(tail);
  for (int i = tail.length - _eocdMinSize; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) != _eocdMagic) continue;
    final int commentLength = data.getUint16(i + 20, Endian.little);
    if (i + _eocdMinSize + commentLength != tail.length) continue;
    final int cdSize = data.getUint32(i + 12, Endian.little);
    final int cdOffset = data.getUint32(i + 16, Endian.little);
    final int eocdOffset = tailStart + i;
    if (cdOffset + cdSize != eocdOffset) return null;
    return cdOffset;
  }
  return null;
}

/// 小端 uint64；高 32 位非零（超出合理范围）返回 null。
int? _readUint64(ByteData data, int offset) {
  if (offset + 8 > data.lengthInBytes) return null;
  final int low = data.getUint32(offset, Endian.little);
  final int high = data.getUint32(offset + 4, Endian.little);
  if (high != 0) return null;
  return low;
}

/// 顺序读 uint32 长度前缀的子段；越界抛 [FormatException]。
class _LengthPrefixedReader {
  _LengthPrefixedReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _pos = 0;

  bool get hasRemaining => _pos < _bytes.length;

  Uint8List next() {
    if (_bytes.length - _pos < 4) throw const FormatException('short prefix');
    final int length = _data.getUint32(_pos, Endian.little);
    final int start = _pos + 4;
    if (length > _bytes.length - start) {
      throw const FormatException('length overflow');
    }
    _pos = start + length;
    return Uint8List.sublistView(_bytes, start, start + length);
  }
}

/// v2 / v3 方案值：signers 序列 → signer → signed data → digests、certificates。
List<String> _signerCertDigests(Uint8List schemeValue) {
  final _LengthPrefixedReader outer = _LengthPrefixedReader(schemeValue);
  final _LengthPrefixedReader signers = _LengthPrefixedReader(outer.next());
  final List<String> out = <String>[];
  while (signers.hasRemaining) {
    final _LengthPrefixedReader signer = _LengthPrefixedReader(signers.next());
    final _LengthPrefixedReader signedData = _LengthPrefixedReader(
      signer.next(),
    );
    signedData.next(); // digests
    final _LengthPrefixedReader certs = _LengthPrefixedReader(
      signedData.next(),
    );
    if (!certs.hasRemaining) continue;
    final Uint8List der = certs.next();
    if (der.isEmpty) continue;
    final String digest = sha256.convert(der).toString();
    if (!out.contains(digest)) out.add(digest);
  }
  return List<String>.unmodifiable(out);
}
