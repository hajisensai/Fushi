/// 互联共享音乐库的 client 侧（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §5）：
/// 已配对、能力位带 `music.v >= 1` 的 host 作为一台「音乐服务器」（[MusicServerKind.fushiHost]）
/// 出现在服务器列表里，浏览 / 搜索 / 歌单编辑 / 歌词 / MV 都转给 host 的
/// `package:fushi_engine/sync/music_library_host_module.dart`。
///
/// - 曲目 id 就是 host 的 `track_uid`，播放身份同它（design-imusic-q1 选 a）：本机的播放记录、
///   断点、歌词偏移与 host 同键。
/// - 播放路径是占位 `fushi-host-music:///<serverId>/<trackUid>`（[fushiHostMusicTrackPath]），
///   起播时才向 host 签统一流票（[InterconnectMusicHosts.openTrackPath]）；票只留最近几张，
///   更早的主动释放（host 侧还有 6 小时 TTL 与 128 张上限兜底）。
/// - 封面占位 `fushi-host-music-cover:///<serverId>/<ref>`，经同一条钉扎通道取字节
///   （[fushiHostMusicCoverProvider]）。
/// - 修改写回 host（design-imusic-q3 选 c：歌单编辑、歌词偏移 / 换来源、MV 微调）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/painting.dart' show ImageProvider;
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:fushi_engine/sync/remote_music_dto.dart';

/// host 的一次 HTTP 回答。[resolve] 把 host 给的路径拼成本次实际走的那条地址上的绝对 URL。
typedef InterconnectMusicResponse = ({
  int status,
  Uint8List bytes,
  Map<String, Object?>? json,
  Uri? Function(String path, Map<String, String> query) resolve,

  /// 这次走的地址钉扎的证书指纹（https 自签的 host）；明文 / 没有钉扎为 null。在通道之外直接取
  /// host 给的地址（离线副本下载）时，按它钉扎证书。
  String? pin,
});

/// 没有任何地址给出 HTTP 回答（离线 / 不可达 / 证书不符 / 凭据被拒）。
final class InterconnectMusicUnreachable implements Exception {
  const InterconnectMusicUnreachable(this.code);

  final String code;

  @override
  String toString() => 'InterconnectMusicUnreachable($code)';
}

/// host 给了非 2xx 的回答。
final class InterconnectMusicHostError implements Exception {
  const InterconnectMusicHostError(this.status, this.path);

  final int status;
  final String path;

  @override
  String toString() => 'InterconnectMusicHostError($status $path)';
}

/// 一台 host 的请求传输（生产实现 [ChannelInterconnectMusicTransport]；测试注入替身）。
abstract interface class InterconnectMusicTransport {
  Future<InterconnectMusicResponse> send(
    String method,
    String path, {
    Map<String, String> query,
    Object? json,
    required Duration timeout,
  });

  void close();
}

/// 经 [InterconnectHostChannel]（选路、per-peer 凭据、证书钉扎、整段超时）发请求。
class ChannelInterconnectMusicTransport implements InterconnectMusicTransport {
  ChannelInterconnectMusicTransport(this._channel);

  final InterconnectHostChannel _channel;

  @override
  Future<InterconnectMusicResponse> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Object? json,
    required Duration timeout,
  }) async {
    final InterconnectChannelResponse res;
    try {
      res = await _channel.send(
        method,
        path,
        query: query,
        body: json == null ? null : InterconnectRequestBody.json(json),
        timeout: timeout,
      );
    } on InterconnectChannelException catch (e) {
      throw InterconnectMusicUnreachable(e.code);
    } on InterconnectPinRefused {
      throw const InterconnectMusicUnreachable('certificate_mismatch');
    }
    return (
      status: res.statusCode,
      bytes: res.bodyBytes,
      json: res.jsonObject?.cast<String, Object?>(),
      resolve: (String p, Map<String, String> q) =>
          interconnectRequestUri(res.via.url, p, q),
      pin: res.via.fingerprintSha256,
    );
  }

  @override
  void close() => _channel.close();
}

/// 一首 host 曲目起播时签到的流：[url] 交给播放器；CUE 虚拟曲目带起止（毫秒）。
typedef InterconnectMusicOpenedTrack = ({String url, int? startMs, int? endMs});

