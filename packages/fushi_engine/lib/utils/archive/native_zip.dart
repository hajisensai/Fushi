/// zip 读写的原生 zlib 通道：解压与压缩都走 `dart:io` 的 [ZLibCodec]
/// （`raw: true` = 无 zlib/gzip 头，正是 zip 条目的编码），按 4 MB 分块流式。
///
/// 为什么不用 archive 3.6.1 自带的路径：
/// - `Inflate.stream(raw, OutputFileStream)`（以及 `ArchiveFile.decompress(out)`）
///   是纯 Dart，每个 LZ77 回溯引用都要经 `OutputFileStream.subset` 去 flush +
///   seek + 读文件，实测 1.13 MB/s。
/// - `ArchiveFile.writeContent(out)` / `.content` 虽然在 IO 平台上用的是原生
///   zlib，但会把**整个条目**解压进内存（`ZipFile.content` → `inflateBuffer`）
///   才落盘，几百 MB 的条目在移动端直接 OOM。
/// - `ZipEncoder` / `ZipFileEncoder`（level ≠ STORE）用纯 Dart `Deflate`，并且
///   先把整个文件 `toUint8List()` 再压缩。
///
/// 本文件的函数只消费条目的原始压缩窗口 [ArchiveFile.rawContent]，内存峰值是
/// 一个读块（解压）或压缩后的体积（压缩）。
library;

import 'dart:io' show Directory, File, FileSystemEntity, RandomAccessFile;
import 'dart:io' as io show ZLibCodec, ZLibOption;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// 读 / 写的分块大小：每块的堆峰值。
const int kNativeZipChunkBytes = 4 * 1024 * 1024;

/// 已经是压缩格式的扩展名：再 deflate 只浪费 CPU，直接 STORE。
const Set<String> kAlreadyCompressedExtensions = <String>{
  '.jpg', '.jpeg', '.png', '.webp', '.gif', '.avif', '.heic', '.jxl', //
  '.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.oga', '.opus', '.flac', //
  '.mp4', '.m4v', '.mkv', '.webm', //
  '.zip', '.gz', '.7z', '.rar', '.xz', '.bz2', '.zst', '.cbz', '.epub', //
  '.woff', '.woff2',
};

/// 把 [raw] 从头读完，按 [kNativeZipChunkBytes] 分块交给 [onChunk]。
///
/// 读前先 `reset()`：条目的原始窗口可能已被读过（例如先 `.content` 再落盘），
/// 不复位会从中间开始读出截断的数据。
void forEachRawZipChunk(
  InputStreamBase raw,
  void Function(Uint8List bytes) onChunk,
) {
  raw.reset();
  final int total = raw.length;
  int read = 0;
  while (read < total) {
    final int want = (total - read) < kNativeZipChunkBytes
        ? (total - read)
        : kNativeZipChunkBytes;
    final Uint8List bytes = raw.readBytes(want).toUint8List();
    if (bytes.isEmpty) break;
    onChunk(bytes);
    read += bytes.length;
  }
}

/// 用原生 zlib 解压原始 DEFLATE 流 [raw]，每产出一块解压数据调用一次 [onChunk]。
///
/// 压缩数据损坏时 `dart:io` 抛 [FormatException]；但**截断**的流（缺尾块）
/// `dart:io` 不报错、只产出前半段（实测），所以条目级的完整性由
/// [writeZipEntryStreaming] 按中央目录记录的解压后大小核对。
void inflateRawDeflate(
  InputStreamBase raw,
  void Function(List<int> chunk) onChunk,
) {
  final Sink<List<int>> inflater = io.ZLibCodec(
    raw: true,
  ).decoder.startChunkedConversion(_CallbackSink(onChunk));
  forEachRawZipChunk(raw, inflater.add);
  inflater.close();
}

