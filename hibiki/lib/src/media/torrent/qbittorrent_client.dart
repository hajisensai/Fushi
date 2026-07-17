import 'dart:convert';

import 'package:http/http.dart' as http;

/// qBittorrent 列表接口返回的单个种子信息（`/api/v2/torrents/info`）。
class QbTorrentInfo {
  const QbTorrentInfo({
    required this.hash,
    required this.name,
    required this.progress,
    required this.state,
    required this.savePath,
    required this.contentPath,
    required this.amountLeft,
  });

  /// 种子 infohash（小写十六进制），后续查文件列表用。
  final String hash;

  /// 种子显示名。
  final String name;

  /// 下载进度 0.0 ~ 1.0。
  final double progress;

  /// qBittorrent 状态字符串（`downloading` / `uploading` / `stalledUP` 等）。
  final String state;

  /// 保存目录（JSON 键 `save_path`）。
  final String savePath;

  /// 内容根路径：单文件为文件路径，多文件为目录（JSON 键 `content_path`）。
  final String contentPath;

  /// 剩余待下载字节数（JSON 键 `amount_left`）；解析不出为 -1（= 未知，不当作完成）。
  final int amountLeft;

  /// 做种/完成类状态：数据已全部落盘，只在做种或做种停止。
  static const Set<String> _seedingStates = <String>{
    'uploading',
    'stalledUP',
    'pausedUP',
    'stoppedUP',
    'queuedUP',
    'forcedUP',
  };

  /// 错误类状态：即使进度显示 100% 也不视为可用完成态。
  static const Set<String> _errorStates = <String>{
    'error',
    'missingFiles',
  };

  /// 是否已下载完成：state 属于做种类直接算完成；否则要求进度打满
  /// （`progress >= 1.0` 或 `amountLeft == 0`）且 state 不是 error 类。
  bool get isComplete {
    if (_seedingStates.contains(state)) return true;
    if (_errorStates.contains(state)) return false;
    return progress >= 1.0 || amountLeft == 0;
  }
}

/// qBittorrent 文件列表接口返回的单个文件（`/api/v2/torrents/files`）。
class QbTorrentFile {
  const QbTorrentFile({
    required this.name,
    required this.size,
    required this.progress,
    required this.index,
  });

  /// 种子内相对路径（如 `Season 01/EP01.mkv`）。
  final String name;

  /// 文件大小（字节）。
  final int size;

  /// 该文件的下载进度 0.0 ~ 1.0。
  final double progress;

  /// 文件在种子内的序号（JSON 键 `index`）；缺省 -1。
  final int index;
}

/// 归一化 qBittorrent WebUI base URL：去掉尾部所有 `/`。纯函数，便于单测。
String normalizeQbBaseUrl(String raw) {
  String base = raw.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

/// 从 `set-cookie` 响应头提取 `SID=<token>`。纯函数，容错：没有 SID 返回 null。
///
/// `package:http` 会把多个 `Set-Cookie` 头用 `, ` 连成一个字符串，所以这里按
/// 边界正则找 `SID=`，兼容多 cookie 串与属性尾巴（`; path=/` 等）。
String? extractSidCookie(String? setCookieHeader) {
  if (setCookieHeader == null || setCookieHeader.isEmpty) return null;
  final RegExpMatch? match =
      RegExp(r'(?:^|[\s,;])SID=([^;,\s]+)').firstMatch(setCookieHeader);
  final String? sid = match?.group(1);
  if (sid == null || sid.isEmpty) return null;
  return sid;
}

/// 解析 `/api/v2/torrents/info` 响应（JSON 数组）。纯函数，容错：
/// 坏 JSON / 非数组返回空列表；缺 `hash` 的条目跳过；其余字段缺省用安全默认值。
List<QbTorrentInfo> parseQbTorrentInfos(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <QbTorrentInfo>[];
    final List<QbTorrentInfo> out = <QbTorrentInfo>[];
    for (final dynamic e in json) {
      if (e is! Map) continue;
      final dynamic hash = e['hash'];
      if (hash is! String || hash.isEmpty) continue;
      out.add(QbTorrentInfo(
        hash: hash,
        name: e['name'] is String ? e['name'] as String : '',
        progress: e['progress'] is num ? (e['progress'] as num).toDouble() : 0,
        state: e['state'] is String ? e['state'] as String : '',
        savePath: e['save_path'] is String ? e['save_path'] as String : '',
        contentPath:
            e['content_path'] is String ? e['content_path'] as String : '',
        amountLeft: e['amount_left'] is int ? e['amount_left'] as int : -1,
      ));
    }
    return out;
  } catch (_) {
    return const <QbTorrentInfo>[];
  }
}

/// 解析 `/api/v2/torrents/files` 响应（JSON 数组）。纯函数，容错：
/// 坏 JSON / 非数组返回空列表；缺 `name` 的条目跳过；`index` 缺省 -1。
List<QbTorrentFile> parseQbTorrentFiles(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <QbTorrentFile>[];
    final List<QbTorrentFile> out = <QbTorrentFile>[];
    for (final dynamic e in json) {
      if (e is! Map) continue;
      final dynamic name = e['name'];
      if (name is! String || name.isEmpty) continue;
      out.add(QbTorrentFile(
        name: name,
        size: e['size'] is int ? e['size'] as int : 0,
        progress: e['progress'] is num ? (e['progress'] as num).toDouble() : 0,
        index: e['index'] is int ? e['index'] as int : -1,
      ));
    }
    return out;
  } catch (_) {
    return const <QbTorrentFile>[];
  }
}

