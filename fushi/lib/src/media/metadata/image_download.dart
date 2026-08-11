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
import 'package:fushi/src/utils/net/app_http.dart';

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

/// 远端封面原图下载的统一**总预算**（含其全部传输重试）。
///
/// 原图通常比候选列表缩略图大，弱网或代理链路下 30 秒容易在响应完成前误杀；
/// 100 秒仍是有界等待，同时给高分辨率封面留出足够传输时间。
///
/// 注意语义：这是**整轮下载**的截止，不是「每次尝试」的截止。见
/// [CoverDownloadDeadline]。
const Duration kCoverImageDownloadTimeout = Duration(seconds: 100);

/// 一次封面下载（**含其全部传输重试**）共享的唯一截止。
///
/// 旧口径是「每次尝试各自计时」：传输重试最多 3 次（BUG-1272）× 单次 100 秒
/// （BUG-1248）= 最坏 300 秒转圈，界面上与卡死无法区分（TODO-2341）。现在整轮下载
/// 只有这一个截止，重试**分享**同一份预算：
///
/// - 到点由唯一的 [Timer] 触发唯一的 [abortTrigger]，在飞的请求 / 响应流被 package:http
///   的 [http.AbortableRequest] **真正中止**——这是 BUG-1248 的核心性质：只让等待层
///   放弃而底层继续传，孤儿连接会越堆越多，绝不能退化；
/// - 同时把 [isExpired] 置位，重试循环据此停手，不再发起新的尝试（预算用尽即整体失败）。
///
/// 已知并接受的代价：链路特别慢时重试次数用不满。
///
/// 用完必须 [dispose] 取消定时器（成功路径同样要，否则空跑一个 100 秒的 Timer）。
final class CoverDownloadDeadline {
  CoverDownloadDeadline(this.budget) {
    // 预算可能在两次尝试之间（退避期）耗尽，此时没有任何等待方；先挂一个吞错
    // handler，免得 [expiration] 变成未处理的异步异常。等待方会另行挂自己的。
    _expiration.future.ignore();
    _timer = Timer(budget, _expire);
  }

  /// 整轮下载（含全部重试与退避）的总预算。
  final Duration budget;

  final Completer<void> _abort = Completer<void>();
  final Completer<Never> _expiration = Completer<Never>();
  late final Timer _timer;
  bool _expired = false;

  /// 交给每次尝试的 [http.Abortable.abortTrigger]：**所有尝试共用同一个**，
  /// 因此到点时正在传输的那一次会被真正 abort。
  Future<void> get abortTrigger => _abort.future;

  /// 到点抛 [TimeoutException] 的 Future，永不正常完成。
  ///
  /// 必须与 [abortTrigger] 分开：abort 会让底层传输以 `RequestAbortedException`
  /// 结束，若只靠它，等待方拿到的究竟是「超时」还是「连接被中止」就取决于微任务
  /// 顺序。[_expire] 保证先完成本 Future 再触发 abort，超时语义因此是确定的。
  Future<Never> get expiration => _expiration.future;

  /// 预算是否已耗尽。重试循环据此停手。
  bool get isExpired => _expired;

  void _expire() {
    _expired = true;
    // 顺序即契约：先让等待方拿到 TimeoutException，再中止底层传输。
    if (!_expiration.isCompleted) {
      _expiration.completeError(
        TimeoutException('cover image download timed out', budget),
        StackTrace.current,
      );
    }
    if (!_abort.isCompleted) _abort.complete();
  }

  /// 取消截止定时器。到点后再调用无副作用（已到点的事实不回滚）。
  void dispose() => _timer.cancel();
}

/// 发送一次受 [deadline] 约束、可在截止时取消底层传输的封面 GET 请求。
///
/// 单独给 Future 加 `timeout` 只会停止等待，源 HTTP 请求和响应流仍可能继续。本 helper
/// 改用 package:http 的 [http.AbortableRequest]，abort trigger 直接取自共享的
/// [deadline]：到点即 abort 底层传输，同时向调用方抛 [TimeoutException]。默认 IOClient
/// 会据此中止未完成请求或取消正在读取的响应流；client 本身不关闭，因此视频侧的复用
/// client 及调用方注入 client 的所有权不变。
Future<http.Response> fetchCoverImageResponse(
  http.Client client,
  Uri url, {
  required CoverDownloadDeadline deadline,
}) {
  final http.AbortableRequest request = http.AbortableRequest(
    'GET',
    url,
    abortTrigger: deadline.abortTrigger,
  );
  final Future<http.Response> response =
      client.send(request).then(http.Response.fromStream);
  // Future.any：谁先完成谁说了算，后到的错误被静默丢弃（不会变成未处理异常）。
  // 截止分支只负责「告诉等待层超时」，abort 本身由共享 trigger 负责；两者的先后
  // 由 [CoverDownloadDeadline._expire] 固定，因此超时语义不受微任务顺序影响。
  return Future.any(<Future<http.Response>>[response, deadline.expiration]);
}

/// 下载 [url] 指向的图片到临时文件，返回该文件。
///
/// - [client]：默认自建（下载完关闭）；测试注入 mock client（不关闭，由调用方管理）。
/// - [tempDir]：缺省 [Directory.systemTemp]；测试注入临时目录。
/// - 校验：HTTP 2xx + 图片内容（Content-Type 以 `image/` 开头，或字节魔数是
///   JPEG/PNG/WebP/GIF）。非图片 → 抛 [ImageDownloadException]。
/// - 文件名按 URL 派生（同 URL 复下覆盖同一临时文件，不堆垃圾）。
/// - [timeout]：整轮下载的总预算（本函数不重试，因此就是这一次尝试的截止）。
Future<File> downloadImageToTempFile(
  String url, {
  http.Client? client,
  Directory? tempDir,
  Duration timeout = kCoverImageDownloadTimeout,
}) async {
  final http.Client httpClient = client ?? createAppHttpIoClient();
  final CoverDownloadDeadline deadline = CoverDownloadDeadline(timeout);
  try {
    final http.Response response;
    try {
      response = await fetchCoverImageResponse(
        httpClient,
        Uri.parse(url),
        deadline: deadline,
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
    deadline.dispose();
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
