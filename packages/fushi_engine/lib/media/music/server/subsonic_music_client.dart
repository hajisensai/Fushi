/// OpenSubsonic / Subsonic 音乐库客户端（`MusicServerBrowser` 的 Subsonic 实现）。
///
/// 浏览 + 播放：getAlbumList2 / getAlbum / getArtists / getArtist / getPlaylists /
/// getPlaylist / search3 / stream / getCoverArt；收藏（star / unstar / getStarred2）、流派与
/// 统计（getGenres / getSongsByGenre / getAlbumList2）、即时混音（getSimilarSongs）、播放上报
/// （scrobble）、歌词（OpenSubsonic getLyricsBySongId）。认证走 token 方式（`u` + `s` 盐 + `t = md5(password + salt)`，每个请求
/// 一个新盐，**从不发明文 `p=`**），或 OpenSubsonic `apiKeyAuthentication` 扩展的
/// `apiKey`（此时不发 u/t/s）。
///
/// 凭据只能放 query（mpv 拉流没有头通道），所以：异常文本里的 URL 一律经
/// [redactCredentialsInText] 脱敏，[SubsonicApiException.toString] 不含任何凭据。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// Subsonic 协议版本（OpenSubsonic 1.16.1）。
const String kSubsonicApiVersion = '1.16.1';

/// 客户端标识（`c` 参数）。
const String kSubsonicClientName = 'fushi';

/// getAlbumList2 单页上限（协议规定 500）。
const int _kMaxAlbumPage = 500;

/// 通用凭据脱敏之外，再脱 Subsonic 的 token（`t`）与盐（`s`）：共享清单
/// （`kCredentialQueryParams`）没有这两个短名，而 `t` + `s` 足以离线爆破密码。
String redactSubsonicCredentials(String text) =>
    redactCredentialsInText(text).replaceAllMapped(
      RegExp(
        r'([?&])(t|s)=([^&\s"'
        "'"
        r'<>)]+)',
      ),
      (Match m) => '${m.group(1)}${m.group(2)}=$kRedactedPlaceholder',
    );

/// 服务器返回的 API 错误（HTTP 非 2xx，或 `subsonic-response.status == failed`）。
class SubsonicApiException implements Exception {
  const SubsonicApiException({
    this.httpStatus,
    this.code,
    required this.message,
  });

  /// HTTP 状态码（协议层错误时为 null）。
  final int? httpStatus;

  /// Subsonic 错误码（40 = 凭据错误、70 = 数据不存在 …；HTTP 层错误时为 null）。
  final int? code;

  final String message;

  @override
  String toString() {
    final List<String> parts = <String>[
      if (httpStatus != null) 'http $httpStatus',
      if (code != null) 'code $code',
    ];
    final String where = parts.isEmpty ? '' : ' (${parts.join(', ')})';
    return 'SubsonicApiException$where: ${redactSubsonicCredentials(message)}';
  }
}

/// 单个请求的响应超时（流媒体本身不经这里：流地址交给 mpv）。
const Duration kSubsonicRequestTimeout = Duration(seconds: 15);

