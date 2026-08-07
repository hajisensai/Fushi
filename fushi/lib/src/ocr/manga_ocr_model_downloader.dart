/// 漫画 OCR 模型下载器：逐文件字节进度、`.part` 临时名 + 原子 rename、
/// HTTP Range 断点续传、系统代理环境变量。
///
/// 事件契约对齐 [MangaOcrDownloadEvent]：按文件粒度报告 receivedBytes /
/// totalBytes；全部文件完成后最后发一次 `done=true`；任何失败以 error 事件
/// 结束流（async* 抛出即 error）。
///
/// http 栈：`dart:io` [HttpClient] + `findProxyFromEnvironment`（与
/// `update_checker_net.dart` 同范式——只读 `HTTPS_PROXY`/`HTTP_PROXY` 等
/// 环境变量，无覆盖时自然 DIRECT），不引新依赖。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';

/// 默认进度事件的字节间隔（避免大文件每 chunk 一事件淹没 UI）。
const int kMangaOcrDownloadProgressInterval = 512 * 1024;

/// 模型下载器。[createClient] 可注入（测试指向本地 HttpServer）。
class MangaOcrModelDownloader {
  MangaOcrModelDownloader({
    HttpClient Function()? createClient,
    this.progressByteInterval = kMangaOcrDownloadProgressInterval,
  }) : _createClient = createClient ?? _defaultClient;

  final HttpClient Function() _createClient;

  /// 两次进度事件之间至少累积的字节数（首尾事件恒发）。
  final int progressByteInterval;

  static HttpClient _defaultClient() =>
      HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;

  /// 下载清单里所有未就绪文件到 [targetDir]。
  ///
  /// - 已就绪文件跳过（仍发一条 received==total 的完成进度，让 UI 汇总正确）。
  /// - `.part` 残留触发 Range 续传；服务器不支持（非 206）则整文件重下。
  /// - 单文件完成：长度非零 + （expected>0 时）长度==expected，然后原子
  ///   rename `.part` → 最终名。
  /// - 全部完成后补发 `done=true` 收尾事件。
  Stream<MangaOcrDownloadEvent> downloadAll({
    required List<MangaOcrModelFile> files,
    required Directory targetDir,
  }) async* {
    if (files.isEmpty) {
      return;
    }
    await targetDir.create(recursive: true);
    final HttpClient client = _createClient();
    try {
      for (final MangaOcrModelFile file in files) {
        final File target = File(p.join(targetDir.path, file.fileName));
        if (isMangaOcrModelFileReady(target)) {
          final int size = target.lengthSync();
          yield MangaOcrDownloadEvent(
            fileName: file.fileName,
            receivedBytes: size,
            totalBytes: size,
          );
          continue;
        }
        yield* _downloadFile(client, file, target);
      }
      final MangaOcrModelFile last = files.last;
      yield MangaOcrDownloadEvent(
        fileName: last.fileName,
        receivedBytes: last.expectedBytes,
        totalBytes: last.expectedBytes,
        done: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  Stream<MangaOcrDownloadEvent> _downloadFile(
    HttpClient client,
    MangaOcrModelFile file,
    File target,
  ) async* {
    final File part = File('${target.path}.part');
    int offset = part.existsSync() ? part.lengthSync() : 0;

    final HttpClientRequest request = await client.getUrl(Uri.parse(file.url));
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final HttpClientResponse response = await request.close();

    if (offset > 0 &&
        response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        file.expectedBytes > 0 &&
        offset == file.expectedBytes) {
      // `.part` 已经完整（上次在 rename 前中断），服务器对 bytes=<len>- 回 416：
      // 不再拉流，直接走校验 + 原子转正。
      await response.drain<void>();
      yield _finalizePart(file, part, target);
      return;
    }

    final IOSink sink;
    int received;
    int total;
    if (offset > 0 && response.statusCode == HttpStatus.partialContent) {
      // Range 命中：从 offset 续写。
      received = offset;
      total = response.contentLength > 0
          ? offset + response.contentLength
          : math.max(file.expectedBytes, offset);
      sink = part.openWrite(mode: FileMode.append);
    } else if (response.statusCode == HttpStatus.ok) {
      // 服务器不支持 Range（或本就无残留）：整文件重下，截断旧残留。
      received = 0;
      total = response.contentLength > 0
          ? response.contentLength
          : file.expectedBytes;
      sink = part.openWrite();
      offset = 0;
    } else {
      await response.drain<void>();
      throw HttpException(
        'download ${file.fileName} failed: HTTP ${response.statusCode}',
        uri: Uri.parse(file.url),
      );
    }

    int lastEmitted = -1;
    try {
      yield MangaOcrDownloadEvent(
        fileName: file.fileName,
        receivedBytes: received,
        totalBytes: total,
      );
      lastEmitted = received;
      await for (final List<int> chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (received - lastEmitted >= progressByteInterval) {
          yield MangaOcrDownloadEvent(
            fileName: file.fileName,
            receivedBytes: received,
            totalBytes: total,
          );
          lastEmitted = received;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    yield _finalizePart(file, part, target);
  }

  /// 完成一个 `.part`：实际大小校验（非零恒查；expected>0 时长度校验——传输
  /// 截断/上游漂移都在 rename 前拦截，绝不把坏档转正）+ 原子 rename，返回该
  /// 文件的完成事件。
  MangaOcrDownloadEvent _finalizePart(
    MangaOcrModelFile file,
    File part,
    File target,
  ) {
    final int actual = part.lengthSync();
    if (actual <= 0) {
      throw StateError('download ${file.fileName} produced empty file');
    }
    if (file.expectedBytes > 0 && actual != file.expectedBytes) {
      // 长度不符的 .part 不可信，删掉避免下次 Range 续传在坏偏移上加码。
      try {
        part.deleteSync();
      } catch (_) {}
      throw StateError('download ${file.fileName} size mismatch: '
          'got $actual, expected ${file.expectedBytes}');
    }

    // 原子转正：目标若有非法残留（0 字节）先清掉再 rename。
    if (target.existsSync()) {
      target.deleteSync();
    }
    part.renameSync(target.path);
    return MangaOcrDownloadEvent(
      fileName: file.fileName,
      receivedBytes: actual,
      totalBytes: actual,
    );
  }
}
