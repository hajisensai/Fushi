/// Jellyfin（含 Emby / 飞牛等 MediaBrowser 兼容层）音乐条目的 JSON 解析与请求参数（纯函数，
/// 离线 fixture 可测）。HTTP 传输在 app 侧复用视频的 `JellyfinApi`（认证头双发、DeviceId、
/// 超时与凭据脱敏都在那一份里），这里只管「请求什么、怎么读回来」。
library;

import 'package:fushi_engine/media/music/server/music_server.dart';

/// Jellyfin 的 `RunTimeTicks` 是 100 ns。
int? jellyfinTicksToMs(Object? ticks) => ticks is num ? ticks ~/ 10000 : null;

String? _str(Object? v) {
  if (v is! String) return null;
  final String t = v.trim();
  return t.isEmpty ? null : t;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

List<Map<String, Object?>> _maps(Object? v) => <Map<String, Object?>>[
  if (v is List<Object?>)
    for (final Object? e in v)
      if (e is Map<String, Object?>) e,
];

bool _hasPrimary(Map<String, Object?> j) {
  final Object? tags = j['ImageTags'];
  return tags is Map<String, Object?> && tags['Primary'] != null;
}

/// 一页条目（`Items` + `TotalRecordCount`）。
List<Map<String, Object?>> jellyfinItemsOf(Object? json) =>
    json is Map<String, Object?>
    ? _maps(json['Items'])
    : const <Map<String, Object?>>[];

int? jellyfinTotalOf(Object? json) =>
    json is Map<String, Object?> ? _int(json['TotalRecordCount']) : null;

/// `CollectionType == music` 的媒体库视图 id。
List<String> jellyfinMusicLibraryIds(Object? viewsJson) => <String>[
  for (final Map<String, Object?> v in jellyfinItemsOf(viewsJson))
    if ((_str(v['CollectionType']) ?? '').toLowerCase() == 'music')
      ?_str(v['Id']),
];

MusicServerAlbum? parseJellyfinMusicAlbum(Map<String, Object?> j) {
  final String? id = _str(j['Id']);
  if (id == null) return null;
  final List<Map<String, Object?>> artists = _maps(j['AlbumArtists']);
  return MusicServerAlbum(
    id: id,
    title: _str(j['Name']) ?? '',
    artist:
        _str(j['AlbumArtist']) ??
        (artists.isEmpty ? null : _str(artists.first['Name'])),
    artistId: artists.isEmpty ? null : _str(artists.first['Id']),
    year: _int(j['ProductionYear']),
    trackCount: _int(j['ChildCount']) ?? _int(j['SongCount']),
    durationMs: jellyfinTicksToMs(j['RunTimeTicks']),
    coverRef: _hasPrimary(j) ? id : null,
  );
}

MusicServerArtist? parseJellyfinMusicArtist(Map<String, Object?> j) {
  final String? id = _str(j['Id']);
  final String? name = _str(j['Name']);
  if (id == null || name == null) return null;
  return MusicServerArtist(
    id: id,
    name: name,
    albumCount: _int(j['AlbumCount']),
    coverRef: _hasPrimary(j) ? id : null,
  );
}

MusicServerTrack? parseJellyfinMusicTrack(Map<String, Object?> j) {
  final String? id = _str(j['Id']);
  if (id == null) return null;
  Map<String, Object?>? audio;
  for (final Map<String, Object?> s in _maps(j['MediaStreams'])) {
    if (_str(s['Type']) == 'Audio') {
      audio = s;
      break;
    }
  }
  final List<Map<String, Object?>> sources = _maps(j['MediaSources']);
  final Map<String, Object?>? source = sources.isEmpty ? null : sources.first;
  if (audio == null && source != null) {
    for (final Map<String, Object?> s in _maps(source['MediaStreams'])) {
      if (_str(s['Type']) == 'Audio') {
        audio = s;
        break;
      }
    }
  }
  final List<String> artists = <String>[
    for (final Object? a
        in (j['Artists'] is List<Object?>
            ? j['Artists']! as List<Object?>
            : const <Object?>[]))
      if (_str(a) case final String s) s,
  ];
  final int? bitrate = _int(audio?['BitRate']) ?? _int(source?['Bitrate']);
  final String? albumId = _str(j['AlbumId']);
  return MusicServerTrack(
    id: id,
    title: _str(j['Name']) ?? '',
    artist: artists.isEmpty ? _str(j['AlbumArtist']) : artists.join(', '),
    album: _str(j['Album']),
    albumId: albumId,
    discNo: _int(j['ParentIndexNumber']),
    trackNo: _int(j['IndexNumber']),
    durationMs: jellyfinTicksToMs(j['RunTimeTicks']),
    container: (_str(j['Container']) ?? _str(source?['Container']))
        ?.toLowerCase(),
    codec: _str(audio?['Codec'])?.toLowerCase(),
    bitrateKbps: bitrate == null ? null : (bitrate / 1000).round(),
    sampleRate: _int(audio?['SampleRate']),
    bitDepth: _int(audio?['BitDepth']),
    channels: _int(audio?['Channels']),
    sizeBytes: _int(source?['Size']),
    coverRef: _hasPrimary(j)
        ? id
        : (_str(j['AlbumPrimaryImageTag']) != null ? albumId : null),
  );
}

/// 曲目按碟号 → 轨号 → 标题排（服务器排序参数在兼容层上不保证生效）。
List<MusicServerTrack> sortMusicServerTracks(
  Iterable<MusicServerTrack> tracks,
) {
  int cmp(int? a, int? b) {
    if (a == b) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  return tracks.toList()..sort((MusicServerTrack a, MusicServerTrack b) {
    final int d = cmp(a.discNo, b.discNo);
    if (d != 0) return d;
    final int n = cmp(a.trackNo, b.trackNo);
    if (n != 0) return n;
    return a.title.compareTo(b.title);
  });
}

/// 专辑排序 → Jellyfin `SortBy` / `SortOrder`。
({String sortBy, String sortOrder}) jellyfinAlbumSort(
  MusicServerAlbumSort sort,
) => switch (sort) {
  MusicServerAlbumSort.name => (sortBy: 'SortName', sortOrder: 'Ascending'),
  MusicServerAlbumSort.newest => (
    sortBy: 'DateCreated,SortName',
    sortOrder: 'Descending',
  ),
  MusicServerAlbumSort.artist => (
    sortBy: 'AlbumArtist,SortName',
    sortOrder: 'Ascending',
  ),
  MusicServerAlbumSort.year => (
    sortBy: 'ProductionYear,SortName',
    sortOrder: 'Descending',
  ),
};

/// `/Audio/{id}/universal` 声明本机 mpv 能直接解码的容器：在这个清单里、且不超码率上限的
/// 源由服务器原样直出，否则服务器转码成 [codec]（mpv 解码能力是统一 FFmpeg，几乎全收）。
const String kJellyfinMusicDirectContainers =
    'flac,alac,mp3,aac,m4a,m4b,opus,ogg,oga,webma,webm,wav,wv,ape,dsf,dff,aiff,mka';

/// 播放流的路径与参数（[token] 放 query：mpv 没有头通道）。
({String path, Map<String, String> query, bool transcoded})
jellyfinMusicStreamRequest({
  required String trackId,
  required String userId,
  required String deviceId,
  required String token,
  int? maxBitrateKbps,
  String codec = 'opus',
}) {
  if (maxBitrateKbps == null) {
    return (
      path: '/Audio/$trackId/stream',
      query: <String, String>{
        'static': 'true',
        'DeviceId': deviceId,
        'api_key': token,
      },
      transcoded: false,
    );
  }
  return (
    path: '/Audio/$trackId/universal',
    query: <String, String>{
      'UserId': userId,
      'DeviceId': deviceId,
      'api_key': token,
      'MaxStreamingBitrate': '${maxBitrateKbps * 1000}',
      'Container': kJellyfinMusicDirectContainers,
      'TranscodingContainer': 'ogg',
      'TranscodingProtocol': 'http',
      'AudioCodec': codec,
    },
    transcoded: true,
  );
}
