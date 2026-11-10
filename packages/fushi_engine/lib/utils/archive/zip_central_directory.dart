import 'dart:convert';
import 'dart:typed_data';

/// 按字节区间读一份 zip 的回调：返回 `[offset, offset + length)` 的**恰好** [length]
/// 字节（读不全由实现抛异常）。
typedef ZipRangeRead = Future<Uint8List> Function(int offset, int length);

/// zip 中央目录里的一个条目。
class ZipCentralDirectoryEntry {
  const ZipCentralDirectoryEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.localHeaderOffset,
  });

  /// 条目路径（通用位 11 置位时按 UTF-8 解，否则按字节原样映射）。
  final String name;

  /// 压缩方法（0 = stored，8 = deflate）。
  final int method;
  final int compressedSize;
  final int size;
  final int localHeaderOffset;
}

/// 中央目录读不出来：不是 zip、目录结尾 / 中央目录损坏、或目录大到超出上限。
class ZipCentralDirectoryException implements Exception {
  const ZipCentralDirectoryException(this.message);

  final String message;

  @override
  String toString() => 'ZipCentralDirectoryException: $message';
}

const int _kEocdSignature = 0x06054b50;
const int _kZip64LocatorSignature = 0x07064b50;
const int _kZip64EocdSignature = 0x06064b50;
const int _kCentralEntrySignature = 0x02014b50;
const int _kEocdLength = 22;
const int _kZip64LocatorLength = 20;
const int _kZip64EocdLength = 56;

/// EOCD 最远可能在文件尾往前多少字节：EOCD 22 字节 + 最长 65535 字节注释，再加
/// zip64 定位器 20 字节。
const int _kMaxTailLength = _kEocdLength + 0xFFFF + _kZip64LocatorLength;

/// 只靠按区间读拿到一份 zip 的整份中央目录（支持 zip64），不读条目数据。
///
/// 读法：先读文件尾 [initialTailBytes] 字节找目录结尾（EOCD）——Fushi 打的包与绝大多数
/// zip 不带注释，EOCD 就在最后 22 字节；找不到才把尾巴扩到规范上限（64 KiB 注释）。
/// 中央目录若已落在读到的尾巴里就直接切出来，否则再读一次目录本身。典型的书 / 漫画包
/// 中央目录几 KB 到几十 KB，所以总共 1～2 次区间读。
///
/// [length] 是整份 zip 的字节数。中央目录超过 [maxCentralDirectoryBytes] 时抛
/// [ZipCentralDirectoryException]（不为一个异常大的目录无上限地下载）；结构不对同样抛
/// [ZipCentralDirectoryException]。[read] 自己的异常（网络 / 鉴权）原样上抛。
Future<List<ZipCentralDirectoryEntry>> readZipCentralDirectory({
  required int length,
  required ZipRangeRead read,
  int initialTailBytes = 16 * 1024,
  int maxCentralDirectoryBytes = 16 * 1024 * 1024,
}) async {
  if (length < _kEocdLength) {
    throw const ZipCentralDirectoryException('shorter than an EOCD record');
  }
  int tailLength = initialTailBytes < _kEocdLength
      ? _kEocdLength
      : initialTailBytes;
  if (tailLength > length) tailLength = length;
  Uint8List tail = await read(length - tailLength, tailLength);
  int eocd = _findEocd(tail);
  if (eocd < 0 && tailLength < length && tailLength < _kMaxTailLength) {
    tailLength = length < _kMaxTailLength ? length : _kMaxTailLength;
    tail = await read(length - tailLength, tailLength);
    eocd = _findEocd(tail);
  }
  if (eocd < 0) {
    throw const ZipCentralDirectoryException(
      'end of central directory not found',
    );
  }
  final int tailStart = length - tailLength;
  final ByteData t = ByteData.sublistView(tail);
  int count = t.getUint16(eocd + 10, Endian.little);
  int cdSize = t.getUint32(eocd + 12, Endian.little);
  int cdOffset = t.getUint32(eocd + 16, Endian.little);
  if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
    final int locator = eocd - _kZip64LocatorLength;
    if (locator < 0 ||
        t.getUint32(locator, Endian.little) != _kZip64LocatorSignature) {
      throw const ZipCentralDirectoryException('zip64 locator missing');
    }
    final int z64Offset = t.getUint64(locator + 8, Endian.little);
    if (z64Offset < 0 || z64Offset + _kZip64EocdLength > length) {
      throw const ZipCentralDirectoryException('zip64 EOCD out of range');
    }
    final ByteData z = ByteData.sublistView(
      await _slice(tail, tailStart, z64Offset, _kZip64EocdLength, read),
    );
    if (z.getUint32(0, Endian.little) != _kZip64EocdSignature) {
      throw const ZipCentralDirectoryException('zip64 EOCD corrupt');
    }
    count = z.getUint64(32, Endian.little);
    cdSize = z.getUint64(40, Endian.little);
    cdOffset = z.getUint64(48, Endian.little);
  }
  if (cdSize < 0 || cdOffset < 0 || cdOffset + cdSize > length) {
    throw const ZipCentralDirectoryException('central directory out of range');
  }
  if (cdSize > maxCentralDirectoryBytes) {
    throw ZipCentralDirectoryException(
      'central directory too large: $cdSize bytes',
    );
  }
  final Uint8List cd = await _slice(tail, tailStart, cdOffset, cdSize, read);
  return _parseCentralDirectory(cd, count);
}

