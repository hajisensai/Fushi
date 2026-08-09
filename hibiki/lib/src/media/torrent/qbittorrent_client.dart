import 'dart:convert';
import 'dart:typed_data';

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
        // TODO-2482：详情页拆分字段；缺字段/非 int 一律 -1（= 未提供）。
        // [numPeers] 保持「seeds+leechs 合并」的旧语义不变。
        numSeeds: _qbInt(e, 'num_seeds'),
        numLeechs: _qbInt(e, 'num_leechs'),
        swarmSeeds: _qbInt(e, 'num_complete'),
        swarmLeechs: _qbInt(e, 'num_incomplete'),
        activeDurationSeconds: _qbInt(e, 'time_active'),
        seedingDurationSeconds: _qbInt(e, 'seeding_time'),
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

/// 从 qb JSON map 里取 int 字段；缺失/类型不对返回 [fallback]（默认 -1，
/// 与「后端未提供」的 DTO 语义对齐）。
int _qbInt(Map<dynamic, dynamic> e, String key, {int fallback = -1}) =>
    e[key] is int ? e[key] as int : fallback;

/// TODO-2482：解析 `/api/v2/sync/torrentPeers` 响应
/// （`{"peers":{"1.2.3.4:6881":{...}}}`）为中性 [TorrentPeerDetail] 列表。
/// 纯函数，容错：坏 JSON / 顶层非 Map / `peers` 非 Map 返回空列表；
/// 单条 peer 非 Map 跳过。`ip` 字段缺失时从 map key（`ip:port`，IPv6 形如
/// `[::1]:6881`）按最后一个 `:` 拆出地址与端口。
List<TorrentPeerDetail> parseQbTorrentPeers(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! Map) return const <TorrentPeerDetail>[];
    final dynamic peers = json['peers'];
    if (peers is! Map) return const <TorrentPeerDetail>[];
    final List<TorrentPeerDetail> out = <TorrentPeerDetail>[];
    for (final MapEntry<dynamic, dynamic> entry in peers.entries) {
      final dynamic e = entry.value;
      if (e is! Map) continue;
      String address = e['ip'] is String ? e['ip'] as String : '';
      int port = e['port'] is int ? e['port'] as int : 0;
      if (address.isEmpty) {
        // key 形如 `1.2.3.4:6881` / `[::1]:6881`：按最后一个 `:` 拆分，
        // 天然兼容 IPv6 地址内部的冒号。
        final String key = entry.key is String ? entry.key as String : '';
        final int sep = key.lastIndexOf(':');
        if (sep > 0) {
          address = key.substring(0, sep);
          if (port == 0) {
            port = int.tryParse(key.substring(sep + 1)) ?? 0;
          }
        } else {
          address = key;
        }
      }
      out.add(TorrentPeerDetail(
        address: address,
        port: port,
        client: e['client'] is String ? e['client'] as String : '',
        progress: e['progress'] is num ? (e['progress'] as num).toDouble() : 0,
        downSpeedBps: _qbInt(e, 'dl_speed', fallback: 0),
        upSpeedBps: _qbInt(e, 'up_speed', fallback: 0),
        downloadedBytes: _qbInt(e, 'downloaded', fallback: 0),
        uploadedBytes: _qbInt(e, 'uploaded', fallback: 0),
        flags: e['flags'] is String ? e['flags'] as String : '',
      ));
    }
    return out;
  } catch (_) {
    return const <TorrentPeerDetail>[];
  }
}

/// qb tracker `status` int → 中性枚举；值域外（未来新值/坏数据）归
/// [TorrentTrackerStatus.notContacted]。
TorrentTrackerStatus _qbTrackerStatus(int status) {
  switch (status) {
    case 0:
      return TorrentTrackerStatus.disabled;
    case 1:
      return TorrentTrackerStatus.notContacted;
    case 2:
      return TorrentTrackerStatus.working;
    case 3:
      return TorrentTrackerStatus.updating;
    case 4:
      return TorrentTrackerStatus.notWorking;
    default:
      return TorrentTrackerStatus.notContacted;
  }
}

