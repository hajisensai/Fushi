/// mokuro.moe 一卷的完整下载编排：`.mokuro`（小，直下）+ `.cbz`（大：`.part`
/// 断点续传 + zip 中央目录校验 + 原子 rename）→ isolate 流式解包（防路径穿越）
/// → [MangaImporter.importFromMokuroPath] 落库 → 清理临时目录。
///
/// 布局契约：CBZ 顶层是一个 `<卷名>/` 目录（内放页图），`.mokuro` 的 `img_path`
/// 与之一致（`<卷名>/001.jpg`）。解包目录 T 下得到 `T/<卷名>/*.jpg`，`.mokuro`
/// 落 `T/<卷名>.mokuro`——正好满足 [mangaImportCanImport] 的「同级一层子目录有图」
/// 判定，零转换直通现有导入链。
///
/// 下载范式照 `manga_ocr_model_downloader.dart`（Range 续传 / 416 / 非 206 处理），
/// 但 CBZ 无预知长度：完整性校验放宽为「zip 中央目录可解析」，不做 expectedBytes
/// 强校验。解包范式照 `backup_service.dart` 的 `_backupExtractWorker`（
/// `Isolate.spawn` + `InputFileStream` + 4MB 分块 + SendPort 回报进度）。
///
/// 多卷排队由 UI 层顺序 await，本类只管一卷；[cancel] 置标志、循环内检查，
/// 取消保留 `.part` 以便续传。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';

/// 两次字节进度事件之间至少累积的字节数（避免大 CBZ 每 chunk 一事件淹没 UI）。
const int kMokuroMoeProgressInterval = 512 * 1024;

/// 一卷下载所处阶段。
enum MokuroMoeDownloadStage {
  downloadingMokuro,
  downloadingCbz,
  extracting,
  importing,
  done,
}

/// 下载事件：阶段 + 字节进度（total 未知时为 null）+ 导入页进度。
/// [stage] == done 时 [bookKey] 非空（DuplicatePolicy.skip() 命中则 [skippedExisting]
/// 为 true、bookKey 为空——该卷已在库，视作成功但无新行）。
class MokuroMoeVolumeDownloadEvent {
  const MokuroMoeVolumeDownloadEvent({
    required this.stage,
    this.receivedBytes = 0,
    this.totalBytes,
    this.pagesDone = 0,
    this.pagesTotal = 0,
    this.bookKey,
    this.skippedExisting = false,
  });

  final MokuroMoeDownloadStage stage;
  final int receivedBytes;
  final int? totalBytes;
  final int pagesDone;
  final int pagesTotal;
  final String? bookKey;
  final bool skippedExisting;
}

/// [MokuroMoeVolumeDownloader.cancel] 中止时抛出（事件流以此收尾）；`.part`
/// 保留供下次续传。UI 层据类型区分「用户取消」与真实失败。
class MokuroMoeDownloadCancelled implements Exception {
  const MokuroMoeDownloadCancelled();

  @override
  String toString() => 'MokuroMoeDownloadCancelled';
}

/// 一卷的下载/解包/落库编排器（一次 [run]，不可复用）。
class MokuroMoeVolumeDownloader {
  MokuroMoeVolumeDownloader({
    required this.client,
    HttpClient Function()? createClient,
    Directory? stagingRoot,
    this.progressByteInterval = kMokuroMoeProgressInterval,
  })  : _createClient = createClient ?? _defaultClient,
        _stagingRoot = stagingRoot ??
            Directory(p.join(Directory.systemTemp.path, 'hibiki_mokuro_moe'));

  final MokuroMoeClient client;
  final HttpClient Function() _createClient;

  /// 断点续传的 `.part` / 已下完的 `.cbz` 落此根下的 `<系列>/<卷>/`
  /// 确定性子目录（跨次运行可续传）。
  final Directory _stagingRoot;

  final int progressByteInterval;

  bool _cancelled = false;

  static HttpClient _defaultClient() =>
      HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;

  /// 请求中止当前 run：下载循环在下个 chunk 处、阶段切换处检查并抛
  /// [MokuroMoeDownloadCancelled]；`.part` 保留。
  void cancel() => _cancelled = true;

  /// 入库标题：`<系列> <卷>`；卷名已含系列名时直接用卷名（照
  /// [MangaImporter] `_deriveTitle` 的去重口径）。
  static String volumeTitle(String series, String volume) {
    final String s = series.trim();
    final String v = volume.trim();
    if (s.isEmpty) return v.isEmpty ? 'manga' : v;
    if (v.isEmpty) return s;
    return v.contains(s) ? v : '$s $v';
  }

