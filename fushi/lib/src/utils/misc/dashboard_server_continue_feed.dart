/// 首页「继续」里用户自配服务器条目（Jellyfin / Emby / Plex、Audiobookshelf）的
/// 进程级取数状态：结果缓存 + 刷新节流 + 媒体服务器浏览器（及其 HTTP 连接）的
/// 生命周期。
///
/// 首页不在 keep-alive 名单里，每次切回首页都整页重建；把这些状态放在页面 State
/// 上，等于每次回首页都对每台服务器重发 Resume / NextUp，并且每次新建一个永不关闭
/// 的 HTTP 客户端。这里按数据库实例（[of]）留一份：
/// - **节流**：[load] 在 [ttl] 内、门控签名不变时直接复用上一轮结果，不发请求；
///   `force` 绕过（下拉刷新 / 从服务器条目回来、进度确实变了）。并发调用串行，排在
///   后面的非强制调用若前一轮刚取完就直接复用。
/// - **连接复用与关闭**：[browserFor] 按服务器配置（含线路与令牌）复用同一个浏览器，
///   浏览器用本类持有的 HTTP 客户端建；[retainBrowsers] 把不再出现的配置（登出 /
///   换线路 / 门控关闭）的客户端关掉。卡片封面取图与起播都用这里交出的浏览器，所以
///   它们必须活得比单次取数长，不能在取数结束时就关。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

class ServerContinueFeed {
  ServerContinueFeed({
    this.ttl = const Duration(seconds: 90),
    http.Client Function()? httpClientFactory,
    int Function()? nowMs,
  }) : _httpClientFactory = httpClientFactory ?? createAppHttpIoClient,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static final Expando<ServerContinueFeed> _byOwner =
      Expando<ServerContinueFeed>('server-continue-feed');

  /// [owner] 一般是数据库实例：换库（切 Profile 库 / 恢复备份）即换一份状态。
  static ServerContinueFeed of(Object owner) =>
      _byOwner[owner] ??= ServerContinueFeed();

  /// 结果在这段时间内视为新鲜（非强制刷新直接复用）。
  final Duration ttl;
  final http.Client Function() _httpClientFactory;
  final int Function() _nowMs;

  List<ServerContinueCandidate> _current = const <ServerContinueCandidate>[];
  String? _gate;
  int? _fetchedAt;
  Future<void> _tail = Future<void>.value();

  final Map<String, ({MediaServerBrowser browser, http.Client client})>
  _browsers = <String, ({MediaServerBrowser browser, http.Client client})>{};

  /// 上一轮的结果（页面重建首帧直接用，不闪）。
  List<ServerContinueCandidate> get current => _current;

  bool _isFresh(String gate) {
    final int? at = _fetchedAt;
    return at != null && _gate == gate && _nowMs() - at < ttl.inMilliseconds;
  }

  /// 取一轮候选。[gate] 是影响「该问哪些服务器」的门控签名（混排开关、模块开关）：
  /// 签名变了上一轮结果即作废。[force] 绕过节流。
  Future<List<ServerContinueCandidate>> load({
    required String gate,
    required Future<List<ServerContinueCandidate>> Function() fetch,
    bool force = false,
  }) {
    if (!force && _isFresh(gate)) {
      return Future<List<ServerContinueCandidate>>.value(_current);
    }
    final Future<List<ServerContinueCandidate>> run = _tail.then((_) async {
      if (!force && _isFresh(gate)) return _current;
      final int startedAt = _nowMs();
      final List<ServerContinueCandidate> loaded = await fetch();
      _current = loaded;
      _gate = gate;
      _fetchedAt = startedAt;
      return loaded;
    });
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// 让下一次 [load] 无论是否在节流窗口内都重取（服务器配置变了等）。
  void invalidate() => _fetchedAt = null;

  static String _configKey(MediaServerConfig config) =>
      '${config.kind.name}|${jsonEncode(config.toJson())}';

  /// [config] 对应的浏览器：同一配置（含当前线路与令牌）复用同一个实例与连接。
  MediaServerBrowser browserFor(MediaServerConfig config) {
    final String key = _configKey(config);
    final ({MediaServerBrowser browser, http.Client client})? existing =
        _browsers[key];
    if (existing != null) return existing.browser;
    final http.Client client = _httpClientFactory();
    final MediaServerBrowser browser = config.buildBrowser(httpClient: client);
    _browsers[key] = (browser: browser, client: client);
    return browser;
  }

  /// 只保留 [configs] 对应的浏览器，其余（登出 / 换线路 / 换令牌 / 门控关掉）关掉
  /// 连接并丢弃。
  void retainBrowsers(Iterable<MediaServerConfig> configs) {
    final Set<String> keep = <String>{
      for (final MediaServerConfig c in configs) _configKey(c),
    };
    final List<String> stale = <String>[
      for (final String key in _browsers.keys)
        if (!keep.contains(key)) key,
    ];
    for (final String key in stale) {
      _browsers.remove(key)!.client.close();
    }
  }

  /// 当前持有的浏览器数（测试用）。
  int get browserCount => _browsers.length;
}