/// 一台 host 的音乐库，按 [MusicServerBrowser] 接进服务器页 / 混排 / 远程曲目。
///
/// 实例由 [InterconnectMusicHosts] 按 host 持有、跨页面复用（服务器页每次「新建浏览器」拿到的是
/// 同一个实例），所以 [close] 不关传输：传输随 host 从配对表消失时由 [InterconnectMusicHosts]
/// 关（[dispose]）。
class InterconnectMusicBrowser
    implements
        MusicServerBrowser,
        MusicServerPlaylistEditing,
        MusicServerLyricsSource,
        MusicServerVideoSource,
        MusicServerDownloading,
        MusicServerCoverBytes {
  InterconnectMusicBrowser({
    required this.serverId,
    required this.displayName,
    required InterconnectMusicTransport transport,
    this.timeout = const Duration(seconds: 15),
    int? Function()? maxBitrateKbps,
    this.canMatchVideos = false,
    @visibleForTesting DateTime Function()? now,
  }) : _transport = transport,
       _maxBitrateKbps = maxBitrateKbps ?? _noLimit,
       _now = now ?? DateTime.now;

  static int? _noLimit() => null;

  /// 这台 host 能不能接受远程 MV 匹配 / 绑定（能力位 `videoMatch`，design-imusic-q9）。
  final bool canMatchVideos;

  /// 设置里的码率上限（null = 原样直出）。签票时带给 host，host 按源码率决定转不转（design-imusic-q6）。
  final int? Function() _maxBitrateKbps;

  @override
  MusicServerKind get kind => MusicServerKind.fushiHost;

  /// 配对身份（[InterconnectHostRef.key]）：换 IP 不变，换对端 / 重新配对会变。
  @override
  final String serverId;

  @override
  final String displayName;

  /// 单次请求（建连 → 读完响应体）的上限。
  final Duration timeout;

  final InterconnectMusicTransport _transport;
  final DateTime Function() _now;

  /// 起播签到、还没释放的曲目票（旧 → 新）。
  final List<String> _trackTickets = <String>[];

  /// 同时留着的曲目票数：当前曲 + 预载的下一首 + 一张余量（快速切歌时上一首可能还在收尾）。
  static const int kHeldTrackTickets = 3;

  @visibleForTesting
  List<String> get heldTrackTickets => List<String>.unmodifiable(_trackTickets);

  // ── 浏览 ──

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async {
    final RemoteMusicPage<RemoteMusicAlbum> page =
        RemoteMusicPage.fromJson<RemoteMusicAlbum>(
          await _getJson(
            'albums',
            query: <String, String>{
              'offset': '$offset',
              'limit': '$limit',
              'sort': sort.name,
            },
          ),
          RemoteMusicAlbum.fromJson,
        );
    return MusicServerPage<MusicServerAlbum>(
      items: page.items.map(_album).toList(growable: false),
      nextOffset: page.nextOffset,
      total: page.total,
    );
  }

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async =>
      _tracks(await _getJson('albums/${_seg(albumId)}/tracks'));

  @override
  Future<List<MusicServerArtist>> listArtists() async {
    final List<MusicServerArtist> out = <MusicServerArtist>[];
    int? offset = 0;
    while (offset != null) {
      final RemoteMusicPage<RemoteMusicArtist> page =
          RemoteMusicPage.fromJson<RemoteMusicArtist>(
            await _getJson(
              'artists',
              query: <String, String>{
                'offset': '$offset',
                'limit': '$kRemoteMusicPageLimit',
              },
            ),
            RemoteMusicArtist.fromJson,
          );
      out.addAll(page.items.map(_artist));
      // host 给的下一页必须前进，防止坏 host 把这里拖成死循环。
      final int? next = page.nextOffset;
      offset = next != null && next > offset ? next : null;
    }
    return out;
  }

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      RemoteMusicPage.fromJson<RemoteMusicAlbum>(
        await _getJson('artists/${_seg(artistId)}/albums'),
        RemoteMusicAlbum.fromJson,
      ).items.map(_album).toList(growable: false);

  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async {
    final RemoteMusicPage<RemoteMusicPlaylist> page =
        RemoteMusicPage.fromJson<RemoteMusicPlaylist>(
          await _getJson(
            'playlists',
            query: <String, String>{'offset': '$offset', 'limit': '$limit'},
          ),
          RemoteMusicPlaylist.fromJson,
        );
    return MusicServerPage<MusicServerPlaylist>(
      items: page.items.map(_playlist).toList(growable: false),
      nextOffset: page.nextOffset,
      total: page.total,
    );
  }

  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async =>
      _tracks(await _getJson('playlists/${_seg(playlistId)}/tracks'));

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    if (query.trim().isEmpty) return const MusicServerSearchResult();
    final RemoteMusicSearchResult r = RemoteMusicSearchResult.fromJson(
      await _getJson(
        'search',
        query: <String, String>{'q': query.trim(), 'limit': '$limit'},
      ),
    );
    return MusicServerSearchResult(
      albums: r.albums.map(_album).toList(growable: false),
      artists: r.artists.map(_artist).toList(growable: false),
      tracks: <MusicServerTrack>[
        for (final RemoteMusicTrack t in r.tracks)
          if (_playable(t)) _track(t),
      ],
      playlists: r.playlists.map(_playlist).toList(growable: false),
    );
  }

  /// 占位地址（起播时才签票，[InterconnectMusicHosts.openTrackPath]）。host 原样直出，不转码。
  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) =>
      MusicServerStream(
        uri: Uri.parse(fushiHostMusicTrackPath(serverId, track.id)),
        transcoded: false,
        codec: track.codec ?? track.container,
        bitrateKbps: track.bitrateKbps,
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) =>
      coverRef == null || coverRef.isEmpty
      ? null
      : Uri.parse(fushiHostMusicCoverPath(serverId, coverRef));

  /// 实例跨页面共享，页面关掉时不关传输（见类注释）。
  @override
  void close() {}

  /// 释放手里的票、关传输（host 从配对表消失 / 不再提供音乐库时由 [InterconnectMusicHosts] 调）。
  Future<void> dispose() async {
    final List<String> tickets = List<String>.of(_trackTickets);
    _trackTickets.clear();
    await Future.wait(<Future<void>>[
      for (final String t in tickets) _release(t),
    ]);
    _transport.close();
  }

  // ── 取流 ──

  /// 签一首曲目的流票（host 的 `track_uid`）。host 截好段（光盘 / CDDA / 转码，回 `segmentApplied`）时
  /// 流就是这一首；否则 CUE 虚拟曲目的起止取 host 的曲目行，由播放器拼 EDL 段。
  ///
  /// [forDownload]：下载到本机（design-imusic-q12）——原样音质（不带码率上限），且要「就是这一首」的
  /// 文件（CUE 虚拟曲目由 host 无损截段）。
  Future<InterconnectMusicOpenedTrack> openTrack(
    String trackUid, {
    bool forDownload = false,
  }) async => (await _open(trackUid, forDownload: forDownload)).opened;

  /// 离线副本下载（design-imusic-q12，与 Jellyfin / Subsonic 同一条离线副本管线）：原样音质、整首
  /// （CUE 虚拟曲目由 host 无损截段），每次开跑 / 续传现签一张票；地址在通道之外直接取，按这次
  /// 走的地址的证书指纹钉扎。
  @override
  Future<MusicServerDownloadSource> downloadSourceFor(
    MusicServerTrack track,
  ) async {
    final ({InterconnectMusicOpenedTrack opened, String? pin}) o = await _open(
      track.id,
      forDownload: true,
    );
    return MusicServerDownloadSource(
      uri: Uri.parse(o.opened.url),
      extensionHint: (track.container ?? track.codec)?.toLowerCase(),
      pinnedFingerprint: o.pin,
    );
  }

  Future<({InterconnectMusicOpenedTrack opened, String? pin})> _open(
    String trackUid, {
    required bool forDownload,
  }) async {
    final Future<Map<String, Object?>> meta = _getJson(
      'tracks/${_seg(trackUid)}',
    );
    final int? cap = forDownload ? null : _maxBitrateKbps();
    final ({Uri url, String ticket, Map<String, Object?> info, String? pin})
    stream = await _issue(
      LibraryMediaStreamKind.musicTrack,
      trackUid,
      options: <String, Object?>{
        kMusicStreamOptionMaxBitrate: ?cap,
        if (forDownload) kMusicStreamOptionSegment: true,
      },
    );
    final RemoteMusicTrack? track;
    try {
      track = RemoteMusicTrack.fromJson(await meta);
    } on Object {
      unawaited(_release(stream.ticket));
      rethrow;
    }
    // 下载的票不进播放的环（切几首歌就会把还在下的票释放掉）；由 host 的 TTL / 上限收。
    if (!forDownload) {
      _trackTickets.add(stream.ticket);
      while (_trackTickets.length > kHeldTrackTickets) {
        unawaited(_release(_trackTickets.removeAt(0)));
      }
    }
    final bool applied = stream.info['segmentApplied'] == true;
    return (
      opened: (
        url: stream.url.toString(),
        startMs: applied ? null : track?.cueStartMs,
        endMs: applied ? null : track?.cueEndMs,
      ),
      pin: stream.pin,
    );
  }

  Future<({Uri url, String ticket, Map<String, Object?> info, String? pin})>
  _issue(
    LibraryMediaStreamKind kind,
    String id, {
    Map<String, Object?>? options,
  }) async {
    final InterconnectMusicResponse res = await _transport.send(
      'POST',
      kLibraryMediaStreamUrlPath,
      json: <String, Object?>{
        'kind': kind.wireName,
        'id': id,
        if (options != null && options.isNotEmpty) 'options': options,
      },
      timeout: timeout,
    );
    _check(res, kLibraryMediaStreamUrlPath);
    final Map<String, Object?>? body = res.json;
    final Object? url = body?['url'];
    final Object? ticket = body?['ticket'];
    if (url is! String || ticket is! String) {
      throw const FormatException('streamurl: missing url / ticket');
    }
    // host 回的是它看到的请求地址；按本次实际走的地址重拼（中继 / 换路时 host 看到的不一定可达）。
    final Uri issued = Uri.parse(url);
    final Uri? resolved = res.resolve(issued.path, issued.queryParameters);
    if (resolved == null) throw const FormatException('streamurl: bad url');
    return (url: resolved, ticket: ticket, info: body!, pin: res.pin);
  }

  Future<void> _release(String ticket) async {
    try {
      await _transport.send(
        'POST',
        kLibraryMediaStreamReleasePath,
        query: <String, String>{'ticket': ticket},
        timeout: timeout,
      );
    } on Object catch (e) {
      // 释放是礼貌：host 侧有 TTL 与上限兜底，离线时放弃即可。
      debugPrint('[music-interconnect] release ticket failed: $e');
    }
  }

  // ── 封面 ──

  /// 封面字节（[coverRef] 来自曲目 / 专辑的 `coverRef`）。
  @override
  Future<Uint8List> coverBytes(String coverRef) async {
    final String path = '$kRemoteMusicRoutePrefix/covers/${_seg(coverRef)}';
    final InterconnectMusicResponse res = await _transport.send(
      'GET',
      path,
      timeout: timeout,
    );
    _check(res, path);
    return res.bytes;
  }

  // ── 歌单编辑（写回 host） ──

  @override
  Future<MusicServerPlaylist> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async {
    final RemoteMusicPlaylist? p = RemoteMusicPlaylist.fromJson(
      await _sendJson('POST', 'playlists', <String, Object?>{
        'name': name,
        'trackIds': trackIds,
      }),
    );
    if (p == null) throw const FormatException('playlist');
    return _playlist(p);
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) =>
      _sendJson(
        'POST',
        'playlists/${_seg(playlistId)}/tracks',
        <String, Object?>{'trackIds': trackIds},
      );

  @override
  Future<void> removeFromPlaylist(String playlistId, List<String> entryIds) =>
      _sendJson(
        'POST',
        'playlists/${_seg(playlistId)}/entries/remove',
        <String, Object?>{'entryIds': entryIds},
      );

  @override
  Future<void> movePlaylistEntry(
    String playlistId,
    String entryId,
    int newIndex,
  ) => _sendJson(
    'PUT',
    'playlists/${_seg(playlistId)}/entries/${_seg(entryId)}/position',
    <String, Object?>{'index': newIndex},
  );

  @override
  Future<void> renamePlaylist(String playlistId, String name) => _sendJson(
    'PUT',
    'playlists/${_seg(playlistId)}',
    <String, Object?>{'name': name},
  );

  @override
  Future<void> deletePlaylist(String playlistId) =>
      _sendJson('DELETE', 'playlists/${_seg(playlistId)}', null);

  // ── 歌词（host 上生效的那份；修改写回） ──

  @override
  Future<MusicHostLyrics?> lyricsFor(String trackId) async {
    final String path =
        '$kRemoteMusicRoutePrefix/tracks/${_seg(trackId)}/lyrics';
    final InterconnectMusicResponse res = await _transport.send(
      'GET',
      path,
      timeout: timeout,
    );
    if (res.status == 204 || res.status == 404) return null;
    _check(res, path);
    final Map<String, Object?>? body = res.json;
    final RemoteMusicLyrics? l = body == null
        ? null
        : RemoteMusicLyrics.fromJson(body);
    if (l == null) return null;
    return MusicHostLyrics(
      source: l.source,
      format: l.format,
      raw: l.raw,
      offsetMs: l.offsetMs,
      isUserEdited: l.isUserEdited,
    );
  }

  @override
  Future<void> setLyricsOffset(
    String trackId, {
    required String source,
    required int offsetMs,
  }) => _sendJson(
    'PUT',
    'tracks/${_seg(trackId)}/lyrics/offset',
    <String, Object?>{
      'source': source,
      'offsetMs': offsetMs,
      // host 按 updatedAt 后写为准（两台设备同时调时谁晚谁赢）。
      'updatedAt': _now().millisecondsSinceEpoch,
    },
  );

  @override
  Future<void> chooseLyrics(
    String trackId, {
    required String format,
    required List<int> raw,
    required int offsetMs,
  }) => _sendJson('PUT', 'tracks/${_seg(trackId)}/lyrics', <String, Object?>{
    'format': format,
    'raw': base64Encode(raw),
    'offsetMs': offsetMs,
  });

  // ── MV（host 上的绑定；画面按需签票取流） ──

  @override
  Future<List<MusicServerVideo>> videosFor(String trackId) async {
    final Map<String, Object?> body = await _getJson(
      'tracks/${_seg(trackId)}/videos',
    );
    final Object? items = body['items'];
    return <MusicServerVideo>[
      if (items is List)
        for (final Object? e in items)
          if (e is Map<String, Object?>)
            if (RemoteMusicVideo.fromJson(e) case final RemoteMusicVideo v)
              MusicServerVideo(
                id: '${v.videoId}',
                kind: v.kind,
                offsetMs: v.offsetMs,
                isUserBound: v.isUserBound,
                youtubeRef: v.youtubeRef,
                label: v.label,
              ),
    ];
  }

  /// 曲目本身是 MV 视频时（host 曲目的 `isVideo`），给歌词页背景另签一条「原样」的画面流：音频由引擎
  /// 那条流放（可能转了码），画面读同一个原文件，两条连接（design-imusic-q8 选 a）。[offsetMs] 是 MV 时刻
  /// 相对曲目时刻的偏移（CUE 曲目 = 起点）。不是视频回 null。
  Future<({MusicServerMediaLease lease, int offsetMs})?> openTrackPicture(
    String trackUid,
  ) async {
    final RemoteMusicTrack? t = RemoteMusicTrack.fromJson(
      await _getJson('tracks/${_seg(trackUid)}'),
    );
    if (t == null || !t.isVideo) return null;
    final ({Uri url, String ticket, Map<String, Object?> info, String? pin}) s =
        await _issue(LibraryMediaStreamKind.musicTrack, trackUid);
    return (lease: _lease(s), offsetMs: t.cueStartMs ?? 0);
  }

  MusicServerMediaLease _lease(
    ({Uri url, String ticket, Map<String, Object?> info, String? pin}) s,
  ) {
    bool released = false;
    return MusicServerMediaLease(
      uri: s.url,
      release: () async {
        if (released) return;
        released = true;
        await _release(s.ticket);
      },
    );
  }

  /// 请 host 重新找本机 MV（design-imusic-q9）。回这次绑上的个数。
  Future<int> rematchVideos(String trackId) async {
    final Map<String, Object?> body = await _sendJson(
      'POST',
      'tracks/${_seg(trackId)}/videos/rematch',
      null,
    );
    final Object? n = body['bound'];
    return n is int ? n : 0;
  }

  /// host 给的待确认 MV 候选（[RemoteMusicVideoCandidateSource]）。
  Future<List<RemoteMusicVideoCandidate>> videoCandidates(
    String trackId,
    String source,
  ) async {
    final Map<String, Object?> body = await _getJson(
      'tracks/${_seg(trackId)}/videos/candidates',
      query: <String, String>{'source': source},
    );
    final Object? items = body['items'];
    return <RemoteMusicVideoCandidate>[
      if (items is List)
        for (final Object? e in items)
          if (e is Map<String, Object?>)
            if (RemoteMusicVideoCandidate.fromJson(e)
                case final RemoteMusicVideoCandidate c)
              c,
    ];
  }

  /// 请 host 绑定选定的候选。
  Future<void> bindVideo(String trackId, RemoteMusicVideoCandidate candidate) =>
      _sendJson('POST', 'tracks/${_seg(trackId)}/videos', candidate.toJson());

  /// 请 host 解绑一条 MV。
  Future<void> unbindVideo(String trackId, MusicServerVideo video) => _sendJson(
    'DELETE',
    'tracks/${_seg(trackId)}/videos/${_seg(video.id)}',
    null,
  );

  @override
  Future<MusicServerMediaLease> openVideo(MusicServerVideo video) async {
    if (video.youtubeRef != null) {
      throw StateError('YouTube MV is played by the client YouTube source');
    }
    return _lease(await _issue(LibraryMediaStreamKind.musicVideo, video.id));
  }

  @override
  Future<void> setVideoOffset(MusicServerVideo video, int offsetMs) =>
      _sendJson('PUT', 'videos/${_seg(video.id)}/offset', <String, Object?>{
        'offsetMs': offsetMs,
        'updatedAt': _now().millisecondsSinceEpoch,
      });

  // ── 内部 ──

  static String _seg(String id) => Uri.encodeComponent(id);

  Future<Map<String, Object?>> _getJson(
    String route, {
    Map<String, String> query = const <String, String>{},
  }) async {
    final String path = '$kRemoteMusicRoutePrefix/$route';
    final InterconnectMusicResponse res = await _transport.send(
      'GET',
      path,
      query: query,
      timeout: timeout,
    );
    _check(res, path);
    final Map<String, Object?>? body = res.json;
    if (body == null) throw FormatException('$path: not a JSON object');
    return body;
  }

  Future<Map<String, Object?>> _sendJson(
    String method,
    String route,
    Object? json,
  ) async {
    final String path = '$kRemoteMusicRoutePrefix/$route';
    final InterconnectMusicResponse res = await _transport.send(
      method,
      path,
      json: json,
      timeout: timeout,
    );
    _check(res, path);
    return res.json ?? const <String, Object?>{};
  }

  static void _check(InterconnectMusicResponse res, String path) {
    if (res.status < 200 || res.status >= 300) {
      throw InterconnectMusicHostError(res.status, path);
    }
  }

  /// 这台 host 确实给不出字节的才不列（host 已经把网络来源 / 光盘 / CDDA 经自己给出，只剩无头服务端
  /// 没有网络来源解析器、非 Windows host 的 CDDA 这类）。曲目本身是 MV 视频的照常列：音频与画面
  /// 两条连接（design-imusic-q8 选 a）。
  static bool _playable(RemoteMusicTrack t) => t.unplayableReason == null;

  List<MusicServerTrack> _tracks(Map<String, Object?> body) {
    final Object? items = body['items'];
    return <MusicServerTrack>[
      if (items is List)
        for (final Object? e in items)
          if (e is Map<String, Object?>)
            if (RemoteMusicTrack.fromJson(e) case final RemoteMusicTrack t)
              // 这台 host 给不出字节的不列出，与服务器页「放不了的曲目不列出」一致。
              if (_playable(t)) _track(t),
    ];
  }

  static MusicServerTrack _track(RemoteMusicTrack t) => MusicServerTrack(
    id: t.id,
    title: t.title,
    artist: t.artist,
    album: t.album,
    albumId: t.albumId,
    discNo: t.discNo,
    trackNo: t.trackNo,
    durationMs: t.durationMs,
    container: t.container,
    codec: t.codec,
    bitrateKbps: t.bitrateKbps,
    sampleRate: t.sampleRate,
    bitDepth: t.bitDepth,
    channels: t.channels,
    sizeBytes: t.sizeBytes,
    coverRef: t.coverRef,
    playlistEntryId: t.playlistEntryId,
  );

  static MusicServerAlbum _album(RemoteMusicAlbum a) => MusicServerAlbum(
    id: a.id,
    title: a.title,
    artist: a.artist,
    artistId: a.artistId,
    year: a.year,
    trackCount: a.trackCount,
    durationMs: a.durationMs,
    coverRef: a.coverRef,
  );

  static MusicServerArtist _artist(RemoteMusicArtist a) => MusicServerArtist(
    id: a.id,
    name: a.name,
    albumCount: a.albumCount,
    coverRef: a.coverRef,
  );

  static MusicServerPlaylist _playlist(RemoteMusicPlaylist p) =>
      MusicServerPlaylist(
        id: p.id,
        title: p.title,
        trackCount: p.trackCount,
        durationMs: p.durationMs,
        coverRef: p.coverRef,
        editable: p.editable,
      );
}