/// qBittorrent WebUI API v2 客户端（qBittorrent v4.1+）。
///
/// 认证模型：`POST /api/v2/auth/login`（form + 强制 `Referer` 头）拿
/// `SID` cookie，之后所有请求带 `Cookie: SID=<token>`；遇 403（会话过期）
/// 自动重新登录一次并重试该请求。所有网络方法容错：异常/失败一律返回
/// null / false / 空列表，绝不抛。
class QBittorrentClient {
  QBittorrentClient({
    required String baseUrl,
    required this.username,
    required this.password,
    http.Client? client,
  })  : baseUrl = normalizeQbBaseUrl(baseUrl),
        _client = client ?? http.Client();

  /// 归一化后的 WebUI 地址（无尾部 `/`），如 `http://127.0.0.1:8080`。
  final String baseUrl;
  final String username;
  final String password;
  final http.Client _client;

  /// 当前会话 cookie；null = 尚未登录或已失效。
  String? _sid;

  /// 登录并缓存 SID cookie。成功返回 true；凭据错误/网络异常返回 false。
  Future<bool> login() async {
    _sid = null;
    try {
      final http.Response res = await _client.post(
        Uri.parse('$baseUrl/api/v2/auth/login'),
        // qBittorrent 强制校验 Referer 与 Host 一致，否则 401。
        headers: <String, String>{'Referer': baseUrl},
        body: <String, String>{'username': username, 'password': password},
      );
      // 成功是 200 + body `Ok.`；密码错误也是 200 但 body `Fails.`。
      if (res.statusCode != 200 || !res.body.trim().startsWith('Ok')) {
        return false;
      }
      _sid = extractSidCookie(res.headers['set-cookie']);
      return _sid != null;
    } catch (_) {
      return false;
    }
  }

  /// 连接测试：`GET /api/v2/app/version` → 形如 `v4.6.5`；失败返回 null。
  Future<String?> fetchVersion() async {
    final http.Response? res = await _request('GET', '/api/v2/app/version');
    if (res == null || res.statusCode != 200) return null;
    final String version = res.body.trim();
    return version.isEmpty ? null : version;
  }

  /// 添加下载：[urls] 是 magnet 链接或 .torrent URL（多个换行连接）。
  /// 200 且 body `Ok.` 视为成功。
  ///
  /// [sequentialDownload] 开顺序下载、[firstLastPiecePrio] 开首尾块优先：两者
  /// 齐开时视频文件从下载初期就可顺序播放（边下边播的前置条件）。
  Future<bool> addTorrents(
    List<String> urls, {
    String? category,
    String? savePath,
    bool sequentialDownload = false,
    bool firstLastPiecePrio = false,
  }) async {
    if (urls.isEmpty) return false;
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/add',
      form: <String, String>{
        'urls': urls.join('\n'),
        if (category != null) 'category': category,
        if (savePath != null) 'savepath': savePath,
        if (sequentialDownload) 'sequentialDownload': 'true',
        if (firstLastPiecePrio) 'firstLastPiecePrio': 'true',
      },
    );
    return res != null &&
        res.statusCode == 200 &&
        res.body.trim().startsWith('Ok');
  }

  /// 确保分类存在：`POST /api/v2/torrents/createCategory`；
  /// 409（已存在）也算成功。
  Future<bool> ensureCategory(String category, {String? savePath}) async {
    if (category.isEmpty) return false;
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/createCategory',
      form: <String, String>{
        'category': category,
        if (savePath != null) 'savePath': savePath,
      },
    );
    return res != null && (res.statusCode == 200 || res.statusCode == 409);
  }

  /// 列种子：`GET /api/v2/torrents/info`，[category] 非空时只列该分类。
  Future<List<QbTorrentInfo>> fetchTorrents({String? category}) async {
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/info',
      query: category == null ? null : <String, String>{'category': category},
    );
    if (res == null || res.statusCode != 200) return const <QbTorrentInfo>[];
    return parseQbTorrentInfos(res.body);
  }

  /// 列某个种子内的文件：`GET /api/v2/torrents/files?hash=<h>`。
  Future<List<QbTorrentFile>> fetchTorrentFiles(String hash) async {
    if (hash.isEmpty) return const <QbTorrentFile>[];
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/files',
      query: <String, String>{'hash': hash},
    );
    if (res == null || res.statusCode != 200) return const <QbTorrentFile>[];
    return parseQbTorrentFiles(res.body);
  }

  /// 带会话编排的请求：懒登录 → 发请求 → 403 时重新登录一次并重试。
  /// 任何异常/登录失败返回 null。
  Future<http.Response?> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
  }) async {
    try {
      if (_sid == null && !await login()) return null;
      http.Response res = await _send(method, path, query: query, form: form);
      if (res.statusCode == 403) {
        // 会话过期：只重登一次，仍失败就把 403 交给调用方按失败处理。
        _sid = null;
        if (!await login()) return null;
        res = await _send(method, path, query: query, form: form);
      }
      return res;
    } catch (_) {
      return null;
    }
  }

  /// 发一次裸请求（带 SID cookie 与 Referer）。
  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
  }) {
    Uri uri = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    final Map<String, String> headers = <String, String>{
      'Referer': baseUrl,
      if (_sid != null) 'Cookie': 'SID=$_sid',
    };
    if (method == 'POST') {
      return _client.post(uri, headers: headers, body: form ?? const {});
    }
    return _client.get(uri, headers: headers);
  }

  void close() => _client.close();
}
