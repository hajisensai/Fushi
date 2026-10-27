import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi_engine/media/video/media_server/media_server_client_identity.dart';

/// 「添加服务器 / 添加线路」一次尝试的请求轨迹（AL8qJr6yr-）：每发一条请求记
/// `方法 路径 → 状态码 [content-type] [server]`，失败时整段写进错误日志
/// （`ErrorLogService.log`，落盘并随反馈日志上传）。
///
/// 此前添加失败只在对话框里给一句「无法连接 / 404」，日志里什么都没有：探测走了
/// 哪几条端点、根地址与 `/emby` 前缀各回了什么、登录请求本身回了什么，下一次反馈
/// 照样无从定位。
///
/// **不记任何凭据**：只记路径（不带主机、不带查询串——`api_key` 在查询串里）、
/// 状态码与两个响应头；请求体（密码）与响应体（令牌）一概不碰。
class JellyfinConnectTrace {
  final List<String> _lines = <String>[];

  /// 已记录的轨迹行（按发出顺序）。
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 包一层记录轨迹的 client（转发给 [inner]，关闭时一起关）。
  http.Client wrap(http.Client inner) => _TracingClient(inner, _lines);

  /// 诊断日志正文：本机身份 + 地址形态 + 每条请求 + 最终错误。
  String describe({
    required String stage,
    required String typedUrl,
    required Object error,
  }) {
    final Uri? uri = Uri.tryParse(typedUrl);
    final String shape = uri == null
        ? '(unparsable)'
        : '${uri.scheme}://<host>${uri.hasPort ? ':${uri.port}' : ''}'
              '${uri.path}';
    final MediaServerClientIdentity id = mediaServerClientIdentity;
    return <String>[
      '$stage failed for $shape',
      'client: Client="${id.product}" Device="${id.deviceName}" '
          'Version="${id.version}"',
      'requests (${_lines.length}):',
      for (final String line in _lines) '  $line',
      'error: ${_withoutHost(redactCredentialsInText(error.toString()), uri)}',
    ].join('\n');
  }
}

/// 异常文本（如 [JellyfinConnectFailure] 的「无法连接 <地址>」）里的主机名换成
/// `<host>`：轨迹只要路径形态，用户的服务器地址不进日志。
String _withoutHost(String text, Uri? uri) {
  final String host = uri?.host ?? '';
  return host.isEmpty ? text : text.replaceAll(host, '<host>');
}

class _TracingClient extends http.BaseClient {
  _TracingClient(this._inner, this._lines);

  final http.Client _inner;
  final List<String> _lines;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String what = '${request.method} ${request.url.path}';
    // 先占位：调用方的超时（`.timeout`）在本层之上触发，届时这条请求还没回，
    // 轨迹里要看得出「发了、没等到回应」。
    final int slot = _lines.length;
    _lines.add('$what → (no response)');
    try {
      final http.StreamedResponse response = await _inner.send(request);
      final String? type = response.headers['content-type'];
      final String? server = response.headers['server'];
      _lines[slot] =
          '$what → ${response.statusCode}'
          '${type == null ? '' : ' [$type]'}'
          '${server == null ? '' : ' [server: $server]'}';
      return response;
    } on Object catch (error) {
      _lines[slot] = '$what → ${error.runtimeType}';
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