/// 从尾巴末端往前找 EOCD 签名；找不到返回 -1。
int _findEocd(Uint8List tail) {
  final ByteData t = ByteData.sublistView(tail);
  for (int i = tail.length - _kEocdLength; i >= 0; i--) {
    if (t.getUint32(i, Endian.little) == _kEocdSignature) return i;
  }
  return -1;
}

/// `[offset, offset + size)` 已在读到的尾巴里就切出来，否则再读一次。
Future<Uint8List> _slice(
  Uint8List tail,
  int tailStart,
  int offset,
  int size,
  ZipRangeRead read,
) {
  if (offset >= tailStart && offset + size <= tailStart + tail.length) {
    return Future<Uint8List>.value(
      Uint8List.sublistView(
        tail,
        offset - tailStart,
        offset - tailStart + size,
      ),
    );
  }
  return read(offset, size);
}

List<ZipCentralDirectoryEntry> _parseCentralDirectory(Uint8List cd, int count) {
  final ByteData c = ByteData.sublistView(cd);
  final List<ZipCentralDirectoryEntry> entries = <ZipCentralDirectoryEntry>[];
  int pos = 0;
  for (int i = 0; i < count; i++) {
    if (pos + 46 > cd.length ||
        c.getUint32(pos, Endian.little) != _kCentralEntrySignature) {
      throw const ZipCentralDirectoryException('central directory corrupt');
    }
    final int flags = c.getUint16(pos + 8, Endian.little);
    final int method = c.getUint16(pos + 10, Endian.little);
    int compressed = c.getUint32(pos + 20, Endian.little);
    int size = c.getUint32(pos + 24, Endian.little);
    final int nameLen = c.getUint16(pos + 28, Endian.little);
    final int extraLen = c.getUint16(pos + 30, Endian.little);
    final int commentLen = c.getUint16(pos + 32, Endian.little);
    int offset = c.getUint32(pos + 42, Endian.little);
    final int nameStart = pos + 46;
    final int extraEnd = nameStart + nameLen + extraLen;
    if (extraEnd + commentLen > cd.length) {
      throw const ZipCentralDirectoryException('central directory truncated');
    }
    final Uint8List nameBytes = Uint8List.sublistView(
      cd,
      nameStart,
      nameStart + nameLen,
    );
    final String name = (flags & 0x0800) != 0
        ? utf8.decode(nameBytes, allowMalformed: true)
        : String.fromCharCodes(nameBytes);
    // zip64 扩展字段：只有为 0xFFFFFFFF 的字段按 size/compressed/offset 顺序出现。
    int extra = nameStart + nameLen;
    while (extra + 4 <= extraEnd) {
      final int id = c.getUint16(extra, Endian.little);
      final int len = c.getUint16(extra + 2, Endian.little);
      if (id == 0x0001) {
        int f = extra + 4;
        if (size == 0xFFFFFFFF && f + 8 <= extraEnd) {
          size = c.getUint64(f, Endian.little);
          f += 8;
        }
        if (compressed == 0xFFFFFFFF && f + 8 <= extraEnd) {
          compressed = c.getUint64(f, Endian.little);
          f += 8;
        }
        if (offset == 0xFFFFFFFF && f + 8 <= extraEnd) {
          offset = c.getUint64(f, Endian.little);
        }
      }
      extra += 4 + len;
    }
    entries.add(
      ZipCentralDirectoryEntry(
        name: name,
        method: method,
        compressedSize: compressed,
        size: size,
        localHeaderOffset: offset,
      ),
    );
    pos = extraEnd + commentLen;
  }
  return entries;
}