/// TODO-2482：解析 `/api/v2/torrents/trackers` 响应（JSON 数组）为中性
/// [TorrentTrackerDetail] 列表。纯函数，容错：坏 JSON / 非数组返回空列表；
/// 缺 `url` 的条目跳过。
///
/// qb 对 DHT/PEX/LSD 伪 tracker 条目（url 形如 `** [DHT] **`）给 tier=-1：
/// 归一成 tier=0 + [TorrentTrackerStatus.disabled]，但**保留导出**——
/// 显示与否是 UI 的决定，不在解析层丢数据。
List<TorrentTrackerDetail> parseQbTrackers(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return const <TorrentTrackerDetail>[];
    final List<TorrentTrackerDetail> out = <TorrentTrackerDetail>[];
    for (final dynamic e in json) {
      if (e is! Map) continue;
      final dynamic url = e['url'];
      if (url is! String || url.isEmpty) continue;
      final int tier = _qbInt(e, 'tier', fallback: 0);
      final bool pseudo = tier < 0;
      out.add(TorrentTrackerDetail(
        url: url,
        tier: pseudo ? 0 : tier,
        status: pseudo
            ? TorrentTrackerStatus.disabled
            : _qbTrackerStatus(_qbInt(e, 'status', fallback: 1)),
        seeds: _qbInt(e, 'num_seeds'),
        leeches: _qbInt(e, 'num_leeches'),
        downloaded: _qbInt(e, 'num_downloaded'),
        message: e['msg'] is String ? e['msg'] as String : '',
      ));
    }
    return out;
  } catch (_) {
    return const <TorrentTrackerDetail>[];
  }
}

/// TODO-2482：解析 `/api/v2/transfer/info` 响应为部分填充的
/// [TorrentSessionStatusInfo]（只有速率与 DHT 节点数；DHT/LSD/PEX 开关和
/// 监听端口在 preferences 端点，由 [QBittorrentClient.fetchSessionStatus]
/// 组合）。纯函数，容错：坏 JSON / 非 Map 返回 null。
TorrentSessionStatusInfo? parseQbTransferInfo(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! Map) return null;
    return TorrentSessionStatusInfo(
      downRateBps: _qbInt(json, 'dl_info_speed'),
      upRateBps: _qbInt(json, 'up_info_speed'),
      dhtNodes: _qbInt(json, 'dht_nodes'),
    );
  } catch (_) {
    return null;
  }
}

/// TODO-2482：解析 `/api/v2/torrents/pieceStates` 响应（JSON int 数组，
/// 值域 0/1/2）。纯函数，容错：坏 JSON / 非数组返回 null；非 int 条目按 0
/// （缺）处理，不整体失败。
TorrentPieceStates? parseQbPieceStates(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return null;
    final List<int> states = <int>[];
    for (final dynamic e in json) {
      states.add(e is int ? e : 0);
    }
    return TorrentPieceStates(states: states);
  } catch (_) {
    return null;
  }
}

/// qb 文件优先级读值 → 中性枚举：0=skip、6/7=high、其余（1/4/5 与任何
/// 坏值）=normal（qb 历史值域，1 与 4/5 都是「正常」档）。
TorrentFilePriority _qbFilePriorityFromValue(int value) {
  if (value == 0) return TorrentFilePriority.skip;
  if (value == 6 || value == 7) return TorrentFilePriority.high;
  return TorrentFilePriority.normal;
}