class SubsonicMusicClient
    implements
        MusicServerBrowser,
        MusicServerDownloading,
        MusicServerFavoriteEditing,
        MusicServerDiscovery,
        MusicServerInstantMix,
        MusicServerPlaybackReporting,
        MusicServerPlayMarking,
        MusicServerLyricsProvider,
        MusicServerLoudnessLookup {
  SubsonicMusicClient(
    SubsonicServerConfig config, {
    http.Client? client,
    String Function()? saltSource,
  }) : _config = config,
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _saltSource = saltSource ?? _randomSalt;

  final SubsonicServerConfig _config;
  final http.Client _client;
  final bool _ownsClient;
  final String Function() _saltSource;

  static final Random _random = Random.secure();

  static String _randomSalt() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 6; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  @override
  MusicServerKind get kind => MusicServerKind.subsonic;

  @override
  String get serverId => _config.serverId;

  @override
  String get displayName => _config.displayName;

  // ---------------------------------------------------------------- 认证 / URL

  /// 每个请求的公共 query：版本 / 客户端 / 格式 + 认证。每次调用现算新盐。
  Map<String, String> _authParams() {
    final Map<String, String> p = <String, String>{
      'v': kSubsonicApiVersion,
      'c': kSubsonicClientName,
      'f': 'json',
    };
    final String? key = _config.apiKey;
    if (key != null && key.isNotEmpty) {
      p['apiKey'] = key;
      return p;
    }
    final String salt = _saltSource();
    p['u'] = _config.username;
    p['s'] = salt;
    p['t'] = md5
        .convert(utf8.encode('${_config.password ?? ''}$salt'))
        .toString();
    return p;
  }

  Uri _methodUri(String method, [Map<String, String> extra = const {}]) {
    final Uri base = _config.serverUrl;
    return base.replace(
      path: '${base.path}/rest/$method',
      queryParameters: <String, String>{..._authParams(), ...extra},
    );
  }

  // ---------------------------------------------------------------- 请求

  /// 发请求并拆出 `subsonic-response` 对象；失败抛。
  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, String> extra = const {},
  ]) async {
    final Uri uri = _methodUri(method, extra);
    final http.Response res;
    try {
      // 响应超时与视频的 JellyfinApi 同口径：服务器 TCP 可连但不回响应（NAS 半死 / 反代挂起）
      // 时连接超时完全不触发，页面会永远转圈。
      res = await _client.get(uri).timeout(kSubsonicRequestTimeout);
    } on http.ClientException catch (e) {
      // ClientException.message 常带完整 URL（含凭据 query）。
      throw http.ClientException(redactSubsonicCredentials(e.message));
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SubsonicApiException(
        httpStatus: res.statusCode,
        message: 'HTTP ${res.statusCode} from $method',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    } on FormatException {
      throw FormatException('Subsonic $method returned a non-JSON response');
    }
    final Object? inner = decoded is Map<String, Object?>
        ? decoded['subsonic-response']
        : null;
    if (inner is! Map<String, Object?>) {
      throw FormatException('Subsonic $method has no subsonic-response');
    }
    final Object? status = inner['status'];
    if (status == 'ok') return inner;
    final Object? err = inner['error'];
    if (err is Map<String, Object?>) {
      throw SubsonicApiException(
        code: _int(err['code']),
        message: (err['message'] as String?) ?? 'Subsonic error',
      );
    }
    throw SubsonicApiException(message: 'Subsonic $method failed');
  }

  /// 设置页「测试连接」：凭据 / 地址不对会抛。
  Future<void> ping() => _call('ping');

  /// 服务器支持的 OpenSubsonic 扩展名集合。服务器不支持（纯 Subsonic 返回错误 / 404）
  /// 时返回空集合，不抛。
  Future<Set<String>> openSubsonicExtensions() async {
    final Map<String, Object?> r;
    try {
      r = await _call('getOpenSubsonicExtensions');
    } on SubsonicApiException {
      return <String>{};
    }
    return <String>{
      for (final Map<String, Object?> e in _maps(r['openSubsonicExtensions']))
        if (e['name'] is String) e['name']! as String,
    };
  }

  // ---------------------------------------------------------------- 响度

  /// 从音乐库 / 歌单还原的曲目（行里不存响度）起播时补查：`getSong` 的 OpenSubsonic
  /// `replayGain`。纯 Subsonic 服务器没有这一项，回 null。
  @override
  Future<MusicServerLoudness?> loudnessOf(MusicServerTrackRef track) async {
    final Map<String, Object?> r = await _call('getSong', <String, String>{
      'id': track.trackId,
    });
    return parseOpenSubsonicReplayGain(_obj(r['song'])?['replayGain']);
  }

  // ---------------------------------------------------------------- 浏览

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async {
    final int size = limit.clamp(1, _kMaxAlbumPage);
    final Map<String, String> extra = <String, String>{
      'type': switch (sort) {
        MusicServerAlbumSort.name => 'alphabeticalByName',
        MusicServerAlbumSort.newest => 'newest',
        MusicServerAlbumSort.artist => 'alphabeticalByArtist',
        MusicServerAlbumSort.year => 'byYear',
      },
      if (sort == MusicServerAlbumSort.year) ...<String, String>{
        'fromYear': '0',
        'toYear': '9999',
      },
      'size': '$size',
      'offset': '$offset',
    };
    final Map<String, Object?> r = await _call('getAlbumList2', extra);
    final List<MusicServerAlbum> items = <MusicServerAlbum>[
      for (final Map<String, Object?> a in _maps(
        _obj(r['albumList2'])?['album'],
      ))
        _album(a),
    ];
    return MusicServerPage<MusicServerAlbum>(
      items: items,
      nextOffset: items.length >= size ? offset + size : null,
    );
  }

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async {
    final Map<String, Object?> r = await _call('getAlbum', <String, String>{
      'id': albumId,
    });
    final List<MusicServerTrack> tracks = <MusicServerTrack>[
      for (final Map<String, Object?> s in _maps(_obj(r['album'])?['song']))
        _track(s),
    ];
    // 稳定排序：List.sort 不稳定，带原序号兜底。
    final List<int> order = List<int>.generate(tracks.length, (int i) => i);
    order.sort((int a, int b) {
      final MusicServerTrack x = tracks[a];
      final MusicServerTrack y = tracks[b];
      final int disc = (x.discNo ?? 1).compareTo(y.discNo ?? 1);
      if (disc != 0) return disc;
      final int no = (x.trackNo ?? 1 << 30).compareTo(y.trackNo ?? 1 << 30);
      return no != 0 ? no : a.compareTo(b);
    });
    return <MusicServerTrack>[for (final int i in order) tracks[i]];
  }

  @override
  Future<List<MusicServerArtist>> listArtists() async {
    final Map<String, Object?> r = await _call('getArtists');
    return <MusicServerArtist>[
      for (final Map<String, Object?> index in _maps(
        _obj(r['artists'])?['index'],
      ))
        for (final Map<String, Object?> a in _maps(index['artist'])) _artist(a),
    ];
  }

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async {
    final Map<String, Object?> r = await _call('getArtist', <String, String>{
      'id': artistId,
    });
    return <MusicServerAlbum>[
      for (final Map<String, Object?> a in _maps(_obj(r['artist'])?['album']))
        _album(a),
    ];
  }

  /// `getPlaylists` 协议上不分页：一次全取，再在内存里按 [offset] / [limit] 切片。
  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async {
    final Map<String, Object?> r = await _call('getPlaylists');
    final List<MusicServerPlaylist> all = <MusicServerPlaylist>[
      for (final Map<String, Object?> p in _maps(
        _obj(r['playlists'])?['playlist'],
      ))
        _playlist(p),
    ];
    final int start = offset.clamp(0, all.length);
    final int end = (start + (limit < 1 ? 1 : limit)).clamp(start, all.length);
    return MusicServerPage<MusicServerPlaylist>(
      items: all.sublist(start, end),
      nextOffset: end < all.length ? end : null,
      total: all.length,
    );
  }

  /// 歌单曲目：`getPlaylist` 的 `entry` 原样顺序（不按碟号 / 轨号重排）。
  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async {
    final Map<String, Object?> r = await _call('getPlaylist', <String, String>{
      'id': playlistId,
    });
    return <MusicServerTrack>[
      for (final Map<String, Object?> s in _maps(_obj(r['playlist'])?['entry']))
        // 子目录 / 视频条目放不了：只留非目录、非视频的曲目。
        if (s['isDir'] != true && s['isVideo'] != true) _track(s),
    ];
  }

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    final String q = query.trim();
    if (q.isEmpty) return const MusicServerSearchResult();
    final Map<String, Object?> r = await _call('search3', <String, String>{
      'query': q,
      'artistCount': '$limit',
      'albumCount': '$limit',
      'songCount': '$limit',
    });
    final Map<String, Object?>? s = _obj(r['searchResult3']);
    return MusicServerSearchResult(
      albums: <MusicServerAlbum>[
        for (final Map<String, Object?> a in _maps(s?['album'])) _album(a),
      ],
      artists: <MusicServerArtist>[
        for (final Map<String, Object?> a in _maps(s?['artist'])) _artist(a),
      ],
      tracks: <MusicServerTrack>[
        for (final Map<String, Object?> t in _maps(s?['song'])) _track(t),
      ],
    );
  }

  // ---------------------------------------------------------------- 收藏

  /// `star` / `unstar`：曲目用 `id`，专辑 `albumId`，艺人 `artistId`（ID3 模型）。
  @override
  Future<void> setFavorite(
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  }) => _call(favorite ? 'star' : 'unstar', <String, String>{
    switch (kind) {
      MusicServerItemKind.track => 'id',
      MusicServerItemKind.album => 'albumId',
      MusicServerItemKind.artist => 'artistId',
    }: id,
  });

  @override
  Future<bool?> trackFavorite(String trackId) async {
    final Map<String, Object?> r = await _call('getSong', <String, String>{
      'id': trackId,
    });
    final Map<String, Object?>? song = _obj(r['song']);
    return song == null ? null : _starred(song);
  }

  /// `getStarred2` 不分页：一次全取，各组截到 [limit]。
  @override
  Future<MusicServerItems> listFavorites({
    int limit = kMusicServerPageSize,
  }) async {
    final Map<String, Object?> r = await _call('getStarred2');
    final Map<String, Object?>? s = _obj(r['starred2']);
    return MusicServerItems(
      albums: <MusicServerAlbum>[
        for (final Map<String, Object?> a in _maps(s?['album']).take(limit))
          _album(a),
      ],
      artists: <MusicServerArtist>[
        for (final Map<String, Object?> a in _maps(s?['artist']).take(limit))
          _artist(a),
      ],
      tracks: <MusicServerTrack>[
        for (final Map<String, Object?> t in _maps(s?['song']).take(limit))
          _track(t),
      ],
    );
  }

  // ---------------------------------------------------------------- 流派 / 统计

  /// Subsonic 的流派没有 id：[MusicServerGenre.id] 就是流派名。
  @override
  Future<List<MusicServerGenre>> listGenres() async {
    final Map<String, Object?> r = await _call('getGenres');
    final List<MusicServerGenre> out = <MusicServerGenre>[
      for (final Map<String, Object?> g in _maps(_obj(r['genres'])?['genre']))
        if (_str(g['value']) case final String name)
          MusicServerGenre(
            id: name,
            name: name,
            albumCount: _int(g['albumCount']),
            trackCount: _int(g['songCount']),
          ),
    ];
    return out..sort(
      (MusicServerGenre a, MusicServerGenre b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  @override
  Future<List<MusicServerAlbum>> genreAlbums(
    MusicServerGenre genre, {
    int limit = kMusicServerPageSize,
  }) => _albumList('byGenre', limit, <String, String>{'genre': genre.id});

  @override
  Future<List<MusicServerTrack>> genreTracks(
    MusicServerGenre genre, {
    int limit = kMusicServerPageSize,
  }) async {
    final Map<String, Object?> r = await _call(
      'getSongsByGenre',
      <String, String>{'genre': genre.id, 'count': '${limit.clamp(1, 500)}'},
    );
    return <MusicServerTrack>[
      for (final Map<String, Object?> s in _maps(
        _obj(r['songsByGenre'])?['song'],
      ))
        _track(s),
    ];
  }

  @override
  Future<List<MusicServerAlbum>> recentlyAddedAlbums({int limit = 30}) =>
      _albumList('newest', limit);

  /// Subsonic 只按专辑统计播放（`frequent`）。
  @override
  Future<MusicServerItems> mostPlayed({int limit = 30}) async =>
      MusicServerItems(albums: await _albumList('frequent', limit));

  @override
  Future<MusicServerItems> recentlyPlayed({int limit = 30}) async =>
      MusicServerItems(albums: await _albumList('recent', limit));

  Future<List<MusicServerAlbum>> _albumList(
    String type,
    int limit, [
    Map<String, String> extra = const <String, String>{},
  ]) async {
    final Map<String, Object?> r = await _call(
      'getAlbumList2',
      <String, String>{
        'type': type,
        'size': '${limit.clamp(1, _kMaxAlbumPage)}',
        ...extra,
      },
    );
    return <MusicServerAlbum>[
      for (final Map<String, Object?> a in _maps(
        _obj(r['albumList2'])?['album'],
      ))
        _album(a),
    ];
  }

  // ---------------------------------------------------------------- 即时混音

  /// `getSimilarSongs` 认曲目 / 专辑 / 艺人 id（服务器没接 Last.fm 等相似度来源时为空）。
  @override
  Future<List<MusicServerTrack>> instantMix(
    MusicServerItemKind kind,
    String id, {
    int limit = 50,
  }) async {
    final Map<String, Object?> r = await _call(
      'getSimilarSongs',
      <String, String>{'id': id, 'count': '$limit'},
    );
    return <MusicServerTrack>[
      for (final Map<String, Object?> s in _maps(
        _obj(r['similarSongs'])?['song'],
      ))
        _track(s),
    ];
  }

  // ---------------------------------------------------------------- 播放上报

  /// [streamFor] 拼的 `…/rest/stream?id=…`（`format=raw` 直出，否则请求了转码）。
  @override
  MusicServerStreamRef? streamRefOf(Uri uri) {
    final List<String> seg = uri.pathSegments;
    if (seg.length < 2) return null;
    final String method = seg.last.toLowerCase();
    if (seg[seg.length - 2].toLowerCase() != 'rest' ||
        (method != 'stream' && method != 'stream.view')) {
      return null;
    }
    final String? id = uri.queryParameters['id'];
    if (id == null || id.isEmpty) return null;
    final String format = uri.queryParameters['format'] ?? 'raw';
    return MusicServerStreamRef(trackId: id, transcoded: format != 'raw');
  }

  /// 开播：`scrobble submission=false`（「正在播放」，不计次数）。
  @override
  Future<void> reportPlaybackStarted(MusicServerPlaybackReport report) => _call(
    'scrobble',
    <String, String>{'id': report.trackId, 'submission': 'false'},
  );

  /// Subsonic 没有进度上报。
  @override
  Future<void> reportPlaybackProgress(
    MusicServerPlaybackReport report, {
    MusicServerPlaybackEvent? event,
  }) async {}

  /// 停止：听够门槛（[musicScrobbleThresholdReached]）才 `scrobble submission=true`
  /// 提交一次播放（`time` = 开播时刻），否则什么都不发。
  @override
  Future<void> reportPlaybackStopped(MusicServerPlaybackReport report) async {
    if (!musicScrobbleThresholdReached(report.positionMs, report.durationMs)) {
      return;
    }
    await _call('scrobble', <String, String>{
      'id': report.trackId,
      'time': '${report.startedAtMs}',
      'submission': 'true',
    });
  }

  /// 补记离线时的一次播放：`scrobble time=<开播毫秒> submission=true`。
  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) async {
    await _call('scrobble', <String, String>{
      'id': trackId,
      'time': '${playedAt.millisecondsSinceEpoch}',
      'submission': 'true',
    });
  }

  /// Subsonic 在停止时听够门槛才 `submission=true`（[reportPlaybackStopped]）。
  @override
  bool get countsPlayOnStart => false;

  // ---------------------------------------------------------------- 歌词

  /// OpenSubsonic `songLyrics` 扩展的 `getLyricsBySongId`：取第一份同步歌词，没有同步的取
  /// 第一份。服务器不支持（纯 Subsonic：错误码 / 404）或这首没有歌词回 null。
  @override
  Future<MusicServerLyrics?> lyricsFor(String trackId) async {
    final Map<String, Object?> r;
    try {
      r = await _call('getLyricsBySongId', <String, String>{'id': trackId});
    } on SubsonicApiException catch (e) {
      // 不支持的方法：HTTP 404 / 501，或协议层错误（code 0 通用、70 不存在）。
      final bool unsupported = e.httpStatus == 404 || e.httpStatus == 501;
      final bool noData =
          e.httpStatus == null &&
          (e.code == null || e.code == 0 || e.code == 70);
      if (unsupported || noData) {
        return null;
      }
      rethrow;
    }
    final List<Map<String, Object?>> all = _maps(
      _obj(r['lyricsList'])?['structuredLyrics'],
    );
    if (all.isEmpty) return null;
    final Map<String, Object?> pick = all.firstWhere(
      (Map<String, Object?> l) => l['synced'] == true,
      orElse: () => all.first,
    );
    final bool synced = pick['synced'] == true;
    final int offset = _int(pick['offset']) ?? 0;
    final List<MusicServerLyricLine> lines = <MusicServerLyricLine>[
      for (final Map<String, Object?> l in _maps(pick['line']))
        MusicServerLyricLine(
          text: '${l['value'] ?? ''}'.trimRight(),
          startMs: synced && _int(l['start']) != null
              // OpenSubsonic：offset 为正 = 歌词提前显示（与 LRC `[offset:]` 同号）。
              ? (_int(l['start'])! - offset).clamp(0, 1 << 31)
              : null,
        ),
    ];
    if (lines.every((MusicServerLyricLine l) => l.text.trim().isEmpty)) {
      return null;
    }
    return MusicServerLyrics(lines: lines);
  }

  // ---------------------------------------------------------------- 播放 / 封面

  /// 注意：服务器不支持转码时会无视 `format` / `maxBitRate` 原样返回，所以带码率上限
  /// 时 [MusicServerStream.transcoded] 只表示「请求了转码」，界面应标注为「请求转码」
  /// 而不是断言实际输出已转码。
  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) {
    if (maxBitrateKbps == null) {
      return MusicServerStream(
        uri: _methodUri('stream', <String, String>{
          'id': track.id,
          'format': 'raw',
        }),
        transcoded: false,
        codec: track.codec ?? track.container,
        bitrateKbps: track.bitrateKbps,
      );
    }
    return MusicServerStream(
      uri: _methodUri('stream', <String, String>{
        'id': track.id,
        'format': 'opus',
        'maxBitRate': '$maxBitrateKbps',
      }),
      transcoded: true,
      codec: 'opus',
      bitrateKbps: maxBitrateKbps,
    );
  }

  /// 原文件（`download`：不转码，无视码率上限；需要账号有下载权限，没有时服务器回错误）。
  @override
  MusicServerDownloadSource downloadSourceFor(MusicServerTrack track) =>
      MusicServerDownloadSource(
        uri: _methodUri('download', <String, String>{'id': track.id}),
        extensionHint: (track.container ?? track.codec)?.toLowerCase(),
      );

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) {
    if (coverRef == null || coverRef.isEmpty) return null;
    return _methodUri('getCoverArt', <String, String>{
      'id': coverRef,
      'size': '$size',
    });
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------- 映射

  MusicServerAlbum _album(Map<String, Object?> a) {
    final int? durationSec = _int(a['duration']);
    return MusicServerAlbum(
      id: '${a['id']}',
      title: (a['name'] as String?) ?? (a['title'] as String?) ?? '',
      artist: a['artist'] as String?,
      artistId: a['artistId'] == null ? null : '${a['artistId']}',
      year: _int(a['year']),
      trackCount: _int(a['songCount']),
      durationMs: durationSec == null ? null : durationSec * 1000,
      coverRef: _str(a['coverArt']),
      favorite: _starred(a),
    );
  }

  /// `starred`（收藏时刻）在 = 收藏了；Subsonic 只在收藏了时才带这个字段，不带就是没收藏。
  static bool _starred(Map<String, Object?> j) => _str(j['starred']) != null;

  MusicServerArtist _artist(Map<String, Object?> a) => MusicServerArtist(
    id: '${a['id']}',
    name: (a['name'] as String?) ?? '',
    albumCount: _int(a['albumCount']),
    coverRef: _str(a['coverArt']),
    favorite: _starred(a),
  );

  MusicServerPlaylist _playlist(Map<String, Object?> p) {
    final int? durationSec = _int(p['duration']);
    final String? owner = _str(p['owner']);
    final String comment = '${p['comment'] ?? ''}'.trim();
    return MusicServerPlaylist(
      id: '${p['id']}',
      title: (p['name'] as String?) ?? '',
      description: comment.isEmpty ? null : comment,
      curator: owner,
      trackCount: _int(p['songCount']),
      durationMs: durationSec == null ? null : durationSec * 1000,
      coverRef: _str(p['coverArt']),
      // Subsonic 只有歌单所有者能改歌单（apiKey 模式不知道用户名，一律视为不可改）。
      editable:
          owner != null &&
          _config.username.isNotEmpty &&
          owner == _config.username,
    );
  }

  MusicServerTrack _track(Map<String, Object?> s) {
    final int? durationSec = _int(s['duration']);
    final String? suffix = _str(s['suffix'])?.toLowerCase();
    final String? codec =
        _str(s['codec'])?.toLowerCase() ??
        suffix ??
        _codecFromContentType(_str(s['contentType']));
    return MusicServerTrack(
      id: '${s['id']}',
      title: (s['title'] as String?) ?? '',
      artist: s['artist'] as String?,
      album: s['album'] as String?,
      albumId: s['albumId'] == null ? null : '${s['albumId']}',
      discNo: _int(s['discNumber']),
      trackNo: _int(s['track']),
      durationMs: durationSec == null ? null : durationSec * 1000,
      container: suffix,
      codec: codec,
      bitrateKbps: _int(s['bitRate']),
      sampleRate: _int(s['samplingRate']),
      bitDepth: _int(s['bitDepth']),
      channels: _int(s['channelCount']),
      sizeBytes: _int(s['size']),
      coverRef: _str(s['coverArt']),
      favorite: _starred(s),
      loudness: parseOpenSubsonicReplayGain(s['replayGain']),
    );
  }

  static String? _codecFromContentType(String? contentType) {
    if (contentType == null) return null;
    final int slash = contentType.indexOf('/');
    String sub = (slash < 0 ? contentType : contentType.substring(slash + 1))
        .toLowerCase()
        .split(';')
        .first
        .trim();
    if (sub.startsWith('x-')) sub = sub.substring(2);
    return switch (sub) {
      '' => null,
      'mpeg' => 'mp3',
      'mp4' => 'aac',
      _ => sub,
    };
  }

  // ---------------------------------------------------------------- JSON 辅助

  static Map<String, Object?>? _obj(Object? v) =>
      v is Map<String, Object?> ? v : null;

  /// Subsonic JSON 里「单个对象」有时被序列化成对象而非数组：两种都吃。
  static List<Map<String, Object?>> _maps(Object? v) {
    if (v is Map<String, Object?>) return <Map<String, Object?>>[v];
    if (v is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? e in v)
        if (e is Map<String, Object?>) e,
    ];
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    final String s = '$v';
    return s.isEmpty ? null : s;
  }
}
