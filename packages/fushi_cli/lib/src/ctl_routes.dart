/// 控制通道的可注册路由：app 侧按域注册 [CtlRoute]，服务端只做匹配、鉴权、
/// 「未就绪回 409」与错误映射，不懂任何 app 语义。
library;

/// 路由处理器主动拒绝请求。服务端把它映射成对应状态码 + `{error, message}`。
class CtlFailure implements Exception {
  const CtlFailure(this.status, this.code, [this.message]);

  /// 400：参数缺失或格式不对。
  const CtlFailure.badRequest(String message)
    : this(400, 'bad_request', message);

  /// 404：要操作的对象不存在（书 / 词典 / 下载任务……）。
  const CtlFailure.notFound(String message) : this(404, 'not_found', message);

  /// 409：状态冲突（已在运行、正在导入……），稍后再试。
  const CtlFailure.conflict(String message) : this(409, 'conflict', message);

  /// 422：app 拒绝（模块关闭、平台不支持、合规限制……）。
  const CtlFailure.rejected(String message) : this(422, 'rejected', message);

  /// 501：本平台 / 本构建没有这项能力。
  const CtlFailure.unsupported(String message)
    : this(501, 'unsupported', message);

  final int status;
  final String code;
  final String? message;

  @override
  String toString() =>
      'CtlFailure($status $code${message == null ? '' : ': $message'})';
}

/// 一次路由调用的输入：路径参数、query、JSON body，带几个取值助手。
class CtlCall {
  const CtlCall({
    required this.method,
    required this.path,
    this.params = const <String, String>{},
    this.query = const <String, String>{},
    this.body = const <String, Object?>{},
  });

  final String method;
  final String path;

  /// 路由模式里 `:name` 段匹配到的值（已 URI 解码）。
  final Map<String, String> params;
  final Map<String, String> query;
  final Map<String, Object?> body;

  /// body 优先、其次 query 的字符串字段；缺失或空白抛 400。
  String requireString(String name) {
    final String? value = optString(name);
    if (value == null) throw CtlFailure.badRequest('$name 缺失');
    return value;
  }

  String? optString(String name) {
    final Object? raw = body[name] ?? query[name];
    if (raw == null) return null;
    final String text = '$raw'.trim();
    return text.isEmpty ? null : text;
  }

  int? optInt(String name) {
    final Object? raw = body[name] ?? query[name];
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    final int? parsed = int.tryParse('$raw'.trim());
    if (parsed == null) throw CtlFailure.badRequest('$name 必须是整数');
    return parsed;
  }

  bool? optBool(String name) {
    final Object? raw = body[name] ?? query[name];
    if (raw == null) return null;
    if (raw is bool) return raw;
    switch ('$raw'.trim().toLowerCase()) {
      case 'true' || '1' || 'yes' || 'on':
        return true;
      case 'false' || '0' || 'no' || 'off':
        return false;
    }
    throw CtlFailure.badRequest('$name 必须是布尔值');
  }

  /// body 里的字符串数组（也接受单个字符串）。
  List<String> stringList(String name) {
    final Object? raw = body[name] ?? query[name];
    if (raw == null) return const <String>[];
    if (raw is String)
      return raw.trim().isEmpty ? const <String>[] : <String>[raw.trim()];
    if (raw is List) {
      return <String>[
        for (final Object? item in raw)
          if (item != null && '$item'.trim().isNotEmpty) '$item'.trim(),
      ];
    }
    throw CtlFailure.badRequest('$name 必须是字符串数组');
  }
}

/// 路由处理器。返回值必须可 JSON 编码；null 视为 `{"ok": true}`。
typedef CtlRouteHandler = Future<Object?> Function(CtlCall call);

/// 一条路由：`method` + 路径模式（`/api/admin/library/books/:key`，`:name` 匹配一段）。
class CtlRoute {
  CtlRoute(this.method, this.pattern, this.handler, {this.requiresReady = true})
    : _segments = _split(pattern);

  CtlRoute.get(
    String pattern,
    CtlRouteHandler handler, {
    bool requiresReady = true,
  }) : this('GET', pattern, handler, requiresReady: requiresReady);

  CtlRoute.post(
    String pattern,
    CtlRouteHandler handler, {
    bool requiresReady = true,
  }) : this('POST', pattern, handler, requiresReady: requiresReady);

  CtlRoute.put(
    String pattern,
    CtlRouteHandler handler, {
    bool requiresReady = true,
  }) : this('PUT', pattern, handler, requiresReady: requiresReady);

  CtlRoute.delete(
    String pattern,
    CtlRouteHandler handler, {
    bool requiresReady = true,
  }) : this('DELETE', pattern, handler, requiresReady: requiresReady);

  final String method;
  final String pattern;
  final CtlRouteHandler handler;

  /// app 未初始化完成时是否直接回 409（绝大多数路由都要 AppModel）。
  final bool requiresReady;

  final List<String> _segments;

  /// 路径匹配则返回路径参数，否则 null。
  Map<String, String>? match(String path) {
    final List<String> parts = _split(path);
    if (parts.length != _segments.length) return null;
    final Map<String, String> params = <String, String>{};
    for (int i = 0; i < parts.length; i++) {
      final String seg = _segments[i];
      if (seg.startsWith(':')) {
        params[seg.substring(1)] = Uri.decodeComponent(parts[i]);
      } else if (seg != parts[i]) {
        return null;
      }
    }
    return params;
  }

  static List<String> _split(String path) =>
      path.split('/').where((String s) => s.isNotEmpty).toList(growable: false);
}
