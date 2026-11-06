/// 按条目随机读 zip 文件（.apkg / .colpkg），**不把整个包读进内存**。
///
/// 只用 archive（本仓钉 ^3.6.1）解析中央目录：`ZipDirectory.read(InputFileStream)` 只按需读
/// 文件头，各条目的数据不读。条目数据按 [SrsZipEntry] 记下的偏移从文件里取：
/// - 小条目（媒体清单、fushi-ext、单个媒体文件）[readEntry] 一次读出并解压，峰值 ≈ 该条目大小；
/// - 大条目（集合 SQLite）[extractEntry] 以 [kSrsZipChunkBytes] 为块流式解压到文件，峰值与包大小无关。
///
/// deflate 用 dart:io 的原生 zlib（`ZLibDecoder(raw: true)`），不用 archive 的纯 Dart inflate。
/// Anki 只用 store / deflate 两种压缩方式；其它方式按损坏包处理。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart'
    show InputFileStream, ZipDirectory, ZipFileHeader;

/// 流式解压的块大小。
const int kSrsZipChunkBytes = 1 << 20;

/// zip 条目的定位信息（中央目录里的值；只是几个整数，可随结果跨 isolate 交回）。
class SrsZipEntry {
  const SrsZipEntry({
    required this.name,
    required this.localHeaderOffset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.method,
  });

  final String name;
  final int localHeaderOffset;
  final int compressedSize;
  final int uncompressedSize;

  /// 0 = store，8 = deflate。
  final int method;
}

/// zip 结构不对 / 用了不支持的压缩方式。
class SrsZipFormatException implements Exception {
  const SrsZipFormatException(this.message);
  final String message;

  @override
  String toString() => 'SrsZipFormatException: $message';
}

const int _kLocalHeaderSignature = 0x04034b50;
const int _kStore = 0;
const int _kDeflate = 8;

/// 读 [path] 的中央目录（同步；放在后台 isolate 里调用）。
Map<String, SrsZipEntry> srsReadZipIndex(String path) {
  final InputFileStream input = InputFileStream(path);
  try {
    final ZipDirectory dir = ZipDirectory.read(input);
    final Map<String, SrsZipEntry> out = <String, SrsZipEntry>{};
    for (final ZipFileHeader h in dir.fileHeaders) {
      final String name = h.filename.replaceAll(r'\', '/');
      out[name] = SrsZipEntry(
        name: name,
        localHeaderOffset: h.localHeaderOffset ?? 0,
        compressedSize: h.compressedSize ?? 0,
        uncompressedSize: h.uncompressedSize ?? 0,
        method: h.compressionMethod,
      );
    }
    return out;
  } finally {
    input.closeSync();
  }
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// 本地文件头之后数据的起点（本地头的文件名 / 扩展字段长度可能与中央目录不同，必须现读）。
int _dataOffsetSync(RandomAccessFile raf, SrsZipEntry e) {
  raf.setPositionSync(e.localHeaderOffset);
  final Uint8List h = raf.readSync(30);
  if (h.length < 30 || _u32(h, 0) != _kLocalHeaderSignature) {
    throw SrsZipFormatException('bad local header for ${e.name}');
  }
  return e.localHeaderOffset + 30 + _u16(h, 26) + _u16(h, 28);
}

Future<int> _dataOffset(RandomAccessFile raf, SrsZipEntry e) async {
  await raf.setPosition(e.localHeaderOffset);
  final Uint8List h = await raf.read(30);
  if (h.length < 30 || _u32(h, 0) != _kLocalHeaderSignature) {
    throw SrsZipFormatException('bad local header for ${e.name}');
  }
  return e.localHeaderOffset + 30 + _u16(h, 26) + _u16(h, 28);
}

void _checkMethod(SrsZipEntry e) {
  if (e.method != _kStore && e.method != _kDeflate) {
    throw SrsZipFormatException(
      'unsupported compression method ${e.method} for ${e.name}',
    );
  }
}

Uint8List _inflate(SrsZipEntry e, Uint8List compressed) {
  if (e.method == _kStore) return compressed;
  final List<int> out = ZLibDecoder(raw: true).convert(compressed);
  return out is Uint8List ? out : Uint8List.fromList(out);
}

/// 一次读出并解压一个条目（同步）。只用于小条目：峰值 ≈ 压缩大小 + 解压大小。
Uint8List srsReadZipEntrySync(RandomAccessFile raf, SrsZipEntry e) {
  _checkMethod(e);
  raf.setPositionSync(_dataOffsetSync(raf, e));
  final Uint8List compressed = raf.readSync(e.compressedSize);
  if (compressed.length != e.compressedSize) {
    throw SrsZipFormatException('truncated entry ${e.name}');
  }
  return _inflate(e, compressed);
}

/// 一次读出并解压一个条目（异步，按需读单个媒体文件用）。
Future<Uint8List> srsReadZipEntry(String path, SrsZipEntry e) async {
  _checkMethod(e);
  final RandomAccessFile raf = await File(path).open();
  try {
    await raf.setPosition(await _dataOffset(raf, e));
    final Uint8List compressed = await raf.read(e.compressedSize);
    if (compressed.length != e.compressedSize) {
      throw SrsZipFormatException('truncated entry ${e.name}');
    }
    return _inflate(e, compressed);
  } finally {
    await raf.close();
  }
}

/// 把一个条目流式解压到 [out]（同步；放在后台 isolate 里调用）。内存峰值 ≈ 两个块，与条目大小无关。
void srsExtractZipEntrySync(RandomAccessFile raf, SrsZipEntry e, File out) {
  _checkMethod(e);
  final int start = _dataOffsetSync(raf, e);
  final RandomAccessFile dst = out.openSync(mode: FileMode.write);
  try {
    final _RafSink sink = _RafSink(dst);
    final Sink<List<int>> target = e.method == _kDeflate
        ? ZLibDecoder(raw: true).startChunkedConversion(sink)
        : sink;
    raf.setPositionSync(start);
    int remaining = e.compressedSize;
    while (remaining > 0) {
      final int n = remaining < kSrsZipChunkBytes
          ? remaining
          : kSrsZipChunkBytes;
      final Uint8List chunk = raf.readSync(n);
      if (chunk.isEmpty) throw SrsZipFormatException('truncated ${e.name}');
      target.add(chunk);
      remaining -= chunk.length;
    }
    target.close();
    dst.flushSync();
  } finally {
    dst.closeSync();
  }
}

class _RafSink implements Sink<List<int>> {
  _RafSink(this._raf);
  final RandomAccessFile _raf;

  @override
  void add(List<int> data) => _raf.writeFromSync(data);

  @override
  void close() {}
}
