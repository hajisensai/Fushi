/// 海报下载器 —— 把匹配所得海报 URL 落地为视频封面文件，返回可直接 `updateCover` 的路径。
///
/// 复用既有封面约定：
///   - 文件名走 [videoCoverFileName]（`<sanitize(bookUid)>.jpg`，由 bookUid 1:1 派生，
///     与 DB `coverPath` 对应；从 `video_import_dialog.dart` re-export，见其定义）。
///   - 目录走 [VideoStorage.coversDir]（`<documents>/video_covers`）。
/// 因此本下载器落地的封面与导入抽帧 / 用户手动设置的封面**同目录同命名**，落库后书架
/// 显示逻辑零改动。1 uid 1 文件名：替换前旧封面存在也直接覆盖（现有约定）。
///
/// 代理：`package:http` 默认走 `dart:io` `HttpClient`，尊重进程环境系统代理设置；
/// 部分海报站（如 TMDB `image.tmdb.org`）在部分地区需代理，由外层环境配置后自动继承。
library;

import 'dart:async';
import 'dart:io';

import 'package:hibiki/src/media/media_cover_service.dart';
import 'package:hibiki/src/media/metadata/credential_redaction.dart';
import 'package:hibiki/src/media/metadata/image_download.dart'
    show
        CoverDownloadDeadline,
        fetchCoverImageResponse,
        kCoverImageDownloadTimeout;
import 'package:hibiki/src/media/metadata/transport_retry.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show videoCoverFileName;
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 海报下载器。构造注入 [http.Client]（默认自建），测试用 mock client。
class CoverDownloader {
  CoverDownloader({
    http.Client? client,
    this.timeout = kCoverImageDownloadTimeout,
    this.maxAttempts = kTransportMaxAttempts,
    Future<void> Function(Duration delay)? retrySleep,
  })  : _client = client ?? http.Client(),
        _retrySleep = retrySleep;

  final http.Client _client;

  /// **整轮**下载的总预算（所有尝试与退避共享这一个截止，TODO-2341）。比搜索宽：
  /// 海报是几百 KB ~ 数 MB 的响应体，慢速链路上传输本身就要时间，不能像搜索那样按
  /// 「建连成败」取值；与书籍侧共用 [kCoverImageDownloadTimeout]（100 秒，BUG-1248）。
  ///
  /// 不是「每次尝试各 100 秒」：那样 3 次重试最坏堆成 300 秒，界面上与卡死无法区分。
  final Duration timeout;

  /// 传输失败时的总尝试次数（含首次）。与搜索同一根因：链路会成片丢连接（BUG-1272）。
  /// 图片下载是幂等 GET，重放安全。次数与 [timeout] 是**与**的关系：先到者停手，
  /// 因此链路特别慢时次数可能用不满（已知取舍）。
  final int maxAttempts;

  final Future<void> Function(Duration delay)? _retrySleep;

  /// 下载 [url] 指向的海报，落地为 [bookUid] 对应封面，返回**绝对路径**（可直接
  /// 传给 `updateCover`）。
  ///
  /// - [coversDirectory]：缺省取 [VideoStorage.coversDir]（生产路径）；测试注入临时目录。
  /// - 校验：HTTP 2xx + 图片内容（`Content-Type` 以 `image/` 开头，或字节魔数是
  ///   JPEG/PNG/WebP）。非图片（如 `text/html` 错误页）→ 抛 [ScrapeNetworkException]。
  /// - 落盘走统一收口 [MediaCoverService.applyCoverBytes]：原子 `.tmp`+rename
  ///   （失败**不动旧封面**、不留 .tmp）+ 双键驱逐旧解码缓存（BUG-1118 不变量）。
  Future<String> downloadCover({
    required String url,
    required String bookUid,
    Directory? coversDirectory,
  }) async {
    final Directory coversDir =
        coversDirectory ?? await VideoStorage.coversDir();
    return downloadImageFile(
      url: url,
      fileName: videoCoverFileName(bookUid),
      directory: coversDir,
    );
  }

  /// 下载 [url] 落地为 [directory]/[fileName]，返回绝对路径（v68 附加图组用：
  /// backdrop/logo/titleCard 的文件名不是 bookUid 1:1 派生，须显式给名）。
  ///
  /// 与 [downloadCover] 同一套截止/重试/魔数校验/原子落盘——那是收口，不是两份。
  Future<String> downloadImageFile({
    required String url,
    required String fileName,
    required Directory directory,
  }) async {
    await directory.create(recursive: true);
    final String finalPath = p.join(directory.path, fileName);

    // 整轮下载（含全部重试与退避）只有这一个截止：所有尝试共用同一个 abort trigger，
    // 到点时**在飞的那一次传输也被真正中止**（BUG-1248 的核心性质），并置位
    // isExpired 让重试循环停手（TODO-2341）。
    final CoverDownloadDeadline deadline = CoverDownloadDeadline(timeout);
    final http.Response response;
    try {
      // 只有传输失败（拿不到响应）会重试；下面对非 2xx 的判断在 try 之外，因此
      // 404 / 403 的坏 URL 依旧一次就失败，不会被重放。每次尝试都走
      // [fetchCoverImageResponse]：截止即 abort 底层请求/响应流，重放不会在后台
      // 堆积仍在下载的孤儿连接（BUG-1248）。
      response = await runWithTransportRetry<http.Response>(
        () => fetchCoverImageResponse(
          _client,
          Uri.parse(url),
          deadline: deadline,
        ),
        maxAttempts: maxAttempts,
        sleep: _retrySleep,
        shouldGiveUp: () => deadline.isExpired,
      );
    } on TimeoutException {
      throw const ScrapeNetworkException('Poster download timed out');
    } catch (e) {
      // package:http 的 ClientException 会把完整请求 URL 拼进 toString()；候选
      // 海报 URL 可能带签名/token，必须在异常构造侧先脱敏，保证日志/界面/复制同源安全。
      throw ScrapeNetworkException(
        redactCredentialsInText('Poster request failed: $e'),
      );
    } finally {
      deadline.dispose();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        'Poster download HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final List<int> bytes = response.bodyBytes;
    final String? contentType = response.headers['content-type'];
    if (!_looksLikeImage(bytes, contentType)) {
      throw ScrapeNetworkException(
        'Poster response is not an image (content-type: '
        '${contentType ?? 'unknown'})',
      );
    }

    // 统一收口：原子落地（.tmp+rename，失败不动旧封面）+ 双键驱逐（BUG-1118）。
    try {
      await MediaCoverService.applyCoverBytes(
          bytes: bytes, destPath: finalPath);
    } catch (e) {
      throw ScrapeNetworkException(
        redactCredentialsInText('Cover write failed: $e'),
      );
    }

    return finalPath;
  }

  /// 关闭内部 client（若为默认自建）。
  void close() => _client.close();

  /// 判断响应是否为图片：`Content-Type` 以 `image/` 开头，或字节魔数命中
  /// JPEG / PNG / WebP。两者任一成立即认为是图片。
  static bool _looksLikeImage(List<int> bytes, String? contentType) {
    if (contentType != null &&
        contentType.trim().toLowerCase().startsWith('image/')) {
      return true;
    }
    return _hasImageMagic(bytes);
  }

  /// 字节魔数嗅探：JPEG(FF D8 FF) / PNG(89 50 4E 47) / WebP(RIFF....WEBP)。
  static bool _hasImageMagic(List<int> bytes) {
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
}