/// 本机已配对 host 里提供音乐库的那些（按配对表顺序）。每台 host 一个 [InterconnectMusicBrowser]，
/// 跨页面复用；能力探测按 [cacheTtl] 缓存（服务器页 / 混排 / 起播都会问，不能每次都探每台 host）。
///
/// 进程级实例 [instance] 由 `AppModel` 建音乐会话时装上；起播（[openTrackPath]）与封面
/// （[fetchRemoteCover]）经它找到 host。
class InterconnectMusicHosts implements RemoteCoverFetcher {
  InterconnectMusicHosts(
    this._repository, {
    this.cacheTtl = const Duration(minutes: 1),
    this.probeTimeout = const Duration(seconds: 6),
    int? Function()? maxBitrateKbps,
    @visibleForTesting
    InterconnectMusicTransport Function(InterconnectHostRef host)?
    transportFactory,
    @visibleForTesting DateTime Function()? now,
  }) : _transportFactory = transportFactory,
       _maxBitrateKbps = maxBitrateKbps,
       _now = now ?? DateTime.now;

  final int? Function()? _maxBitrateKbps;

  /// 进程级装配点（`AppModel` 装）；未装配（测试 / 无头入口）时没有互联音乐库。
  static InterconnectMusicHosts? instance;

  final SyncRepository Function() _repository;
  final InterconnectMusicTransport Function(InterconnectHostRef host)?
  _transportFactory;
  final DateTime Function() _now;

