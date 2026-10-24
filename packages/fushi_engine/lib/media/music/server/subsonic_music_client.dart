/// OpenSubsonic / Subsonic 音乐库客户端（`MusicServerBrowser` 的 Subsonic 实现）。
///
/// 只读浏览 + 播放：getAlbumList2 / getAlbum / getArtists / getArtist / search3 / stream /
/// getCoverArt。认证走 token 方式（`u` + `s` 盐 + `t = md5(password + salt)`，每个请求
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

class SubsonicMusicClient implements MusicServerBrowser {
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
      res = await _client.get(uri);
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
    );
  }

  MusicServerArtist _artist(Map<String, Object?> a) => MusicServerArtist(
    id: '${a['id']}',
    name: (a['name'] as String?) ?? '',
    albumCount: _int(a['albumCount']),
    coverRef: _str(a['coverArt']),
  );

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
