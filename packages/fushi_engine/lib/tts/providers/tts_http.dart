/// 各 HTTP 引擎共用的请求 / 落盘 / 错误归一。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:fushi_engine/tts/tts_types.dart';

/// 单次响应体上限（合成音频、声音列表 JSON 同一道）：句级音频与声音列表都不会
/// 接近它，超了说明端点不对。地址是用户自填的，不设上限一个错的端点就能把内存撑爆。
const int kTtsMaxResponseBytes = 64 * 1024 * 1024;

/// 读完一个 2xx 响应体并解析成 JSON。按**原始字节**计 [maxBytes]，超了立刻抛
/// `too large`（不先整块读进内存再判断）；[timeout] 是相邻两块数据之间的时限。
Future<Object?> _readJsonBody(
  HttpClientResponse response, {
  required Duration timeout,
  required int maxBytes,
}) async {
  final BytesBuilder bytes = BytesBuilder(copy: false);
  await for (final List<int> chunk in response.timeout(timeout)) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const TtsFailure(TtsFailureCode.badResponse, 'too large');
    }
    bytes.add(chunk);
  }
  return jsonDecode(utf8.decode(bytes.takeBytes()));
}

/// 单次合成整体时限（自建 GPU 服务长句可能要几十秒）。
const Duration kTtsRequestTimeout = Duration(minutes: 3);

/// HTTP `Retry-After`：秒数或 HTTP 日期。解析不了返回 null（按默认退避）。
Duration? ttsParseRetryAfter(String? raw, {DateTime? now}) {
  if (raw == null) return null;
  final String value = raw.trim();
  if (value.isEmpty) return null;
  final int? seconds = int.tryParse(value);
  if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
  try {
    final Duration d = HttpDate.parse(
      value,
    ).difference((now ?? DateTime.now()).toUtc());
    return d.isNegative ? Duration.zero : d;
  } on HttpException {
    return null;
  } on FormatException {
    return null;
  }
}

/// 非 2xx 状态 → 稳定错误码。[retryAfter] 只对 429 / 5xx 有意义（重试层据此等待）。
TtsFailure ttsFailureForStatus(int status, {Duration? retryAfter}) =>
    switch (status) {
      401 || 403 => TtsFailure(TtsFailureCode.unauthorized, 'HTTP $status'),
      429 => TtsFailure.withRetry(
        TtsFailureCode.rateLimited,
        detail: 'HTTP $status',
        retryAfter: retryAfter,
      ),
      >= 500 => TtsFailure.withRetry(
        TtsFailureCode.serverError,
        detail: 'HTTP $status',
        retryAfter: retryAfter,
      ),
      409 => TtsFailure(TtsFailureCode.busy, 'HTTP $status'),
      400 || 404 || 422 => TtsFailure(TtsFailureCode.rejected, 'HTTP $status'),
      _ => TtsFailure(TtsFailureCode.badResponse, 'HTTP $status'),
    };

