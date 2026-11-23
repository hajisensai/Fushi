/// 播放项 → 当前配置的服务器与服务器侧曲目（播放上报、服务器歌词、「正在播放」的收藏、
/// 最近播放重建的项补身份）。
///
/// 服务器曲目的身份只有一种：[MusicServerTrackRef]（播放项的 `serverTrack`：服务器页、曲库 /
/// 本地歌单里的服务器曲目（v149）、离线副本（v172）建的项都带）。按顺序认：
/// 1. 播放项自带的 [MusicServerTrackRef]；
/// 2. 离线副本索引（[musicServerLocalCopyLookup]，按 uid 查到行里的服务器身份 + 条目 id）：
///    只给了 uid + 本机路径的调用方（歌词解析）、路径是离线副本的旧项用；
/// 3. 没带身份、路径是服务器流地址的旧项（最近播放快照重建的）：按当前配置的服务器逐台问
///    [MusicServerStreamIdentity.streamRefOf] 认流地址。
///
/// 三种都再用 [musicServerTrackUid] 核对 uid：两台同类服务器、别的服务器的同形地址都不会认错；
/// 网络音乐来源（WebDAV 等）的 http 地址、YouTube 内置音源（同用 `srv` 前缀，但路径是
/// `fushi-music-youtube://` 占位）一律不认。
library;

import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show
        MusicServerLocalCopy,
        MusicServerLocalCopyLookup,
        musicServerLocalCopyLookup;

/// 认出来的服务器曲目：这台设备上配置着的那台服务器 + 曲目身份。
class MusicServerResolvedTrack {
  const MusicServerResolvedTrack({
    required this.browser,
    required this.ref,
    this.transcoded = false,
  });

  final MusicServerBrowser browser;
  final MusicServerTrackRef ref;

  /// 这次播放的是服务器转码流（上报的 `PlayMethod` 据此）；离线副本 / 原样直出为 false。
  final bool transcoded;

  String get trackId => ref.trackId;
}

bool _isHttp(String path) =>
    path.startsWith('http://') || path.startsWith('https://');

/// 本机文件路径（不是任何 `scheme://` 地址）。
bool _isLocalPath(String path) =>
    path.isNotEmpty && !RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]+://').hasMatch(path);

/// 值不值得去认：带着身份，或 uid 在服务器曲目命名空间（`srv` 前缀）且路径是 http(s) 流地址 /
/// 本机文件（离线副本）。
bool musicServerTrackCandidate(
  String trackUid,
  String path, {
  MusicServerTrackRef? serverTrack,
}) =>
    serverTrack != null ||
    (trackUid.startsWith('srv') && (_isHttp(path) || _isLocalPath(path)));

/// [browser] 自己发出的这条流是不是转码流（认不出按原样直出）。
bool _transcodedStream(MusicServerBrowser browser, String path) {
  if (!_isHttp(path) || browser is! MusicServerStreamIdentity) return false;
  final Uri? uri = Uri.tryParse(path);
  if (uri == null) return false;
  return (browser as MusicServerStreamIdentity).streamRefOf(uri)?.transcoded ??
      false;
}

/// 纯函数：在 [browsers] 里找播放项（[trackUid] + [path] + 自带的 [serverTrack]）所在的那台
/// 服务器与曲目。[localCopies] 缺省进程级 [musicServerLocalCopyLookup]。
MusicServerResolvedTrack? musicServerResolveTrack({
  required String trackUid,
  required String path,
  MusicServerTrackRef? serverTrack,
  required Iterable<MusicServerBrowser> browsers,
  MusicServerLocalCopyLookup? localCopies,
}) {
  if (!musicServerTrackCandidate(trackUid, path, serverTrack: serverTrack)) {
    return null;
  }
  ({String serverId, String trackId})? id = serverTrack == null
      ? null
      : (serverId: serverTrack.serverId, trackId: serverTrack.trackId);
  if (id == null) {
    final MusicServerLocalCopy? local =
        (localCopies ?? musicServerLocalCopyLookup)?.call(trackUid);
    if (local != null) id = (serverId: local.serverId, trackId: local.trackId);
  }
  if (id != null) {
    if (musicServerTrackUid(id.serverId, id.trackId) != trackUid) return null;
    for (final MusicServerBrowser b in browsers) {
      if (b.serverId != id.serverId) continue;
      if (serverTrack != null && b.kind != serverTrack.kind) return null;
      return MusicServerResolvedTrack(
        browser: b,
        ref:
            serverTrack ??
            MusicServerTrackRef(
              kind: b.kind,
              serverId: b.serverId,
              trackId: id.trackId,
            ),
        transcoded: _transcodedStream(b, path),
      );
    }
    return null;
  }
  if (!_isHttp(path)) return null;
  final Uri? uri = Uri.tryParse(path);
  if (uri == null) return null;
  for (final MusicServerBrowser b in browsers) {
    if (b is! MusicServerStreamIdentity) continue;
    final MusicServerStreamRef? s = (b as MusicServerStreamIdentity)
        .streamRefOf(uri);
    if (s == null) continue;
    if (musicServerTrackUid(b.serverId, s.trackId) == trackUid) {
      return MusicServerResolvedTrack(
        browser: b,
        ref: MusicServerTrackRef(
          kind: b.kind,
          serverId: b.serverId,
          trackId: s.trackId,
        ),
        transcoded: s.transcoded,
      );
    }
  }
  return null;
}

/// 带缓存的解析器：服务器列表（[load]，读配置、新建客户端）只在第一次、缓存里认不出、或
/// 调用方报告失败（[invalidate]：令牌换了 / 服务器删了）时重读。
class MusicServerTrackResolver {
  MusicServerTrackResolver(
    this._load, {
    MusicServerLocalCopyLookup? localCopies,
  }) : _localCopies = localCopies;

  final Future<List<MusicServerBrowser>> Function() _load;
  final MusicServerLocalCopyLookup? _localCopies;
  List<MusicServerBrowser>? _cache;

  /// 正在读的那一次（同时来的几次解析共用，不各建一套客户端）。
  Future<List<MusicServerBrowser>>? _loading;

  Future<MusicServerResolvedTrack?> resolve({
    required String trackUid,
    required String path,
    MusicServerTrackRef? serverTrack,
  }) async {
    if (!musicServerTrackCandidate(trackUid, path, serverTrack: serverTrack)) {
      return null;
    }
    MusicServerResolvedTrack? of(List<MusicServerBrowser> browsers) =>
        musicServerResolveTrack(
          trackUid: trackUid,
          path: path,
          serverTrack: serverTrack,
          browsers: browsers,
          localCopies: _localCopies,
        );
    final List<MusicServerBrowser>? cached = _cache;
    if (cached != null) {
      final MusicServerResolvedTrack? hit = of(cached);
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
    return of(fresh);
  }

  /// 播放项 → 认出来的服务器曲目。
  Future<MusicServerResolvedTrack?> resolveItem(MusicPlayItem item) => resolve(
    trackUid: item.trackUid,
    path: item.path,
    serverTrack: item.serverTrack,
  );

  /// 没带服务器身份的播放项（最近播放快照重建的）补上身份；本来就带着、或认不出的原样回。
  Future<MusicPlayItem> withIdentity(MusicPlayItem item) async {
    if (item.serverTrack != null) return item;
    final MusicServerResolvedTrack? r = await resolveItem(item);
    return r == null ? item : item.withServerTrack(r.ref);
  }

  /// 下次解析时重读服务器配置。
  void invalidate() {
    _cache = null;
    _loading = null;
  }
}
