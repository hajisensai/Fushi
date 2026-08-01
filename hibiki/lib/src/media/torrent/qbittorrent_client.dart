import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:hibiki/src/media/torrent/torrent_backend.dart';

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
  final RegExpMatch? match = RegExp(
    r'(?:^|[\s,;])SID=([^;,\s]+)',
  ).firstMatch(setCookieHeader);
  final String? sid = match?.group(1);
  if (sid == null || sid.isEmpty) return null;
  return sid;
}

/// 解析 `/api/v2/torrents/info` 响应（JSON 数组）为中性 [TorrentSnapshot]。
/// 纯函数，容错：坏 JSON / 非数组返回空列表；缺 `hash` 的条目跳过；
/// 其余字段缺省用安全默认值（`save_path` / `content_path` / `amount_left`）。
List<TorrentSnapshot> parseQbTorrentInfos(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <TorrentSnapshot>[];
    final List<TorrentSnapshot> out = <TorrentSnapshot>[];
    for (final dynamic e in json) {
      if (e is! Map) continue;
      final dynamic hash = e['hash'];
      if (hash is! String || hash.isEmpty) continue;
      out.add(TorrentSnapshot(
        hash: hash,
        name: e['name'] is String ? e['name'] as String : '',
        progress: e['progress'] is num ? (e['progress'] as num).toDouble() : 0,
        state: e['state'] is String ? e['state'] as String : '',
        savePath: e['save_path'] is String ? e['save_path'] as String : '',
        contentPath:
            e['content_path'] is String ? e['content_path'] as String : '',
        amountLeft: e['amount_left'] is int ? e['amount_left'] as int : -1,
        // BUG-1294：qb 一直返回这些字段，此前解析时被丢弃。
        downRateBps: e['dlspeed'] is int ? e['dlspeed'] as int : 0,
        upRateBps: e['upspeed'] is int ? e['upspeed'] as int : 0,
        downloadedBytes: e['downloaded'] is int ? e['downloaded'] as int : 0,
        uploadedBytes: e['uploaded'] is int ? e['uploaded'] as int : 0,
        numPeers: (e['num_seeds'] is int ? e['num_seeds'] as int : 0) +
            (e['num_leechs'] is int ? e['num_leechs'] as int : 0),
      ));
    }
    return out;
  } catch (_) {
    return const <TorrentSnapshot>[];
  }
}

