/// 播放项 → 服务器曲目（播放上报、服务器歌词用）。
///
/// 播放项不带服务器侧身份，只有 uid 与流地址（从服务器页直接播、从曲库 / 本地歌单里的
/// 服务器曲目（v149）播、从「最近播放」重播都一样）。这里按当前配置的服务器逐台问
/// [MusicServerStreamIdentity.streamRefOf] 认流地址，再用 [musicServerTrackUid] 核对 uid：
/// 两台同类服务器的流地址同形也不会认错，网络音乐来源（WebDAV 等）的 http 地址 uid 对不上，
/// 一律不认。
library;

import 'package:fushi_engine/media/music/server/music_server.dart';

/// 认出来的服务器曲目。
class MusicServerTrackRef {
  const MusicServerTrackRef({required this.browser, required this.stream});

  final MusicServerBrowser browser;
  final MusicServerStreamRef stream;

  String get trackId => stream.trackId;
}

/// 值不值得去问服务器：uid 在服务器曲目命名空间（`srv` 前缀）且路径是 http(s) 流地址
/// （YouTube 内置音源同用 `srv` 前缀，但路径是 `fushi-music-youtube://` 占位）。
bool musicServerTrackCandidate(String trackUid, String path) =>
    trackUid.startsWith('srv') &&
    (path.startsWith('http://') || path.startsWith('https://'));

/// 纯函数：在 [browsers] 里找播放项（[trackUid] + [path]）所在的那台服务器与曲目。
MusicServerTrackRef? musicServerTrackRefOf({
  required String trackUid,
  required String path,
  required Iterable<MusicServerBrowser> browsers,
}) {
  if (!musicServerTrackCandidate(trackUid, path)) return null;
  final Uri? uri = Uri.tryParse(path);
  if (uri == null) return null;
  for (final MusicServerBrowser b in browsers) {
    if (b is! MusicServerStreamIdentity) continue;
    final MusicServerStreamRef? ref = (b as MusicServerStreamIdentity)
        .streamRefOf(uri);
    if (ref == null) continue;
    if (musicServerTrackUid(b.serverId, ref.trackId) == trackUid) {
      return MusicServerTrackRef(browser: b, stream: ref);
    }
  }
  return null;
}

/// 带缓存的解析器：服务器列表（[load]，读配置、新建客户端）只在第一次、缓存里认不出、或
/// 调用方报告失败（[invalidate]：令牌换了 / 服务器删了）时重读。
class MusicServerTrackResolver {
  MusicServerTrackResolver(this._load);

  final Future<List<MusicServerBrowser>> Function() _load;
  List<MusicServerBrowser>? _cache;

  /// 正在读的那一次（同时来的几次解析共用，不各建一套客户端）。
  Future<List<MusicServerBrowser>>? _loading;

  Future<MusicServerTrackRef?> resolve({
    required String trackUid,
    required String path,
  }) async {
    if (!musicServerTrackCandidate(trackUid, path)) return null;
    final List<MusicServerBrowser>? cached = _cache;
    if (cached != null) {
      final MusicServerTrackRef? hit = musicServerTrackRefOf(
        trackUid: trackUid,
        path: path,
        browsers: cached,
      );
      if (hit != null) return hit;
    }
    final Future<List<MusicServerBrowser>> loading = _loading ??= _load();
    final List<MusicServerBrowser> fresh;
    try {
      fresh = await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
    _cache = fresh;
    return musicServerTrackRefOf(
      trackUid: trackUid,
      path: path,
      browsers: fresh,
    );
  }

  /// 下次解析时重读服务器配置。
  void invalidate() {
    _cache = null;
    _loading = null;
  }
}