/// 把一个 zip 条目流式写进 [out]，返回写出的解压后字节数。
///
/// - STORE：原始窗口即解压后数据，分块拷贝；
/// - DEFLATE：[inflateRawDeflate] 原生分块解压；
/// - 其它（bzip2 等，本仓自己的包不产出）：退回 archive 的 `writeContent`，
///   正确但会整条目入内存。
///
/// [onBytes] 每写出一块回报该块的（解压后）字节数，供进度条持续推进。
///
/// 不能用 `ArchiveFile.decompress(out)`：`ZipDecoder` 解出的条目 `_content` 是
/// `ZipFile`（非 null），`decompress(out)` 直接 no-op、写出 0 字节。
int writeZipEntryStreaming(
  ArchiveFile file,
  OutputStreamBase out, {
  void Function(int bytes)? onBytes,
}) {
  final InputStreamBase? raw = file.rawContent;
  int written = 0;
  void write(List<int> chunk) {
    if (chunk.isEmpty) return;
    out.writeBytes(chunk);
    written += chunk.length;
    onBytes?.call(chunk.length);
  }

  if (raw != null && file.compressionType == ArchiveFile.STORE) {
    forEachRawZipChunk(raw, write);
    _checkEntrySize(file, written);
  } else if (raw != null && file.compressionType == ArchiveFile.DEFLATE) {
    inflateRawDeflate(raw, write);
    _checkEntrySize(file, written);
  } else {
    file.writeContent(out);
    written = file.size;
    onBytes?.call(file.size);
  }
  return written;
}

/// 写出字节数必须等于条目头记录的解压后大小：截断的 DEFLATE 流 `dart:io` 不报错，
/// 不核对就会把半截文件当成功落盘。
void _checkEntrySize(ArchiveFile file, int written) {
  if (written != file.size) {
    throw FormatException(
      'zip entry ${file.name}: wrote $written bytes, header says ${file.size}',
    );
  }
}

/// 把 [file] 流式解压到磁盘 [destPath]（父目录自动创建）。返回写出的字节数。
int extractZipEntryToFile(
  ArchiveFile file,
  String destPath, {
  void Function(int bytes)? onBytes,
}) {
  File(destPath).parent.createSync(recursive: true);
  final OutputFileStream out = OutputFileStream(destPath);
  try {
    return writeZipEntryStreaming(file, out, onBytes: onBytes);
  } finally {
    out.closeSync();
  }
}

/// [entryName] 落在 [outputDir] 下的目标路径；越界（zip-slip）返回 null。
String? zipEntryOutputPath(String outputDir, String entryName) {
  final String target = p.normalize(p.join(outputDir, p.normalize(entryName)));
  if (!p.isWithin(p.canonicalize(outputDir), p.canonicalize(target))) {
    return null;
  }
  return target;
}

/// 把磁盘上的 zip [zipPath] 整包流式解到 [outputDir]：只读中央目录，条目逐个
/// 原生解压落盘，任何时刻只有一个读块在内存里。
///
/// 与 archive 的 `extractFileToDisk` 对齐的语义：只写常规文件（目录按需创建）、
/// 越出 [outputDir] 的条目跳过；不还原符号链接（本仓的导入源都不需要，且符号链接
/// 是 zip-slip 的另一条路）。
void extractZipFileToDirectory(String zipPath, String outputDir) {
  Directory(outputDir).createSync(recursive: true);
  final InputFileStream input = InputFileStream(zipPath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    for (final ArchiveFile file in archive.files) {
      final String? target = zipEntryOutputPath(outputDir, file.name);
      if (target == null) continue;
      if (!file.isFile) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      if (file.isSymbolicLink) continue;
      extractZipEntryToFile(file, target);
    }
  } finally {
    input.closeSync();
  }
}

/// 内存里的 [bytes] 用原生 zlib deflate 成 zip 条目，交给 `ZipEncoder` 时原样
/// 透传（`isCompressed && rawContent != null` 分支），不再走纯 Dart `Deflate`。
///
/// 压缩后不变小（含空内容）时返回 STORE 条目。
ArchiveFile nativeDeflatedArchiveFile(
  String name,
  List<int> bytes, {
  int level = io.ZLibOption.defaultLevel,
}) {
  if (bytes.isEmpty) {
    return ArchiveFile(name, 0, Uint8List(0))..compress = false;
  }
  final List<int> compressed = io.ZLibCodec(
    raw: true,
    level: level,
  ).encode(bytes);
  if (compressed.length >= bytes.length) {
    return ArchiveFile(name, bytes.length, bytes)..compress = false;
  }
  // 传 InputStream 而不是 List：List 会被同时当成 `_content`（解压后内容），
  // 之后谁读 `.content` 都会拿到压缩字节。
  return ArchiveFile(
    name,
    bytes.length,
    InputStream(compressed),
    ArchiveFile.DEFLATE,
  )..crc32 = getCrc32(bytes);
}