/// TODO-2482：从 `/api/v2/torrents/files` 响应（与 [parseQbTorrentFiles]
/// 同一份 body）按文件 index 对位提取 `priority`。纯函数，容错：
/// 坏 JSON / 非数组返回 null；单条目坏 → 该条 normal。
///
/// **files 数组不保证按 index 排序**：先按条目自带的 `index` 落位；
/// `index` 缺失/越界时退回按出现序占位。
List<TorrentFilePriority>? parseQbFilePriorities(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) return null;
    final int n = json.length;
    final List<TorrentFilePriority> out =
        List<TorrentFilePriority>.filled(n, TorrentFilePriority.normal);
    int position = 0;
    for (final dynamic e in json) {
      int index = position;
      TorrentFilePriority priority = TorrentFilePriority.normal;
      if (e is Map) {
        final int declared = _qbInt(e, 'index');
        if (declared >= 0 && declared < n) index = declared;
        final dynamic p = e['priority'];
        if (p is int) priority = _qbFilePriorityFromValue(p);
      }
      out[index] = priority;
      position++;
    }
    return out;
  } catch (_) {
    return null;
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

  /// Uploads validated `.torrent` metainfo using qBittorrent's multipart
  /// `torrents` field. Provider download URLs are resolved before this call,
  /// so temporary API keys never enter qBittorrent's persistent task state.
  Future<bool> addTorrentFile(
    Uint8List bytes, {
    required String fileName,
    String? category,
    String? savePath,
    bool sequentialDownload = false,
    bool firstLastPiecePrio = false,
  }) async {
    if (bytes.isEmpty) return false;
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/add',
      form: <String, String>{
        if (category != null) 'category': category,
        if (savePath != null) 'savepath': savePath,
        if (sequentialDownload) 'sequentialDownload': 'true',
        if (firstLastPiecePrio) 'firstLastPiecePrio': 'true',
      },
      torrentBytes: bytes,
      torrentFileName: fileName,
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

  /// TODO-2482：某种子当前连接的 peer 列表：
  /// `GET /api/v2/sync/torrentPeers?hash=<h>&rid=0`（rid=0 = 全量快照，
  /// 不走增量 diff）。失败/非 200 返回 null（区别于「连上了但没 peer」的
  /// 空列表）。
  Future<List<TorrentPeerDetail>?> fetchTorrentPeers(String hash) async {
    if (hash.isEmpty) return null;
    final http.Response? res = await _request(
      'GET',
      '/api/v2/sync/torrentPeers',
      query: <String, String>{'hash': hash, 'rid': '0'},
    );
    if (res == null || res.statusCode != 200) return null;
    return parseQbTorrentPeers(res.body);
  }

  /// TODO-2482：某种子的 tracker 列表：`GET /api/v2/torrents/trackers`。
  Future<List<TorrentTrackerDetail>?> fetchTrackers(String hash) async {
    if (hash.isEmpty) return null;
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/trackers',
      query: <String, String>{'hash': hash},
    );
    if (res == null || res.statusCode != 200) return null;
    return parseQbTrackers(res.body);
  }

  /// TODO-2482：某种子每个文件的优先级（按 index 对位）：复用
  /// `GET /api/v2/torrents/files` 响应经 [parseQbFilePriorities] 提取。
  Future<List<TorrentFilePriority>?> fetchFilePriorities(String hash) async {
    if (hash.isEmpty) return null;
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/files',
      query: <String, String>{'hash': hash},
    );
    if (res == null || res.statusCode != 200) return null;
    return parseQbFilePriorities(res.body);
  }

  /// TODO-2482：设置若干文件的下载优先级：`POST /api/v2/torrents/filePrio`
  /// （form：hash / id=`index|index|...` / priority，值域见
  /// `_qbFilePriorityFromValue` 的注释）。200 = 成功。
  Future<bool> setFilePriority({
    required String hash,
    required List<int> fileIndexes,
    required int priority,
  }) async {
    if (hash.isEmpty || fileIndexes.isEmpty) return false;
    final http.Response? res = await _request(
      'POST',
      '/api/v2/torrents/filePrio',
      form: <String, String>{
        'hash': hash,
        'id': fileIndexes.join('|'),
        'priority': '$priority',
      },
    );
    return res != null && res.statusCode == 200;
  }

  /// TODO-2482：会话级协议状态：组合 `GET /api/v2/transfer/info`（速率 +
  /// DHT 节点数）与 `GET /api/v2/app/preferences`（DHT/LSD/PEX 开关 +
  /// 监听端口）。preferences 失败时仍返回 transfer 侧的部分数据（bool 开关
  /// 保持 null = 不知道）；两个端点都失败才返回 null。
  ///
  /// 注意 portMappings 恒为空：qb API 只暴露 UPnP **开关**，拿不到映射
  /// **结果**，伪造一条「成功」是撒谎，UI 对外接 qb 不渲染该行。
  Future<TorrentSessionStatusInfo?> fetchSessionStatus() async {
    final http.Response? infoRes =
        await _request('GET', '/api/v2/transfer/info');
    final TorrentSessionStatusInfo? transfer =
        (infoRes != null && infoRes.statusCode == 200)
            ? parseQbTransferInfo(infoRes.body)
            : null;
    Map<dynamic, dynamic>? prefs;
    final http.Response? prefRes =
        await _request('GET', '/api/v2/app/preferences');
    if (prefRes != null && prefRes.statusCode == 200) {
      try {
        final dynamic json = jsonDecode(prefRes.body);
        if (json is Map) prefs = json;
      } catch (_) {
        // preferences 坏 body 按「没拿到」处理，不影响 transfer 侧数据。
      }
    }
    if (transfer == null && prefs == null) return null;
    return TorrentSessionStatusInfo(
      dhtEnabled: prefs?['dht'] is bool ? prefs!['dht'] as bool : null,
      dhtNodes: transfer?.dhtNodes ?? -1,
      lsdEnabled: prefs?['lsd'] is bool ? prefs!['lsd'] as bool : null,
      pexEnabled: prefs?['pex'] is bool ? prefs!['pex'] as bool : null,
      listenPort:
          prefs?['listen_port'] is int ? prefs!['listen_port'] as int : 0,
      downRateBps: transfer?.downRateBps ?? -1,
      upRateBps: transfer?.upRateBps ?? -1,
    );
  }

  /// TODO-2482：某种子的 piece 位图：`GET /api/v2/torrents/pieceStates`。
  Future<TorrentPieceStates?> fetchPieceStates(String hash) async {
    if (hash.isEmpty) return null;
    final http.Response? res = await _request(
      'GET',
      '/api/v2/torrents/pieceStates',
      query: <String, String>{'hash': hash},
    );
    if (res == null || res.statusCode != 200) return null;
    return parseQbPieceStates(res.body);
  }

  /// 带会话编排的请求：懒登录（登录失败退匿名探测，BUG-1295）→ 发请求 →
  /// 403 时重新认证一次并重试。任何异常/认证失败返回 null。
  Future<http.Response?> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
    Uint8List? torrentBytes,
    String? torrentFileName,
  }) async {
    try {
      if (_sid == null && !_anonymousOk && !await _authenticate()) return null;
      http.Response res = await _send(
        method,
        path,
        query: query,
        form: form,
        torrentBytes: torrentBytes,
        torrentFileName: torrentFileName,
      );
      if (res.statusCode == 403) {
        // 会话过期 / 免密开关被关掉：只重认证一次，仍失败就把 403 交给
        // 调用方按失败处理。
        _sid = null;
        _anonymousOk = false;
        if (!await _authenticate()) return null;
        res = await _send(
          method,
          path,
          query: query,
          form: form,
          torrentBytes: torrentBytes,
          torrentFileName: torrentFileName,
        );
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
    Uint8List? torrentBytes,
    String? torrentFileName,
  }) async {
    Uri uri = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    final Map<String, String> headers = <String, String>{
      'Referer': baseUrl,
      if (_sid != null) 'Cookie': 'SID=$_sid',
    };
    if (method == 'POST') {
      if (torrentBytes != null) {
        final http.MultipartRequest request = http.MultipartRequest('POST', uri)
          ..headers.addAll(headers)
          ..fields.addAll(form ?? const <String, String>{})
          ..files.add(
            http.MultipartFile.fromBytes(
              'torrents',
              torrentBytes,
              filename: _safeTorrentFileName(torrentFileName),
            ),
          );
        final http.StreamedResponse streamed =
            await _client.send(request).timeout(requestTimeout);
        return http.Response.fromStream(streamed);
      }
      return _client
          .post(uri, headers: headers, body: form ?? const {})
          .timeout(requestTimeout);
    }
    return _client.get(uri, headers: headers).timeout(requestTimeout);
  }

  void close() => _client.close();
}

String _safeTorrentFileName(String? raw) {
  final String leaf = (raw ?? 'download.torrent')
      .replaceAll('\\', '/')
      .split('/')
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (leaf.isEmpty) return 'download.torrent';
  return leaf.toLowerCase().endsWith('.torrent') ? leaf : '$leaf.torrent';
}
