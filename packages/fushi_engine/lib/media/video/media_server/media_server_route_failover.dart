/// 媒体服务器线路故障转移的传输层原语（拍板台 design-media-server-failover-transport）。
///
/// 纯 Dart（无 Flutter / 插件）：PlexApi（本包）与 app 侧的 JellyfinApi 共用。
///
/// 分工：协议层（`PlexApi` / `JellyfinApi`）的请求漏斗在**传输失败**（请求没到达
/// 服务器）时调一次 [MediaServerRouteFailoverHook]，钩子在这台服务器已存的其它线路里
/// 探测、写回、失效清单缓存（app 侧按服务器共享、单飞的
/// `MediaServerRouteFailover`），返回新的根地址；协议层换掉自己的根地址后把这一次
/// 请求重试一遍（[MediaServerRouteState.run]）。浏览、浏览起播、起播详情、播放期的
/// 元数据请求都走这一处，不在各页面各自 catch 了再换。
library;

/// 当前线路 [failedBaseUrl] 上的请求以 [error] 失败之后，问这台服务器该换哪条线路：
/// 返回新的根地址（已确认可达、是同一台）；不该换 / 没有别的可达线路时返回 null。
typedef MediaServerRouteFailoverHook =
    Future<String?> Function(String failedBaseUrl, Object error);

/// 播放器手里的流在播放途中断了（media_kit 在片尾之前就报 EOF）。没有 Dart 侧的
/// 传输异常可交，播放页拿它当 [MediaServerRouteFailoverHook] 的 error：两套协议的
/// 「这条线路不通」判据（`isPlexTransportFailure` / `isJellyfinTransportFailure`）都
/// 认它，换不换仍由探测结果定——当前线路其实还通（流断是别的原因）时不换。
class MediaServerStreamInterrupted implements Exception {
  const MediaServerStreamInterrupted();

  @override
  String toString() => 'MediaServerStreamInterrupted';
}

/// 一个协议客户端实例的「当前根地址」+ 换线路状态。
///
/// [baseUrl] 可变：换线路后同一个客户端实例直接改走新线路（浏览页 / 播放页手里的
/// 那只客户端不用重建，之后现拼的封面 / 流 / 字幕 URL 都带新 host）。换过的旧根地址
/// 记在 [_formerBases]，交进来的旧 URL（列表里早先拼好的封面）经 [rebase] 改写。
class MediaServerRouteState {
  MediaServerRouteState(this._baseUrl, {this.hook});

  String _baseUrl;

  /// 换线路钩子；null = 不自动换（探测用的一次性客户端、测试）。
  final MediaServerRouteFailoverHook? hook;

  final List<String> _formerBases = <String>[];

  /// 当前请求走的根地址（归一化：含 scheme、无尾斜杠）。
  String get baseUrl => _baseUrl;

  /// [url] 以本实例用过的旧根地址开头时改成当前根地址；其余原样返回。
  String rebase(String url) {
    for (final String former in _formerBases) {
      if (former == _baseUrl) continue;
      if (url == former ||
          url.startsWith('$former/') ||
          url.startsWith('$former?')) {
        return '$_baseUrl${url.substring(former.length)}';
      }
    }
    return url;
  }

  /// 当前线路以 [error] 失败后问钩子换线路；换成功（新根地址与当前不同）返回 true，
  /// 并把当前根地址改成新的。没有钩子 / 钩子说不换 / 钩子自己抛错都返回 false。
  Future<bool> failover(Object error) async {
    final MediaServerRouteFailoverHook? h = hook;
    if (h == null) return false;
    final String failed = _baseUrl;
    String? next;
    try {
      next = await h(failed, error);
    } on Object {
      return false;
    }
    if (next == null || next.isEmpty || next == failed) return false;
    // 等钩子期间别的请求已经把本实例换走了：以先换的为准，不来回改。
    if (_baseUrl != failed) return true;
    if (!_formerBases.contains(failed)) _formerBases.add(failed);
    _formerBases.remove(next);
    _baseUrl = next;
    return true;
  }

  /// 跑一次请求 [attempt]（每次调用都按**当前**根地址现拼 URL）；以
  /// [isTransportFailure] 认定的错误失败、且换线路成功时，在新线路上重试**一次**，
  /// 第二次的结果（含异常）原样交出。其余异常原样抛。
  Future<T> run<T>(
    Future<T> Function() attempt, {
    required bool Function(Object error) isTransportFailure,
  }) async {
    try {
      return await attempt();
    } on Object catch (error) {
      if (hook == null || !isTransportFailure(error)) rethrow;
      if (!await failover(error)) rethrow;
      return attempt();
    }
  }
}
