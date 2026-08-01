/// 跨媒体共享的图片下载工具（刮削封面落地用）。
///
/// 把一个远程图片 URL 下载成本地临时文件，供上层再拷进各自的封面存储（书族走
/// `setOverrideThumbnailFromMediaItem` 的缩略图目录，视频走 video_covers 等）。
/// 含 Content-Type / 字节魔数双重「是不是图片」校验，避免把错误页（text/html）当封面。
///
/// 说明：视频侧 `cover_downloader.dart` 有一份等价的下载+魔数逻辑，落地目录不同。待
/// P3「封面服务统一」时让它也复用本工具；本文件先服务书籍刮削（P1b）。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 图片下载异常（网络失败 / 非 2xx / 非图片）。绝不吞异常，交上层给用户可见提示。
class ImageDownloadException implements Exception {
  const ImageDownloadException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'ImageDownloadException: $message'
      : 'ImageDownloadException($statusCode): $message';
}

/// 远端封面原图下载的统一截止时间。
///
/// 原图通常比候选列表缩略图大，弱网或代理链路下 30 秒容易在响应完成前误杀；
/// 100 秒仍是有界等待，同时给高分辨率封面留出足够传输时间。
const Duration kCoverImageDownloadTimeout = Duration(seconds: 100);

/// 发送一个受 [timeout] 约束、可在截止时取消底层传输的封面 GET 请求。
///
/// 单独给 Future 加 `timeout` 只会停止等待，源 HTTP 请求和响应流仍可能继续。本 helper
/// 改用 package:http 的 [http.AbortableRequest]：截止回调先触发 abort，再向调用方抛
/// [TimeoutException]。默认 IOClient 会据此中止未完成请求或取消正在读取的响应流；
/// client 本身不关闭，因此视频侧的复用 client 及调用方注入 client 的所有权不变。
Future<http.Response> fetchCoverImageResponse(
  http.Client client,
  Uri url, {
  Duration timeout = kCoverImageDownloadTimeout,
}) {
  final Completer<void> abort = Completer<void>();
  final http.AbortableRequest request = http.AbortableRequest(
    'GET',
    url,
    abortTrigger: abort.future,
  );
  final Future<http.Response> response =
      client.send(request).then(http.Response.fromStream);
  return response.timeout(
    timeout,
    onTimeout: () {
      if (!abort.isCompleted) abort.complete();
      throw TimeoutException('cover image download timed out', timeout);
    },
  );
}

/// 下载 [url] 指向的图片到临时文件，返回该文件。
///
/// - [client]：默认自建（下载完关闭）；测试注入 mock client（不关闭，由调用方管理）。
/// - [tempDir]：缺省 [Directory.systemTemp]；测试注入临时目录。
/// - 校验：HTTP 2xx + 图片内容（Content-Type 以 `image/` 开头，或字节魔数是
///   JPEG/PNG/WebP/GIF）。非图片 → 抛 [ImageDownloadException]。
/// - 文件名按 URL 派生（同 URL 复下覆盖同一临时文件，不堆垃圾）。
Future<File> downloadImageToTempFile(
  String url, {
  http.Client? client,
  Directory? tempDir,
  Duration timeout = kCoverImageDownloadTimeout,
}) async {
  final http.Client httpClient = client ?? http.Client();
  try {
    final http.Response response;
    try {
      response = await fetchCoverImageResponse(
        httpClient,
        Uri.parse(url),
        timeout: timeout,
      );
    } on TimeoutException {
      throw const ImageDownloadException('image download timed out');
    } catch (e) {
      throw ImageDownloadException('image request failed: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ImageDownloadException(
        'image download HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final List<int> bytes = response.bodyBytes;
    if (!looksLikeImageBytes(bytes, response.headers['content-type'])) {
      throw ImageDownloadException(
        'response is not an image (content-type: '
        '${response.headers['content-type'] ?? 'unknown'})',
      );
    }
    final Directory dir = tempDir ?? Directory.systemTemp;
    await dir.create(recursive: true);
    final File file = File(
      p.join(dir.path, 'hibiki_scrape_${url.hashCode.toRadixString(16)}.img'),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  } finally {
    if (client == null) httpClient.close();
  }
}

/// 图片判定：Content-Type 以 `image/` 开头，或字节魔数命中常见图片格式。
bool looksLikeImageBytes(List<int> bytes, String? contentType) {
  if (contentType != null &&
      contentType.trim().toLowerCase().startsWith('image/')) {
    return true;
  }
  if (bytes.length < 4) return false;
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
  // PNG: 89 50 4E 47
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true;
  }
  // GIF: "GIF8"
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // WebP: "RIFF" .... "WEBP"
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  return false;
}
