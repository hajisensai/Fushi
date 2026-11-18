/// MangaBaka 公开 API（`https://api.mangabaka.org/v1`）的传输层：搜系列、按 id 取系列、
/// 拉系列图片（沿 `pagination.next` 翻页）。
///
/// - 免 key；UA 由调用方注入（书刮削用 `fushiUserAgent('book-scraper')`），不带任何用户
///   信息。
/// - 限流共用 [MangaBakaRateGates]（与追踪插件同一组计数）。
/// - 429：`Retry-After` ≤ [maxRetryAfter] 时按它等**一次**再发（外部协议要求，不是
///   掩盖症状）；再 429 或要求等更久 → 抛 [MangaBakaRateLimitedException]，本客户端
///   此后直接拒绝（一次运行内停用 MangaBaka，由调用方转 Bangumi 并报出来）。
/// - 数据许可 CC BY-NC-SA 4.0，展示处必须可见署名（i18n `book_scrape_mangabaka_attribution`）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_rate_gates.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// MangaBaka 请求失败（网络 / 非 2xx / 响应形状不对）。
class MangaBakaException implements Exception {
  const MangaBakaException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'MangaBakaException: $message'
      : 'MangaBakaException($statusCode): $message';
}

/// 被限流且不宜再等：本次运行停用 MangaBaka。
class MangaBakaRateLimitedException extends MangaBakaException {
  const MangaBakaRateLimitedException(super.message) : super(statusCode: 429);
}

/// 图片列表每页条数上限（源站不带 `limit` 时默认 24）。
const int kMangaBakaImagesPageLimit = 50;

/// 图片列表最多翻几页（ONE PIECE 的 ja 卷封面 115 张 = 3 页，10 页足够任何系列）。
const int kMangaBakaMaxImagePages = 10;

/// MangaBaka API 客户端。注入 [client] 时不负责关闭它。
class MangaBakaClient {
  MangaBakaClient({
    http.Client? client,
    required this.userAgent,
    MangaBakaRateGates? gates,
    this.baseUrl = 'https://$kMangaBakaApiHost/v1',
    this.timeout = const Duration(seconds: 15),
    this.maxRetryAfter = const Duration(seconds: 60),
    Future<void> Function(Duration delay)? wait,
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _gates = gates ?? MangaBakaRateGates.shared,
       _wait = wait ?? ((Duration d) => Future<void>.delayed(d));

  final http.Client _client;
  final bool _ownsClient;
  final MangaBakaRateGates _gates;
  final Future<void> Function(Duration delay) _wait;

  final String userAgent;
  final String baseUrl;

  /// 单次请求超时。
  final Duration timeout;

  /// `Retry-After` 超过它就不等，直接停用（不让界面卡住）。
  final Duration maxRetryAfter;

  bool _rateLimited = false;

  /// 本客户端是否已因限流停用。
  bool get isRateLimited => _rateLimited;

  /// 按 [query] 搜系列（最多 [limit] 条，源站上限 50）。
  Future<List<MangaBakaSeries>> searchSeries(
    String query, {
    int limit = 10,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) return const <MangaBakaSeries>[];
    final Uri uri = Uri.parse('$baseUrl/series/search').replace(
      queryParameters: <String, String>{
        'q': q,
        'limit': '${limit.clamp(1, 50)}',
      },
    );
    final String body = (await _get(uri, search: true))!;
    return _parse(() => parseMangaBakaSearch(body).items);
  }

  /// 按 id 取系列；404 → null。`merged` 的系列不在这里跟随（调用方据
  /// [MangaBakaSeries.mergedWith] 再取一次）。
  Future<MangaBakaSeries?> fetchSeries(int id) async {
    final String? body = await _get(
      Uri.parse('$baseUrl/series/$id'),
      search: false,
      allowNotFound: true,
    );
    if (body == null) return null;
    return _parse(() => parseMangaBakaSeries(body));
  }

  /// 拉系列 [seriesId] 的图片，按 [type]（`volume` / `banner` …）与可选 [language]
  /// 过滤；沿 `pagination.next` 翻页，最多 [kMangaBakaMaxImagePages] 页。
  Future<List<MangaBakaImage>> fetchSeriesImages(
    int seriesId, {
    required String type,
    String? language,
  }) async {
    Uri? next = Uri.parse('$baseUrl/series/$seriesId/images').replace(
      queryParameters: <String, String>{
        'type': type,
        'language': ?language,
        'limit': '$kMangaBakaImagesPageLimit',
      },
    );
    final List<MangaBakaImage> out = <MangaBakaImage>[];
    for (int page = 0; next != null && page < kMangaBakaMaxImagePages; page++) {
      final String body = (await _get(next, search: false))!;
      final MangaBakaPage<MangaBakaImage> parsed = _parse(
        () => parseMangaBakaImagesPage(body),
      );
      out.addAll(parsed.items);
      next = _sameHostNext(parsed.next);
    }
    return out;
  }

  /// `pagination.next` 只跟随同一 API host 的地址（源站给的 next 已带全部筛选参数）。
  Uri? _sameHostNext(String? raw) {
    if (raw == null) return null;
    final Uri? uri = Uri.tryParse(raw);
    final Uri base = Uri.parse(baseUrl);
    if (uri == null || uri.host != base.host || uri.scheme != base.scheme) {
      return null;
    }
    return uri;
  }

  T _parse<T>(T Function() body) {
    try {
      return body();
    } on MangaBakaFormatException catch (e) {
      throw MangaBakaException(e.message);
    }
  }

  Future<String?> _get(
    Uri uri, {
    required bool search,
    bool allowNotFound = false,
  }) async {
    if (_rateLimited) {
      throw const MangaBakaRateLimitedException('disabled for this run');
    }
    for (int attempt = 0; ; attempt++) {
      await (search ? _gates.search : _gates.other).reserve();
      final http.Response response;
      try {
        response = await _client
            .get(
              uri,
              headers: <String, String>{
                'User-Agent': userAgent,
                'Accept': 'application/json',
              },
            )
            .timeout(timeout);
      } on TimeoutException {
        throw const MangaBakaException('request timed out');
      } catch (e) {
        throw MangaBakaException('request failed: $e');
      }
      if (response.statusCode == 429) {
        final Duration? retryAfter = parseRetryAfter(
          response.headers['retry-after'],
        );
        if (attempt == 0 && retryAfter != null && retryAfter <= maxRetryAfter) {
          await _wait(retryAfter);
          continue;
        }
        _rateLimited = true;
        throw const MangaBakaRateLimitedException('rate limited (HTTP 429)');
      }
      if (response.statusCode == 404 && allowNotFound) return null;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MangaBakaException(
          'HTTP ${response.statusCode} for ${uri.path}',
          statusCode: response.statusCode,
        );
      }
      return utf8.decode(response.bodyBytes);
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// `Retry-After` 头（秒数形式）；HTTP 日期形式与非法值返回 null（按「不宜再等」处理）。
Duration? parseRetryAfter(String? raw) {
  final int? seconds = int.tryParse(raw?.trim() ?? '');
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds);
}
