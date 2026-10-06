import 'dart:convert';
import 'dart:io';

import 'ctl_endpoint.dart';
import 'ctl_protocol.dart';

/// 控制通道请求失败。[code] 取服务端的 `error` 字段；连不上时为 [kCtlErrorUnreachable]。
class CtlException implements Exception {
  const CtlException(this.code, {this.statusCode, this.message});

  final String code;
  final int? statusCode;
  final String? message;

  bool get isNotReady => code == kCtlErrorNotReady;
  bool get isUnreachable => code == kCtlErrorUnreachable;

  @override
  String toString() =>
      'CtlException($code${statusCode == null ? '' : ', HTTP $statusCode'}'
      '${message == null ? '' : ': $message'})';
}

/// 端口没人听 / 连接被拒：发现文件是上一次运行残留的，或 app 正在退出。
const String kCtlErrorUnreachable = 'unreachable';

/// 控制通道客户端（CLI 侧）。
class CtlClient {
  CtlClient(this.endpoint, {HttpClient? httpClient})
    : _http =
          httpClient ??
          (HttpClient()
            ..connectionTimeout = const Duration(seconds: 3)
            // 控制通道只在 127.0.0.1：永远直连。默认的 findProxy 读
            // HTTP_PROXY / HTTPS_PROXY，用户开着全局代理又没配 NO_PROXY 时，
            // 请求（连同 Bearer token）会被送进代理，回来的是代理的 502。
            ..findProxy = (Uri _) => 'DIRECT'),
      _ownsHttp = httpClient == null;

  final CtlEndpoint endpoint;
  final HttpClient _http;
  final bool _ownsHttp;

  Future<CtlAppStatus> status() async =>
      CtlAppStatus.fromJson(await _send('GET', kCtlStatusPath));

  /// 返回 app 认定的目标种类。
  Future<CtlOpenKind?> open(String target) async {
    final Map<String, Object?> body = await _send(
      'POST',
      kCtlOpenPath,
      body: <String, Object?>{'target': target},
    );
    return CtlOpenKind.fromWire(body['kind'] as String?);
  }

  Future<void> lookup(String word) async {
    await _send('POST', kCtlLookupPath, body: <String, Object?>{'word': word});
  }

  Future<void> quit() async {
    await _send('POST', kCtlQuitPath);
  }

  /// 通用调用：按域注册的路由都走这里。返回解码后的 JSON（可能是 Map / List）。
  Future<Object?> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) => _sendAny(method, path, query: query, body: body);

  void close() {
    if (_ownsHttp) _http.close(force: true);
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final Object? decoded = await _sendAny(method, path, body: body);
    return decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
  }

  Future<Object?> _sendAny(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final Uri uri = endpoint.baseUri.replace(
      path: path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
    final HttpClientResponse response;
    try {
      final HttpClientRequest request = await _http.openUrl(method, uri);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${endpoint.token}',
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      response = await request.close();
    } on SocketException catch (error) {
      throw CtlException(kCtlErrorUnreachable, message: error.message);
    } on HttpException catch (error) {
      throw CtlException(kCtlErrorUnreachable, message: error.message);
    }
    final String text = await utf8.decodeStream(response);
    Object? json;
    if (text.isNotEmpty) {
      try {
        json = jsonDecode(text);
      } on FormatException {
        // 不是本通道的应答（端口被别的程序复用）：按协议错误报。
        throw CtlException(
          'protocol',
          statusCode: response.statusCode,
          message: text,
        );
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    final Map<String, Object?> error = json is Map<String, Object?>
        ? json
        : const <String, Object?>{};
    throw CtlException(
      error['error'] as String? ?? 'http_${response.statusCode}',
      statusCode: response.statusCode,
      message: error['message'] as String?,
    );
  }
}