  final Duration cacheTtl;
  final Duration probeTimeout;

  final Map<String, InterconnectMusicBrowser> _browsers =
      <String, InterconnectMusicBrowser>{};
  List<InterconnectMusicBrowser>? _available;
  DateTime? _probedAt;
  Future<List<InterconnectMusicBrowser>>? _probing;

  /// 提供音乐库的 host（能力位 `music.v >= 1`）。离线 / 关了互联 / 老版本的 host 不出现。
  Future<List<InterconnectMusicBrowser>> browsers({bool force = false}) {
    final DateTime? at = _probedAt;
    final List<InterconnectMusicBrowser>? cached = _available;
    if (!force &&
        cached != null &&
        at != null &&
        _now().difference(at) < cacheTtl) {
      return Future<List<InterconnectMusicBrowser>>.value(cached);
    }
    return _probing ??= _probe().whenComplete(() => _probing = null);
  }

  /// [serverId] 那台 host 的浏览器；先看缓存，没有再探一次。
  Future<InterconnectMusicBrowser?> browserFor(String serverId) async {
    for (final InterconnectMusicBrowser b in _available ?? const []) {
      if (b.serverId == serverId) return b;
    }
    for (final InterconnectMusicBrowser b in await browsers(force: true)) {
      if (b.serverId == serverId) return b;
    }
    return null;
  }