/// 发一个请求，把 2xx 响应体写进 [outputPath]；非 2xx 抛 [TtsFailure]（不读正文）。
/// 返回写入的字节数。
Future<int> ttsSendToFile({
  required HttpClient client,
  required String method,
  required Uri uri,
  required String outputPath,
  required TtsCancelToken cancel,
  Map<String, String> headers = const <String, String>{},
  List<int>? body,
}) async {
  cancel.throwIfCancelled();
  HttpClientRequest? request;
  final void Function() unregister = cancel.onCancel(() {
    request?.abort(const TtsFailure(TtsFailureCode.cancelled));
  });
  try {
    final HttpClientRequest req = await client.openUrl(method, uri);
    request = req;
    cancel.throwIfCancelled();
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final HttpClientResponse response = await req.close().timeout(
      kTtsRequestTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((Object _) {});
      throw ttsFailureForStatus(
        response.statusCode,
        retryAfter: ttsParseRetryAfter(
          response.headers.value(HttpHeaders.retryAfterHeader),
        ),
      );
    }
    final IOSink sink = File(outputPath).openWrite();
    int written = 0;
    try {
      await for (final List<int> chunk in response.timeout(
        kTtsRequestTimeout,
      )) {
        written += chunk.length;
        if (written > kTtsMaxResponseBytes) {
          throw const TtsFailure(TtsFailureCode.badResponse, 'too large');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    cancel.throwIfCancelled();
    if (written == 0) {
      // 200 却没有音频：在线服务偶发（限流前兆 / 后端抖动），按临时失败交给重试层。
      throw const TtsFailure.withRetry(
        TtsFailureCode.badResponse,
        detail: 'empty',
        transient: true,
      );
    }
    return written;
  } on TtsFailure {
    rethrow;
  } on TimeoutException {
    throw const TtsFailure(TtsFailureCode.timeout);
  } on SocketException {
    throw const TtsFailure(TtsFailureCode.network);
  } on HttpException {
    if (cancel.isCancelled) throw const TtsFailure(TtsFailureCode.cancelled);
    throw const TtsFailure(TtsFailureCode.network);
  } on HandshakeException {
    throw const TtsFailure(TtsFailureCode.network, 'tls');
  } finally {
    unregister();
  }
}

/// GET 一个 JSON（声音列表之类）。响应体与 [ttsPostJson] 同一道上限
/// （[maxResponseBytes]，默认 [kTtsMaxResponseBytes]）。
Future<Object?> ttsGetJson({
  required HttpClient client,
  required Uri uri,
  Map<String, String> headers = const <String, String>{},
  TtsCancelToken? cancel,
  int maxResponseBytes = kTtsMaxResponseBytes,
}) async {
  final TtsCancelToken token = cancel ?? TtsCancelToken();
  try {
    final HttpClientRequest req = await client.getUrl(uri);
    headers.forEach(req.headers.set);
    final HttpClientResponse response = await req.close().timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((Object _) {});
      throw ttsFailureForStatus(
        response.statusCode,
        retryAfter: ttsParseRetryAfter(
          response.headers.value(HttpHeaders.retryAfterHeader),
        ),
      );
    }
    token.throwIfCancelled();
    return await _readJsonBody(
      response,
      timeout: const Duration(seconds: 30),
      maxBytes: maxResponseBytes,
    );
  } on TtsFailure {
    rethrow;
  } on FormatException {
    throw const TtsFailure(TtsFailureCode.badResponse, 'json');
  } on TimeoutException {
    throw const TtsFailure(TtsFailureCode.timeout);
  } on SocketException {
    throw const TtsFailure(TtsFailureCode.network);
  } on HttpException {
    throw const TtsFailure(TtsFailureCode.network);
  } on HandshakeException {
    throw const TtsFailure(TtsFailureCode.network, 'tls');
  }
}

/// POST 一个 JSON 并解析 JSON 响应（Google 这类把音频 base64 包在 JSON 里的引擎）。
/// [sendBody] 为 false 时发空请求体（参数全在 query 里的接口，如 VOICEVOX
/// `/audio_query`），[body] 被忽略。
Future<Object?> ttsPostJson({
  required HttpClient client,
  required Uri uri,
  required Object? body,
  required TtsCancelToken cancel,
  Map<String, String> headers = const <String, String>{},
  int maxResponseBytes = kTtsMaxResponseBytes,
  bool sendBody = true,
}) async {
  cancel.throwIfCancelled();
  HttpClientRequest? request;
  final void Function() unregister = cancel.onCancel(() {
    request?.abort(const TtsFailure(TtsFailureCode.cancelled));
  });
  try {
    final HttpClientRequest req = await client.postUrl(uri);
    request = req;
    cancel.throwIfCancelled();
    req.followRedirects = false;
    if (sendBody) {
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
    }
    headers.forEach(req.headers.set);
    final List<int> bytes = sendBody
        ? utf8.encode(jsonEncode(body))
        : const <int>[];
    req.contentLength = bytes.length;
    if (bytes.isNotEmpty) req.add(bytes);
    final HttpClientResponse response = await req.close().timeout(
      kTtsRequestTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((Object _) {});
      throw ttsFailureForStatus(
        response.statusCode,
        retryAfter: ttsParseRetryAfter(
          response.headers.value(HttpHeaders.retryAfterHeader),
        ),
      );
    }
    final Object? decoded = await _readJsonBody(
      response,
      timeout: kTtsRequestTimeout,
      maxBytes: maxResponseBytes,
    );
    cancel.throwIfCancelled();
    return decoded;
  } on TtsFailure {
    rethrow;
  } on FormatException {
    throw const TtsFailure(TtsFailureCode.badResponse, 'json');
  } on TimeoutException {
    throw const TtsFailure(TtsFailureCode.timeout);
  } on SocketException {
    throw const TtsFailure(TtsFailureCode.network);
  } on HttpException {
    if (cancel.isCancelled) throw const TtsFailure(TtsFailureCode.cancelled);
    throw const TtsFailure(TtsFailureCode.network);
  } on HandshakeException {
    throw const TtsFailure(TtsFailureCode.network, 'tls');
  } finally {
    unregister();
  }
}

/// SSML 文本转义。
String ttsEscapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
