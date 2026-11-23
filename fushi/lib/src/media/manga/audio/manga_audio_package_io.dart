/// 有声漫画导出包的读写底层：错误类型、取消令牌、在独立 isolate 里流式写包 / 解包。
///
/// 写包与解包都在 `Isolate.spawn` 起的工作 isolate 里跑（几百 MB 的页图与音频不能占住
/// UI isolate），进度按字节经 [SendPort] 回传；取消 = 直接杀掉工作 isolate，再由调用方
/// 删掉半成品（写包写的是 `<目标>.part`，解包解在调用方独占的暂存目录里）。zip 条目
/// 一律流式（`native_zip.dart`：原生 zlib / CRC，任何时刻只有一个读块在内存里）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart';

/// 导出 / 导入失败。[code] 稳定（路由的错误码、界面文案都按它分），[details] 是逐条
/// 说明（缺失的文件、出错的卷）。
class MangaAudioPackageException implements Exception {
  const MangaAudioPackageException(
    this.code,
    this.message, {
    this.details = const <String>[],
  });

  final String code;
  final String message;
  final List<String> details;

  @override
  String toString() =>
      'MangaAudioPackageException($code): $message'
      '${details.isEmpty ? '' : ' [${details.take(5).join(', ')}]'}';
}

/// 用户取消了导出 / 导入。
class MangaAudioPackageCancelled implements Exception {
  const MangaAudioPackageCancelled();

  @override
  String toString() => 'MangaAudioPackageCancelled';
}

/// 取消令牌：[cancel] 置位并立刻调用当前登记的中止钩子（杀掉正在写包 / 解包的
/// isolate）；各阶段之间由 [throwIfCancelled] 检查。
class MangaPackageCancelToken {
  bool _cancelled = false;
  void Function()? _abort;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _abort?.call();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const MangaAudioPackageCancelled();
  }

  /// 登记 / 清掉当前重活的中止钩子。
  void onAbort(void Function()? abort) => _abort = abort;
}

/// 一个要写进包里的条目：磁盘文件（[sourcePath]）或内存字节（[bytes]）二选一。
class MangaPackageZipEntry {
  const MangaPackageZipEntry.file(this.name, String this.sourcePath)
    : bytes = null;

  const MangaPackageZipEntry.bytes(this.name, Uint8List this.bytes)
    : sourcePath = null;

  /// 包内路径（正斜杠）。
  final String name;
  final String? sourcePath;
  final Uint8List? bytes;
}

/// 包里 JSON 条目走 deflate，其余（页图、音频，本来就是压缩格式）stored。
bool _deflates(String name) => name.toLowerCase().endsWith('.json');

/// 在工作 isolate 里把 [entries] 写成 zip [outputPath]（先写 `.part` 再改名，失败 /
/// 取消删掉半成品）。[onBytes] 按写完的源字节回报进度。
Future<void> writeMangaAudioPackageZip({
  required String outputPath,
  required List<MangaPackageZipEntry> entries,
  void Function(int deltaBytes)? onBytes,
  MangaPackageCancelToken? cancel,
}) async {
  final String partPath = '$outputPath.part';
  final File part = File(partPath);
  try {
    await _runWorker(
      _zipWorker,
      <Object?>[
        partPath,
        <String>[for (final MangaPackageZipEntry e in entries) e.name],
        <Object?>[
          for (final MangaPackageZipEntry e in entries) e.sourcePath ?? e.bytes,
        ],
      ],
      onBytes: onBytes,
      cancel: cancel,
    );
    final File target = File(outputPath);
    if (await target.exists()) await target.delete();
    await part.rename(outputPath);
  } catch (_) {
    if (await part.exists()) await part.delete();
    rethrow;
  }
}

/// 在工作 isolate 里把包 [zipPath] 整个流式解到 [outputDir]（逐条目核对 CRC）。只解
/// 安全的包内路径（[isSafeMangaAudioPackagePath]），其余条目跳过。[onBytes] 按写出的
/// 解压后字节回报进度。
Future<void> extractMangaAudioPackageZip({
  required String zipPath,
  required String outputDir,
  void Function(int deltaBytes)? onBytes,
  MangaPackageCancelToken? cancel,
}) => _runWorker(
  _unzipWorker,
  <Object?>[zipPath, outputDir],
  onBytes: onBytes,
  cancel: cancel,
);

/// 包里所有文件条目的解压后总字节（读中央目录，不解压）。
Future<int> mangaAudioPackageUncompressedBytes(String zipPath) =>
    Isolate.run(() {
      final InputFileStream input = InputFileStream(zipPath);
      try {
        int total = 0;
        for (final ArchiveFile f in ZipDecoder().decodeBuffer(input).files) {
          if (f.isFile) total += f.size;
        }
        return total;
      } finally {
        input.closeSync();
      }
    });