  /// 起播：占位路径 → 签好票的流地址（+ CUE 起止）。host 不在 / 不再提供音乐库时抛
  /// [InterconnectMusicUnreachable]，走播放器既有的播放失败路径。
  Future<InterconnectMusicOpenedTrack> openTrackPath(String path) async {
    final ({String hostId, String trackUid})? id = parseFushiHostMusicTrackPath(
      path,
    );
    if (id == null) throw ArgumentError.value(path, 'path');
    final InterconnectMusicBrowser? b = await browserFor(id.hostId);
    if (b == null) throw const InterconnectMusicUnreachable('no_host');
    return b.openTrack(id.trackUid);
  }

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    final ({String hostId, String trackUid})? id = parseFushiHostMusicCoverPath(
      coverUrl,
    );
    if (id == null) throw ArgumentError.value(coverUrl, 'coverUrl');
    final InterconnectMusicBrowser? b = await browserFor(id.hostId);
    if (b == null) throw const InterconnectMusicUnreachable('no_host');
    return b.coverBytes(id.trackUid);
  }

  /// 封面占位里已经带着 serverId（配对身份），命名空间只需区分来源种类。
  @override
  String get coverCacheNamespace => 'fushi-host-music';

  Future<List<InterconnectMusicBrowser>> _probe() async {
    final SyncRepository repo = _repository();
    final List<FushiClientUrl> rows = await repo.getFushiClientUrls();
    final List<InterconnectHostRef> hosts = interconnectPairedHostRefs(rows);
    final List<InterconnectMusicBrowser?> found = await Future.wait(
      <Future<InterconnectMusicBrowser?>>[
        for (final InterconnectHostRef h in hosts) _probeHost(repo, rows, h),
      ],
    );
    final List<InterconnectMusicBrowser> available = <InterconnectMusicBrowser>[
      for (final InterconnectMusicBrowser? b in found) ?b,
    ];
    // 从配对表消失的 host：释放票、关传输。探测失败（离线）的留着实例，下次在线时复用。
    final Set<String> paired = <String>{
      for (final InterconnectHostRef h in hosts) h.key,
    };
    for (final String key in _browsers.keys.toList()) {
      if (!paired.contains(key)) unawaited(_browsers.remove(key)!.dispose());
    }
    _available = available;
    _probedAt = _now();
    return available;
  }

  Future<InterconnectMusicBrowser?> _probeHost(
    SyncRepository repo,
    List<FushiClientUrl> rows,
    InterconnectHostRef host,
  ) async {
    final String label = interconnectHostLabel(rows, host);
    final InterconnectMusicTransport Function(InterconnectHostRef)? factory =
        _transportFactory;
    if (factory != null) {
      // 测试：替身传输直接问能力位。
      final InterconnectMusicTransport t = factory(host);
      final Map<String, Object?>? music;
      try {
        final InterconnectMusicResponse res = await t.send(
          'GET',
          '/api/capabilities',
          timeout: probeTimeout,
        );
        music = _musicCaps(res.json);
        if (music == null) {
          t.close();
          return null;
        }
      } on Object {
        t.close();
        return null;
      }
      return _browsers.putIfAbsent(
        host.key,
        () => InterconnectMusicBrowser(
          serverId: host.key,
          displayName: label,
          transport: t,
          maxBitrateKbps: _maxBitrateKbps,
          canMatchVideos: music!['videoMatch'] == true,
        ),
      );
    }
    final InterconnectHostChannel channel = InterconnectHostChannel(
      repo: repo,
      host: host,
    );
    final InterconnectCapabilityOutcome<Map<String, Object?>> outcome =
        await probeInterconnectCapability<Map<String, Object?>>(
          channel,
          label: label,
          timeout: probeTimeout,
          parse: (Map<String, dynamic> caps, FushiClientUrl via) =>
              _musicCaps(caps.cast<String, Object?>()),
        );
    if (outcome is! InterconnectCapabilityAvailable<Map<String, Object?>>) {
      channel.close();
      return null;
    }
    final bool canMatchVideos = outcome.target['videoMatch'] == true;
    final InterconnectMusicBrowser? existing = _browsers[host.key];
    if (existing != null) {
      channel.close();
      return existing;
    }
    return _browsers[host.key] = InterconnectMusicBrowser(
      serverId: host.key,
      displayName: label,
      transport: ChannelInterconnectMusicTransport(channel),
      maxBitrateKbps: _maxBitrateKbps,
      canMatchVideos: canMatchVideos,
    );
  }

  /// 能力位里的音乐对象（`v >= 1` 才算提供音乐库）；不提供为 null。
  static Map<String, Object?>? _musicCaps(Map<String, Object?>? caps) {
    final Object? music = caps?[kRemoteMusicCapability];
    if (music is! Map) return null;
    final Object? v = music['v'];
    return v is int && v >= 1 ? music.cast<String, Object?>() : null;
  }

  /// 关掉全部 host 的传输（进程收尾 / 测试）。
  Future<void> dispose() async {
    final List<InterconnectMusicBrowser> all = _browsers.values.toList();
    _browsers.clear();
    _available = null;
    await Future.wait(<Future<void>>[
      for (final InterconnectMusicBrowser b in all) b.dispose(),
    ]);
  }
}

