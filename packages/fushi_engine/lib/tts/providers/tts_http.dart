/// 各 HTTP 引擎共用的请求 / 落盘 / 错误归一。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/tts_types.dart';

/// 单次合成响应体上限：句级音频不会接近它，超了说明端点不对。
const int kTtsMaxResponseBytes = 64 * 1024 * 1024;

/// 单次合成整体时限（自建 GPU 服务长句可能要几十秒）。
const Duration kTtsRequestTimeout = Duration(minutes: 3);

TtsFailure ttsFailureForStatus(int status) => switch (status) {
  401 || 403 => TtsFailure(TtsFailureCode.unauthorized, 'HTTP $status'),
  429 => TtsFailure(TtsFailureCode.rateLimited, 'HTTP $status'),
  >= 500 => TtsFailure(TtsFailureCode.serverError, 'HTTP $status'),
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
      throw ttsFailureForStatus(response.statusCode);
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
      throw const TtsFailure(TtsFailureCode.badResponse, 'empty');
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

/// GET 一个 JSON（声音列表之类）。
Future<Object?> ttsGetJson({
  required HttpClient client,
  required Uri uri,
  Map<String, String> headers = const <String, String>{},
  TtsCancelToken? cancel,
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
      throw ttsFailureForStatus(response.statusCode);
    }
    token.throwIfCancelled();
    final String text = await response.transform(utf8.decoder).join();
    return jsonDecode(text);
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
Future<Object?> ttsPostJson({
  required HttpClient client,
  required Uri uri,
  required Object? body,
  required TtsCancelToken cancel,
  Map<String, String> headers = const <String, String>{},
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
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    headers.forEach(req.headers.set);
    final List<int> bytes = utf8.encode(jsonEncode(body));
    req.contentLength = bytes.length;
    req.add(bytes);
    final HttpClientResponse response = await req.close().timeout(
      kTtsRequestTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((Object _) {});
      throw ttsFailureForStatus(response.statusCode);
    }
    final StringBuffer buffer = StringBuffer();
    int length = 0;
    await for (final String chunk
        in response.timeout(kTtsRequestTimeout).transform(utf8.decoder)) {
      length += chunk.length;
      if (length > kTtsMaxResponseBytes) {
        throw const TtsFailure(TtsFailureCode.badResponse, 'too large');
      }
      buffer.write(chunk);
    }
    cancel.throwIfCancelled();
    return jsonDecode(buffer.toString());
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