/// 把磁盘文件 [file] 以 [name] 加进 [encoder]：原生 deflate 分块读文件、增量算
/// CRC，内存峰值 = 压缩后体积 + 一个读块（archive 的 GZIP 档要整文件入内存再压）。
///
/// 已是压缩格式（[kAlreadyCompressedExtensions]）或压缩后不变小的文件走 STORE，
/// STORE 由 archive 真流式写出、不整文件入内存。
void addFileNativeDeflate(
  ZipFileEncoder encoder,
  File file,
  String name, {
  int level = io.ZLibOption.defaultLevel,
}) {
  final int size = file.lengthSync();
  if (size == 0 ||
      kAlreadyCompressedExtensions.contains(p.extension(name).toLowerCase())) {
    _addStoredFile(encoder, file, name);
    return;
  }

  final BytesBuilder compressed = BytesBuilder(copy: false);
  final Sink<List<int>> deflater = io.ZLibCodec(
    raw: true,
    level: level,
  ).encoder.startChunkedConversion(_CallbackSink(compressed.add));
  int crc = 0;
  final RandomAccessFile raf = file.openSync();
  try {
    while (true) {
      final Uint8List chunk = raf.readSync(kNativeZipChunkBytes);
      if (chunk.isEmpty) break;
      crc = getCrc32(chunk, crc);
      deflater.add(chunk);
    }
  } finally {
    raf.closeSync();
  }
  deflater.close();

  if (compressed.length >= size) {
    _addStoredFile(encoder, file, name);
    return;
  }
  final ArchiveFile entry =
      ArchiveFile(
          name,
          size,
          InputStream(compressed.takeBytes()),
          ArchiveFile.DEFLATE,
        )
        ..crc32 = crc
        ..lastModTime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000
        ..mode = file.statSync().mode;
  encoder.addArchiveFile(entry);
}

void _addStoredFile(ZipFileEncoder encoder, File file, String name) {
  final InputFileStream stream = InputFileStream(file.path);
  try {
    final ArchiveFile entry =
        ArchiveFile.stream(name, file.lengthSync(), stream)
          ..compress = false
          ..lastModTime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000
          ..mode = file.statSync().mode;
    encoder.addArchiveFile(entry);
  } finally {
    stream.closeSync();
  }
}

/// [ZipFileEncoder.addDirectory] 的原生 zlib 版：同样的条目集合与命名（含目录
/// 条目、`includeDirName` 语义），文件内容走 [addFileNativeDeflate]。
void addDirectoryNativeDeflate(
  ZipFileEncoder encoder,
  Directory dir, {
  bool includeDirName = true,
  bool followLinks = true,
}) {
  final String dirName = p.basename(dir.path);
  final List<FileSystemEntity> entities = dir.listSync(
    recursive: true,
    followLinks: followLinks,
  );
  for (final FileSystemEntity entity in entities) {
    final String rel = p.relative(entity.path, from: dir.path);
    final String name = includeDirName ? '$dirName/$rel' : rel;
    if (entity is Directory) {
      final ArchiveFile af = ArchiveFile('$name/', 0, null)
        ..mode = entity.statSync().mode
        ..lastModTime =
            entity.statSync().modified.millisecondsSinceEpoch ~/ 1000
        ..isFile = false;
      encoder.addArchiveFile(af);
    } else if (entity is File) {
      addFileNativeDeflate(encoder, entity, name);
    }
  }
}

/// 把 zlib 产出的每一块转交给回调。
class _CallbackSink implements Sink<List<int>> {
  _CallbackSink(this._onChunk);

  final void Function(List<int> chunk) _onChunk;

  @override
  void add(List<int> chunk) {
    if (chunk.isNotEmpty) _onChunk(chunk);
  }

  @override
  void close() {}
}