  /// 跑完一卷全流程。事件流以 done 事件正常结束；取消以
  /// [MokuroMoeDownloadCancelled] 错误结束；其余失败以原始异常结束。
  Stream<MokuroMoeVolumeDownloadEvent> run({
    required HibikiDatabase db,
    required String seriesName,
    required String volumeName,
  }) {
    final StreamController<MokuroMoeVolumeDownloadEvent> controller =
        StreamController<MokuroMoeVolumeDownloadEvent>();
    controller.onListen = () {
      _run(controller, db: db, seriesName: seriesName, volumeName: volumeName)
          .then((void _) => controller.close(),
              onError: (Object e, StackTrace stack) {
        controller.addError(e, stack);
        controller.close();
      });
    };
    return controller.stream;
  }

  Future<void> _run(
    StreamController<MokuroMoeVolumeDownloadEvent> controller, {
    required HibikiDatabase db,
    required String seriesName,
    required String volumeName,
  }) async {
    final Directory staging = Directory(p.join(
      _stagingRoot.path,
      sanitizeTtuFilename(seriesName),
      sanitizeTtuFilename(volumeName),
    ));
    await staging.create(recursive: true);
    final File mokuroFile = File(p.join(staging.path, 'volume.mokuro'));
    final File cbzFile = File(p.join(staging.path, 'volume.cbz'));
    final Directory extractDir = Directory(p.join(staging.path, 'extract'));

    try {
      // 1. `.mokuro`（小 JSON）：每次重下覆盖（保证与站点最新 OCR 一致）。
      _checkCancelled();
      controller.add(const MokuroMoeVolumeDownloadEvent(
        stage: MokuroMoeDownloadStage.downloadingMokuro,
      ));
      await _downloadSmall(
        client.mokuroUrl(seriesName, volumeName),
        mokuroFile,
      );

      // 2. `.cbz`：`.part` 断点续传 + zip 校验 + 原子 rename（已存在则直接复用
      // ——上次下载完成但导入失败的续跑路径）。
      _checkCancelled();
      if (!cbzFile.existsSync()) {
        await _downloadCbz(
          controller,
          url: client.cbzUrl(seriesName, volumeName),
          target: cbzFile,
        );
      }

      // 3. isolate 流式解包到 extract/（残留半成品先清掉，保证幂等）。
      _checkCancelled();
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
      extractDir.createSync(recursive: true);
      controller.add(const MokuroMoeVolumeDownloadEvent(
        stage: MokuroMoeDownloadStage.extracting,
      ));
      await _extractInIsolate(
        zipPath: cbzFile.path,
        destDirPath: extractDir.path,
        onBytes: _throttled(
          (int received) => controller.add(MokuroMoeVolumeDownloadEvent(
            stage: MokuroMoeDownloadStage.extracting,
            receivedBytes: received,
          )),
        ),
      );

      // 4. `.mokuro` 放到解包目录同级（`T/<卷名>.mokuro` 配 `T/<卷名>/` 图片目录，
      // 满足 mangaImportCanImport 的同级判定；img_path 相对 T 解析）。
      _checkCancelled();
      final File placedMokuro =
          File(p.join(extractDir.path, '$volumeName.mokuro'));
      mokuroFile.copySync(placedMokuro.path);

      // 5. 现有导入链落库（DuplicatePolicy.skip()：同名卷静默跳过，不复制成 `X (2)`）。
      controller.add(const MokuroMoeVolumeDownloadEvent(
        stage: MokuroMoeDownloadStage.importing,
      ));
      String? bookKey;
      bool skipped = false;
      try {
        bookKey = await MangaImporter.importFromMokuroPath(
          db: db,
          mokuroPath: placedMokuro.path,
          title: volumeTitle(seriesName, volumeName),
          policy: const DuplicatePolicy.skip(),
          onProgress: (int done, int total) =>
              controller.add(MokuroMoeVolumeDownloadEvent(
            stage: MokuroMoeDownloadStage.importing,
            pagesDone: done,
            pagesTotal: total,
          )),
        );
      } on DuplicateImportCancelledException {
        skipped = true;
      }

      controller.add(MokuroMoeVolumeDownloadEvent(
        stage: MokuroMoeDownloadStage.done,
        bookKey: bookKey,
        skippedExisting: skipped,
      ));

      // 成功/已在库：整个 staging 目录（含 cbz/.mokuro）不再需要，清掉。
      _tryDelete(staging);
    } catch (_) {
      // 失败/取消：只清解包半成品；`.part` / 已完成 `.cbz` 保留供续传/重试。
      _tryDelete(extractDir);
      rethrow;
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw const MokuroMoeDownloadCancelled();
  }

  static void _tryDelete(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// 小文件直下（`.mokuro`）：写 `.part` 再原子 rename，非 200 报错。
  Future<void> _downloadSmall(String url, File target) async {
    final HttpClient http = _createClient();
    try {
      final HttpClientRequest request = await http.getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw MokuroMoeHttpException(
          response.statusCode,
          uri: Uri.parse(url),
        );
      }
      final File part = File('${target.path}.part');
      final IOSink sink = part.openWrite();
      try {
        await for (final List<int> chunk in response) {
          _checkCancelled();
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
    } finally {
      http.close(force: true);
    }
  }

  /// CBZ 下载：`.part` 断点续传；无预知长度，完成校验 = zip 中央目录可解析。
  /// [retried] 防 416 重试无限递归（一次为限）。
  Future<void> _downloadCbz(
    StreamController<MokuroMoeVolumeDownloadEvent> controller, {
    required String url,
    required File target,
    bool retried = false,
  }) async {
    final File part = File('${target.path}.part');
    int offset = part.existsSync() ? part.lengthSync() : 0;

    final HttpClient http = _createClient();
    try {
      final HttpClientRequest request = await http.getUrl(Uri.parse(url));
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final HttpClientResponse response = await request.close();

      if (offset > 0 &&
          response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // `.part` 长度 >= 远端长度：要么上次已下完（rename 前中断），要么坏档。
        // 无 expectedBytes 可比，直接用 zip 解析判卷：能解析就转正；不能则删掉
        // 重下一次。
        await response.drain<void>();
        if (_zipParses(part.path)) {
          _finalizeCbz(part, target);
          return;
        }
        part.deleteSync();
        if (retried) {
          throw StateError('mokuro.moe CBZ invalid after retry: $url');
        }
        await _downloadCbz(controller, url: url, target: target, retried: true);
        return;
      }

      final IOSink sink;
      int received;
      int? total;
      if (offset > 0 && response.statusCode == HttpStatus.partialContent) {
        received = offset;
        total =
            response.contentLength > 0 ? offset + response.contentLength : null;
        sink = part.openWrite(mode: FileMode.append);
      } else if (response.statusCode == HttpStatus.ok) {
        // 服务器不支持 Range（或本就无残留）：整文件重下，截断旧残留。
        received = 0;
        total = response.contentLength > 0 ? response.contentLength : null;
        sink = part.openWrite();
      } else {
        await response.drain<void>();
        throw MokuroMoeHttpException(
          response.statusCode,
          uri: Uri.parse(url),
        );
      }

      int lastEmitted = received;
      controller.add(MokuroMoeVolumeDownloadEvent(
        stage: MokuroMoeDownloadStage.downloadingCbz,
        receivedBytes: received,
        totalBytes: total,
      ));
      try {
        await for (final List<int> chunk in response) {
          // 取消：先落已到的 chunk 再停，`.part` 保持前缀完整可续传。
          sink.add(chunk);
          received += chunk.length;
          _checkCancelled();
          if (received - lastEmitted >= progressByteInterval) {
            controller.add(MokuroMoeVolumeDownloadEvent(
              stage: MokuroMoeDownloadStage.downloadingCbz,
              receivedBytes: received,
              totalBytes: total,
            ));
            lastEmitted = received;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      controller.add(MokuroMoeVolumeDownloadEvent(
        stage: MokuroMoeDownloadStage.downloadingCbz,
        receivedBytes: received,
        totalBytes: total,
      ));
      if (!_zipParses(part.path)) {
        // 坏档不可信（续传基底错位/传输损坏），删掉避免下次在坏偏移上加码。
        try {
          part.deleteSync();
        } catch (_) {}
        throw StateError('mokuro.moe CBZ is not a valid zip: $url');
      }
      _finalizeCbz(part, target);
    } finally {
      http.close(force: true);
    }
  }

  static void _finalizeCbz(File part, File target) {
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
  }

  /// zip 中央目录可解析且至少有一个 entry（不解压，仅结构校验）。
  static bool _zipParses(String path) {
    InputFileStream? input;
    try {
      input = InputFileStream(path);
      final Archive archive = ZipDecoder().decodeBuffer(input);
      return archive.files.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      input?.closeSync();
    }
  }

  /// 把逐 chunk 字节回报聚成累计值再按 [progressByteInterval] 节流。
  void Function(int chunkBytes) _throttled(void Function(int received) emit) {
    int received = 0;
    int lastEmitted = 0;
    return (int chunkBytes) {
      received += chunkBytes;
      if (received - lastEmitted >= progressByteInterval) {
        emit(received);
        lastEmitted = received;
      }
    };
  }

  /// 后台 isolate 解包（照 backup_service `_extractEntriesStreaming` 范式）。
  Future<void> _extractInIsolate({
    required String zipPath,
    required String destDirPath,
    required void Function(int chunkBytes) onBytes,
  }) async {
    final ReceivePort port = ReceivePort();
    final Completer<void> completer = Completer<void>();
    port.listen((dynamic message) {
      if (message is int) {
        onBytes(message);
      } else if (message == _extractDoneToken) {
        if (!completer.isCompleted) completer.complete();
        port.close();
      } else {
        // Worker 失败（'errorText'）或未捕获 isolate 错误（[error, stack]）。
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('mokuro.moe CBZ extraction failed: $message'),
          );
        }
        port.close();
      }
    });
    final Isolate isolate = await Isolate.spawn(
      _extractCbzWorker,
      _ExtractRequest(zipPath, destDirPath, port.sendPort),
      onError: port.sendPort,
    );
    try {
      await completer.future;
    } finally {
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

const String _extractDoneToken = 'mokuro-moe-extract-done';

/// 可跨 isolate 传递的解包请求。
class _ExtractRequest {
  const _ExtractRequest(this.zipPath, this.destDirPath, this.sendPort);
  final String zipPath;
  final String destDirPath;
  final SendPort sendPort;
}

/// 后台 isolate 入口：重开 zip、逐 entry 校验路径（防穿越）后流式落盘。
void _extractCbzWorker(_ExtractRequest request) {
  final SendPort port = request.sendPort;
  InputFileStream? input;
  try {
    input = InputFileStream(request.zipPath);
    final Archive archive = ZipDecoder().decodeBuffer(input);
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final List<String> segments = _safeEntrySegments(file.name);
      final String dest = p.joinAll(<String>[request.destDirPath, ...segments]);
      _streamArchiveFileToDisk(file, dest, port);
    }
    port.send(_extractDoneToken);
  } catch (error, stack) {
    port.send('$error\n$stack');
  } finally {
    input?.closeSync();
  }
}

/// zip entry 名 → 安全相对路径段。含 `..` / 绝对路径 / 盘符的 entry 一律拒绝
/// （zip 路径穿越红线）。
List<String> _safeEntrySegments(String entryName) {
  if (entryName.startsWith('/') ||
      entryName.startsWith('\\') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(entryName)) {
    throw StateError('zip entry uses absolute path: $entryName');
  }
  final List<String> segments = entryName
      .split(RegExp(r'[\\/]+'))
      .where((String s) => s.isNotEmpty && s != '.')
      .toList();
  if (segments.isEmpty || segments.any((String s) => s == '..')) {
    throw StateError('zip entry escapes destination: $entryName');
  }
  return segments;
}

/// 单 entry 流式落盘：STORE 走 4MB 分块拷贝（逐块回报字节），DEFLATE 流式
/// inflate（照 backup_service `_streamArchiveFileToDisk`）。
void _streamArchiveFileToDisk(
    ArchiveFile file, String destPath, SendPort port) {
  File(destPath).parent.createSync(recursive: true);
  final OutputFileStream output = OutputFileStream(destPath);
  try {
    final InputStreamBase? raw = file.rawContent;
    if (raw != null && !file.isCompressed) {
      const int chunkSize = 4 * 1024 * 1024; // 每块 4MB 峰值堆
      final int total = raw.length;
      int written = 0;
      while (written < total) {
        final int want =
            (total - written) < chunkSize ? (total - written) : chunkSize;
        final Uint8List bytes = raw.readBytes(want).toUint8List();
        if (bytes.isEmpty) break;
        output.writeBytes(bytes);
        written += bytes.length;
        port.send(bytes.length);
      }
    } else if (raw != null && file.compressionType == ArchiveFile.DEFLATE) {
      Inflate.stream(raw, output);
      port.send(file.size);
    } else {
      // 兜底（已物化内容）：整块写。
      output.writeBytes(file.content as List<int>);
      port.send(file.size);
    }
  } finally {
    output.closeSync();
  }
}
