/// 视频元数据来源共用的只读 HTTP 传输层。
///
/// 除传输异常外，也按服务端提示处理 429，并对 5xx 做有界退避。响应只在内存中按
/// 请求键缓存；缓存保存原始 UTF-8 文本，调用方每次拿到的 JSON 对象都是重新解码的，
/// 不会因为某个 provider 修改集合而污染后续调用。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class VideoMetadataNetworkException implements Exception {
  const VideoMetadataNetworkException(
    this.message, {
    this.statusCode,
    this.retryAfter,
  });

  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() {
    final int? code = statusCode;
    return code == null
        ? 'VideoMetadataNetworkException: $message'
        : 'VideoMetadataNetworkException($code): $message';
  }
}

class VideoMetadataHttpResponse {
  const VideoMetadataHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  Object? decodeJson({required String operation}) {
    try {
      return jsonDecode(body);
    } catch (error) {
      throw VideoMetadataNetworkException(
        '$operation returned invalid JSON: $error',
        statusCode: statusCode,
      );
    }
  }

  Map<String, Object?> decodeJsonObject({required String operation}) {
    final Object? decoded = decodeJson(operation: operation);
    if (decoded is! Map<String, Object?>) {
      throw VideoMetadataNetworkException(
        '$operation response is not a JSON object',
        statusCode: statusCode,
      );
    }
    return decoded;
  }
}

typedef VideoMetadataRetrySleep = Future<void> Function(Duration duration);
typedef VideoMetadataNow = DateTime Function();

class VideoMetadataHttpClient {
  VideoMetadataHttpClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 400),
    this.maxRetryDelay = const Duration(seconds: 30),
    this.defaultCacheTtl = const Duration(minutes: 30),
    VideoMetadataRetrySleep? sleep,
    VideoMetadataNow? now,
  })  : assert(maxAttempts > 0),
        _client = client ?? http.Client(),
        _ownsClient = client == null,
        _sleep = sleep ?? Future<void>.delayed,
        _now = now ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxRetryDelay;
  final Duration defaultCacheTtl;
  final VideoMetadataRetrySleep _sleep;
  final VideoMetadataNow _now;
  final Map<String, _CachedResponse> _cache = <String, _CachedResponse>{};

  Future<VideoMetadataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    required String operation,
    String? cacheKey,
    Duration? cacheTtl,
  }) {
    return send(
      () => _client.get(uri, headers: headers).timeout(timeout),
      operation: operation,
      cacheKey: cacheKey,
      cacheTtl: cacheTtl,
    );
  }

  Future<VideoMetadataHttpResponse> postJson(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    required Object? body,
    required String operation,
    String? cacheKey,
    Duration? cacheTtl,
  }) {
    return send(
      () => _client
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              ...headers,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout),
      operation: operation,
      cacheKey: cacheKey,
      cacheTtl: cacheTtl,
    );
  }

  Future<VideoMetadataHttpResponse> send(
    Future<http.Response> Function() request, {
    required String operation,
    String? cacheKey,
    Duration? cacheTtl,
  }) async {
    final String? effectiveCacheKey = cacheKey?.trim();
    if (effectiveCacheKey != null && effectiveCacheKey.isNotEmpty) {
      final _CachedResponse? cached = _cache[effectiveCacheKey];
      if (cached != null && cached.expiresAt.isAfter(_now())) {
        return cached.response;
      }
      _cache.remove(effectiveCacheKey);
    }

    Object? lastError;
    StackTrace? lastStack;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final http.Response response = await request();
        final Duration? retryAfter = parseRetryAfter(
          response.headers['retry-after'],
          now: _now(),
        );
        final bool retryableStatus =
            response.statusCode == 429 || response.statusCode >= 500;
        if (retryableStatus && attempt < maxAttempts) {
          await _sleep(_boundedRetryDelay(
            retryAfter ?? baseBackoff * attempt,
            maxRetryDelay,
          ));
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw VideoMetadataNetworkException(
            '$operation HTTP ${response.statusCode}',
            statusCode: response.statusCode,
            retryAfter: retryAfter,
          );
        }
        final VideoMetadataHttpResponse result = VideoMetadataHttpResponse(
          statusCode: response.statusCode,
          body: utf8.decode(response.bodyBytes),
          headers: response.headers,
        );
        if (effectiveCacheKey != null && effectiveCacheKey.isNotEmpty) {
          _cache[effectiveCacheKey] = _CachedResponse(
            response: result,
            expiresAt: _now().add(cacheTtl ?? defaultCacheTtl),
          );
        }
        return result;
      } on VideoMetadataNetworkException catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (attempt >= maxAttempts ||
            (error.statusCode != null &&
                error.statusCode != 429 &&
                error.statusCode! < 500)) {
          Error.throwWithStackTrace(error, stack);
        }
        await _sleep(_boundedRetryDelay(
          error.retryAfter ?? baseBackoff * attempt,
          maxRetryDelay,
        ));
      } on TimeoutException catch (error, stack) {
        lastError = VideoMetadataNetworkException('$operation timed out');
        lastStack = stack;
        if (attempt >= maxAttempts) break;
        await _sleep(_boundedRetryDelay(
          baseBackoff * attempt,
          maxRetryDelay,
        ));
      } catch (error, stack) {
        lastError = VideoMetadataNetworkException(
          '$operation request failed: ${error.runtimeType}',
        );
        lastStack = stack;
        if (attempt >= maxAttempts) break;
        await _sleep(_boundedRetryDelay(
          baseBackoff * attempt,
          maxRetryDelay,
        ));
      }
    }

    final Object error = lastError ??
        VideoMetadataNetworkException('$operation failed without a response');
    Error.throwWithStackTrace(error, lastStack ?? StackTrace.current);
  }

  void invalidateCache([String? key]) {
    if (key == null) {
      _cache.clear();
    } else {
      _cache.remove(key);
    }
  }

  void close() {
    _cache.clear();
    if (_ownsClient) _client.close();
  }
}

Duration _boundedRetryDelay(Duration requested, Duration maximum) {
  if (requested.isNegative) return Duration.zero;
  return requested > maximum ? maximum : requested;
}

Duration? parseRetryAfter(String? value, {required DateTime now}) {
  final String trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final int? seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return Duration(seconds: seconds < 0 ? 0 : seconds);
  }
  final DateTime? date = DateTime.tryParse(trimmed) ?? _parseHttpDate(trimmed);
  if (date == null) return null;
  final Duration difference = date.toUtc().difference(now.toUtc());
  return difference.isNegative ? Duration.zero : difference;
}

DateTime? _parseHttpDate(String value) {
  final RegExpMatch? match = RegExp(
    r'^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(\d{1,2})\s+'
    r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+'
    r'(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  ).firstMatch(value);
  if (match == null) return null;
  const Map<String, int> months = <String, int>{
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final int? month = months[match.group(2)];
  if (month == null) return null;
  try {
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  } on FormatException {
    return null;
  }
}

class _CachedResponse {
  const _CachedResponse({required this.response, required this.expiresAt});

  final VideoMetadataHttpResponse response;
  final DateTime expiresAt;
}