/// 只读包里的 `package.json` 并解析（不解包）。不是 zip / 没有包清单 / 清单坏都抛
/// [MangaAudioPackageFormatException]。
Future<MangaAudioPackageManifest> readMangaAudioPackageManifest(
  String zipPath,
) async {
  final String? text = await Isolate.run(() {
    final InputFileStream input;
    try {
      input = InputFileStream(zipPath);
    } on Object {
      return null;
    }
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      for (final ArchiveFile f in archive.files) {
        if (f.isFile && f.name == kMangaAudioPackageManifestName) {
          return utf8.decode(f.content as List<int>);
        }
      }
      return null;
    } on Object {
      return null;
    } finally {
      input.closeSync();
    }
  });
  if (text == null) {
    throw const MangaAudioPackageFormatException(
      'not_package',
      'not a zip with package.json',
    );
  }
  return MangaAudioPackageManifest.parse(text);
}

// ─────────────────────────────────────────────────────────────────────────
// 工作 isolate
// ─────────────────────────────────────────────────────────────────────────

const String _kDone = 'done';

/// 起一个工作 isolate 跑 [entry]（参数 = `[SendPort, ...args]`），转发进度、等它结束。
/// 工作端发 int = 进度字节、`'done'` = 完成、`['error', 文本]` = 失败。取消时杀掉
/// isolate 并抛 [MangaAudioPackageCancelled]。
Future<void> _runWorker(
  void Function(List<Object?> message) entry,
  List<Object?> args, {
  void Function(int deltaBytes)? onBytes,
  MangaPackageCancelToken? cancel,
}) async {
  cancel?.throwIfCancelled();
  final ReceivePort port = ReceivePort();
  final ReceivePort exitPort = ReceivePort();
  final ReceivePort errorPort = ReceivePort();
  final Completer<void> done = Completer<void>();
  Isolate? isolate;
  void fail(Object error) {
    if (!done.isCompleted) done.completeError(error);
  }

  port.listen((Object? message) {
    if (message is int) {
      onBytes?.call(message);
    } else if (message == _kDone) {
      if (!done.isCompleted) done.complete();
    } else if (message is List && message.length == 2) {
      fail(MangaAudioPackageException('io_failed', '${message[1]}'));
    }
  });
  errorPort.listen((Object? message) {
    fail(
      MangaAudioPackageException(
        'io_failed',
        message is List && message.isNotEmpty ? '${message.first}' : '$message',
      ),
    );
  });
  exitPort.listen((Object? _) {
    // 工作端正常收尾前一定先发 done；先收到退出说明它被杀掉或崩了。
    fail(
      cancel?.isCancelled ?? false
          ? const MangaAudioPackageCancelled()
          : const MangaAudioPackageException(
              'io_failed',
              'package worker exited unexpectedly',
            ),
    );
  });
  try {
    isolate = await Isolate.spawn<List<Object?>>(
      entry,
      <Object?>[port.sendPort, ...args],
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
      errorsAreFatal: true,
    );
    cancel?.onAbort(() {
      isolate?.kill(priority: Isolate.immediate);
      fail(const MangaAudioPackageCancelled());
    });
    if (cancel?.isCancelled ?? false) {
      isolate.kill(priority: Isolate.immediate);
      fail(const MangaAudioPackageCancelled());
    }
    await done.future;
  } finally {
    cancel?.onAbort(null);
    port.close();
    exitPort.close();
    errorPort.close();
  }
}

/// 写包的工作端：`[SendPort, partPath, names, sources]`。
void _zipWorker(List<Object?> message) {
  final SendPort out = message[0]! as SendPort;
  final String partPath = message[1]! as String;
  final List<String> names = (message[2]! as List<Object?>).cast<String>();
  final List<Object?> sources = message[3]! as List<Object?>;
  final ZipFileEncoder encoder = ZipFileEncoder();
  try {
    encoder.create(partPath);
    for (int i = 0; i < names.length; i++) {
      final String name = names[i];
      final Object? source = sources[i];
      if (source is String) {
        final File file = File(source);
        final int size = file.lengthSync();
        if (_deflates(name)) {
          addFileNativeDeflate(encoder, file, name);
        } else {
          addFileStored(encoder, file, name);
        }
        out.send(size);
      } else if (source is Uint8List) {
        encoder.addArchiveFile(nativeDeflatedArchiveFile(name, source));
        out.send(source.length);
      }
    }
    encoder.closeSync();
    out.send(_kDone);
  } on Object catch (e) {
    try {
      encoder.closeSync();
    } on Object {
      // 已经在失败路径上：关不掉也只剩删半成品，由主 isolate 做。
    }
    out.send(<Object?>['error', '$e']);
  }
}

/// 解包的工作端：`[SendPort, zipPath, outputDir]`。
void _unzipWorker(List<Object?> message) {
  final SendPort out = message[0]! as SendPort;
  final String zipPath = message[1]! as String;
  final String outputDir = message[2]! as String;
  InputFileStream? input;
  try {
    Directory(outputDir).createSync(recursive: true);
    input = InputFileStream(zipPath);
    final Archive archive = ZipDecoder().decodeBuffer(input);
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile || file.isSymbolicLink) continue;
      if (!isSafeMangaAudioPackagePath(file.name)) continue;
      final String? target = zipEntryOutputPath(outputDir, file.name);
      if (target == null) continue;
      extractZipEntryToFile(file, target, onBytes: out.send, verifyCrc32: true);
    }
    out.send(_kDone);
  } on Object catch (e) {
    out.send(<Object?>['error', '$e']);
  } finally {
    input?.closeSync();
  }
}