/// 解析 `/api/v2/torrents/files` 响应（JSON 数组）为中性 [TorrentFileEntry]。
/// 纯函数，容错：坏 JSON / 非数组返回空列表；缺 `name` 的条目跳过；
/// `index` 缺省 -1。
List<TorrentFileEntry> parseQbTorrentFiles(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <TorrentFileEntry>[];
    final List<TorrentFileEntry> out = <TorrentFileEntry>[];
    for (final dynamic e in json) {
      if (e is! Map) continue;
      final dynamic name = e['name'];
      if (name is! String || name.isEmpty) continue;
      out.add(
        TorrentFileEntry(
          name: name,
          size: e['size'] is int ? e['size'] as int : 0,
          progress:
              e['progress'] is num ? (e['progress'] as num).toDouble() : 0,
          index: e['index'] is int ? e['index'] as int : -1,
        ),
      );
    }
    return out;
  } catch (_) {
    return const <TorrentFileEntry>[];
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
    this.requestTimeout = const Duration(seconds: 10),
  })  : baseUrl = normalizeQbBaseUrl(baseUrl),
        _client = client ?? http.Client();

  /// 归一化后的 WebUI 地址（无尾部 `/`），如 `http://127.0.0.1:8080`。
  final String baseUrl;
  final String username;
  final String password;
  final http.Client _client;
  final Duration requestTimeout;

  /// 当前会话 cookie；null = 尚未登录或已失效。
  String? _sid;

  /// qBittorrent 开着「对本地主机的客户端跳过身份验证」时，登录接口仍校验
  /// 账密（用户往往根本没设/记不得），但业务接口匿名即可用。BUG-1295：
  /// 登录失败后做一次匿名探测，通了就免登录直连，别把可用的 API 卡死在
  /// 登录门外。true = 已验证匿名可用。
  bool _anonymousOk = false;

  /// 最近一次连接/登录失败的可读原因（英文原样，探测 UI 透传显示）；
  /// 成功后清空。BUG-1295：此前所有失败路径都折叠成一个 null，用户无从自查。
  String? get lastFailure => _lastFailure;
  String? _lastFailure;

  /// 登录并缓存 SID cookie。成功返回 true；凭据错误/网络异常返回 false
  /// （原因落 [lastFailure]）。
  Future<bool> login() async {
    _sid = null;
    try {
      final http.Response res = await _client.post(
        Uri.parse('$baseUrl/api/v2/auth/login'),
        // qBittorrent 强制校验 Referer 与 Host 一致，否则 401。
        headers: <String, String>{'Referer': baseUrl},
        body: <String, String>{'username': username, 'password': password},
      ).timeout(requestTimeout);
      final String body = res.body.trim();
      // 登录失败超限（默认 5 次）后 qb 返回 403 + "…banned…"，解封前填对
      // 账密也进不去——必须单独说清，否则用户会反复重试把封禁续期。
      if (res.statusCode == 403) {
        _lastFailure = body.toLowerCase().contains('banned')
            ? 'IP banned by qBittorrent after too many failed logins '
                '(unban: restart qBittorrent or wait, default 1 hour)'
            : 'HTTP 403: $body';
        return false;
      }
      // 成功是 200 + body `Ok.`；密码错误也是 200 但 body `Fails.`。
      if (res.statusCode != 200) {
        _lastFailure = 'HTTP ${res.statusCode}${body.isEmpty ? '' : ': $body'}';
        return false;
      }
      if (!body.startsWith('Ok')) {
        _lastFailure = 'login rejected (wrong username/password)';
        return false;
      }
      _sid = extractSidCookie(res.headers['set-cookie']);
      if (_sid == null) {
        _lastFailure = 'login ok but no SID cookie in response';
        return false;
      }
      _lastFailure = null;
      return true;
    } catch (e) {
      _lastFailure = e.toString();
      return false;
    }
  }

  /// 匿名探测：不带 Cookie 直接拉版本号。qb 的 localhost 免密（或整体关闭
  /// 认证）时可用。成功则清空 [lastFailure]（连接本身是通的）。
  Future<bool> _probeAnonymous() async {
    try {
      final http.Response res = await _client.get(
        Uri.parse('$baseUrl/api/v2/app/version'),
        headers: <String, String>{'Referer': baseUrl},
      ).timeout(requestTimeout);
      if (res.statusCode == 200 && res.body.trim().isNotEmpty) {
        _lastFailure = null;
        return true;
      }
      return false;
    } catch (_) {
      // 保留 login() 已记下的失败原因（网络不通时两边是同一个原因）。
      return false;
    }
  }

  /// 连接测试：`GET /api/v2/app/version` → 形如 `v4.6.5`；失败返回 null
  /// （原因见 [lastFailure]）。
  Future<String?> fetchVersion() async {
    final http.Response? res = await _request('GET', '/api/v2/app/version');
    if (res == null) return null;
    if (res.statusCode != 200) {
      _lastFailure = 'HTTP ${res.statusCode} from /api/v2/app/version';
      return null;
    }
    final String version = res.body.trim();
    if (version.isEmpty) {
      _lastFailure = 'empty version response';
      return null;
    }
    return version;
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
  Future<List<TorrentSnapshot>> fetchTorrents({String? category}) async {
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/info',
      query: category == null ? null : <String, String>{'category': category},
    );
    if (res == null || res.statusCode != 200) return const <TorrentSnapshot>[];
    return parseQbTorrentInfos(res.body);
  }

  /// 列某个种子内的文件：`GET /api/v2/torrents/files?hash=<h>`。
  Future<List<TorrentFileEntry>> fetchTorrentFiles(String hash) async {
    if (hash.isEmpty) return const <TorrentFileEntry>[];
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/files',
      query: <String, String>{'hash': hash},
    );
    if (res == null || res.statusCode != 200) return const <TorrentFileEntry>[];
    return parseQbTorrentFiles(res.body);
  }

  /// 删除单个种子；默认只移除任务、保留已下载文件。
  Future<bool> deleteTorrent(String hash, {bool deleteFiles = false}) async {
    if (hash.isEmpty) return false;
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/delete',
      form: <String, String>{
        'hashes': hash,
        'deleteFiles': deleteFiles ? 'true' : 'false',
      },
    );
    return res != null && res.statusCode == 200;
  }

  /// TODO-2481：暂停单个种子：`POST /api/v2/torrents/pause`（form 参数
  /// hashes）。qBittorrent 5.0（WebUI API ≥ 2.11）把端点改名成
  /// `/torrents/stop` 并移除旧名 —— 404 时回退新名（外部系统版本差异，
  /// 本客户端无从根治，只能双名兼容）。
  Future<bool> pauseTorrent(String hash) =>
      _postTorrentsToggle(hash, primary: 'pause', renamed: 'stop');

  /// TODO-2481：恢复单个种子：`POST /api/v2/torrents/resume`；qb 5.0 改名
  /// `/torrents/start`，404 回退，同 [pauseTorrent]。
  Future<bool> resumeTorrent(String hash) =>
      _postTorrentsToggle(hash, primary: 'resume', renamed: 'start');

  /// 暂停/恢复的公共发送路径：先老端点 [primary]，404（qb 5.0 移除旧名）
  /// 再试新端点 [renamed]。两名皆失败返回 false。
  Future<bool> _postTorrentsToggle(
    String hash, {
    required String primary,
    required String renamed,
  }) async {
    if (hash.isEmpty) return false;
    final Map<String, String> form = <String, String>{'hashes': hash};
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/$primary',
      form: form,
    );
    if (res != null && res.statusCode == 200) return true;
    if (res == null || res.statusCode != 404) return false;
    final http.Response? retry = await _request(
      'POST',
      '/api/v2/torrents/$renamed',
      form: form,
    );
    return retry != null && retry.statusCode == 200;
  }

  /// TODO-1961-c：改名种子内文件：`POST /api/v2/torrents/renameFile`
  /// （qb ≥ 4.2.1，参数 hash / oldPath / newPath）。
  ///
  /// 与内置引擎同语义：qb 自己改，做种不断。返回 (成功, 失败原因)：
  /// - 409 = qb 明确拒绝（目标已存在 / 名字非法），body 是可读原因；
  /// - 其它非 200 或网络失败 → 通用原因串。
  Future<(bool ok, String? error)> renameFile({
    required String hash,
    required String oldPath,
    required String newPath,
  }) async {
    if (hash.isEmpty || oldPath.isEmpty || newPath.isEmpty) {
      return (false, 'invalid rename arguments');
    }
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/renameFile',
      form: <String, String>{
        'hash': hash,
        'oldPath': oldPath,
        'newPath': newPath,
      },
    );
    if (res == null) return (false, 'qBittorrent request failed');
    if (res.statusCode == 200) return (true, null);
    final String body = res.body.trim();
    return (false, body.isEmpty ? 'HTTP ${res.statusCode}' : body);
  }

  /// TODO-1961-c：移动种子内容：`POST /api/v2/torrents/setLocation`
  /// （参数 hashes / location）。
  ///
  /// 注意与内置引擎的**语义差异**：qb 的 setLocation 对目标已存在的文件不保证
  /// 「整体失败不覆盖」——那是 qb 自身的策略，本客户端管不了。调用方在 UI 上
  /// 对外接 qb 后端应当提示这一点。
  Future<(bool ok, String? error)> setLocation({
    required String hash,
    required String location,
  }) async {
    if (hash.isEmpty || location.isEmpty) {
      return (false, 'invalid setLocation arguments');
    }
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/setLocation',
      form: <String, String>{'hashes': hash, 'location': location},
    );
    if (res == null) return (false, 'qBittorrent request failed');
    if (res.statusCode == 200) return (true, null);
    final String body = res.body.trim();
    return (false, body.isEmpty ? 'HTTP ${res.statusCode}' : body);
  }

  /// 带会话编排的请求：懒登录（登录失败退匿名探测，BUG-1295）→ 发请求 →
  /// 403 时重新认证一次并重试。任何异常/认证失败返回 null。
  Future<http.Response?> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
  }) async {
    try {
      if (_sid == null && !_anonymousOk && !await _authenticate()) return null;
      http.Response res = await _send(method, path, query: query, form: form);
      if (res.statusCode == 403) {
        // 会话过期 / 免密开关被关掉：只重认证一次，仍失败就把 403 交给
        // 调用方按失败处理。
        _sid = null;
        _anonymousOk = false;
        if (!await _authenticate()) return null;
        res = await _send(method, path, query: query, form: form);
      }
      return res;
    } catch (e) {
      _lastFailure = e.toString();
      return null;
    }
  }

  /// 认证编排：正常登录优先；登录失败（典型：qb localhost 免密下账密没配）
  /// 再匿名探测一次，通了就免登录直连。
  Future<bool> _authenticate() async {
    if (await login()) return true;
    _anonymousOk = await _probeAnonymous();
    return _anonymousOk;
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
      return _client
          .post(uri, headers: headers, body: form ?? const {})
          .timeout(requestTimeout);
    }
    return _client.get(uri, headers: headers).timeout(requestTimeout);
  }

  void close() => _client.close();
}