/// 互联 host 封面占位 → 经钉扎通道取图的 provider；不是这种占位 / 没装配时回 null。
ImageProvider? fushiHostMusicCoverProvider(String? coverPath) {
  final InterconnectMusicHosts? hosts = InterconnectMusicHosts.instance;
  if (hosts == null || coverPath == null) return null;
  if (parseFushiHostMusicCoverPath(coverPath) == null) return null;
  return RemoteCoverImage(coverPath, hosts, cacheKey: coverPath);
}

/// 歌词服务的互联 host 层：按播放占位找到 host，转给它的歌词路由。
class InterconnectMusicHostLyrics implements MusicHostLyricsLayer {
  const InterconnectMusicHostLyrics(this._hosts);

  final InterconnectMusicHosts? Function() _hosts;

  @override
  bool handles(String path) =>
      _hosts() != null && parseFushiHostMusicTrackPath(path) != null;

  Future<({InterconnectMusicBrowser browser, String trackUid})?> _target(
    String path,
  ) async {
    final InterconnectMusicHosts? hosts = _hosts();
    final ({String hostId, String trackUid})? id = parseFushiHostMusicTrackPath(
      path,
    );
    if (hosts == null || id == null) return null;
    final InterconnectMusicBrowser? b = await hosts.browserFor(id.hostId);
    return b == null ? null : (browser: b, trackUid: id.trackUid);
  }

  @override
  Future<MusicHostLyrics?> lyricsFor(String path) async {
    final ({InterconnectMusicBrowser browser, String trackUid})? t =
        await _target(path);
    return t?.browser.lyricsFor(t.trackUid);
  }

  @override
  Future<void> setLyricsOffset(
    String path, {
    required String source,
    required int offsetMs,
  }) async {
    final ({InterconnectMusicBrowser browser, String trackUid})? t =
        await _target(path);
    await t?.browser.setLyricsOffset(
      t.trackUid,
      source: source,
      offsetMs: offsetMs,
    );
  }

  @override
  Future<void> chooseLyrics(
    String path, {
    required String format,
    required List<int> raw,
    required int offsetMs,
  }) async {
    final ({InterconnectMusicBrowser browser, String trackUid})? t =
        await _target(path);
    await t?.browser.chooseLyrics(
      t.trackUid,
      format: format,
      raw: raw,
      offsetMs: offsetMs,
    );
  }
}
