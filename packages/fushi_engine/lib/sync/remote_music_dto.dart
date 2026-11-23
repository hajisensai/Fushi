/// 互联共享音乐库的 wire（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §4.2）。
///
/// 路由全在模块前缀 [kRemoteMusicRoutePrefix] 下（Basic + 已配对 peer），形状对齐客户端的
/// `MusicServerBrowser`：列表一律分页（`offset` / `limit`，上限 [kRemoteMusicPageLimit]）。曲目 id 就是
/// host 的 `track_uid`（拍板 design-imusic-q1 选 a：客户端播放身份直接用 host uid）。
///
/// 只出 host 本机能读到字节的曲目；放不了的照视频的 `peerPlayable` 惯例标出原因（[RemoteMusicTrack.
/// unplayableReason]），不静默消失。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 模块的路由前缀与能力键。
const String kRemoteMusicRoutePrefix = '/api/library/music';
const String kRemoteMusicCapability = 'music';

/// 能力值的版本。客户端只认 `v >= 1`。
const int kRemoteMusicWireVersion = 1;

/// 单页上限（= 客户端 `kMusicServerPageSize`）。
const int kRemoteMusicPageLimit = 100;

/// 能力位里 `writeback` 列出的回写种类（拍板 design-imusic-q3：照合集的做法，客户端上的修改写回 host）。
/// `musicTrack` 签票参数（`streamurl` 的 `options`）里的码率上限（kbps，design-imusic-q6）。
const String kMusicStreamOptionMaxBitrate = 'maxBitrateKbps';

/// `musicTrack` 签票参数：要「就是这一首」的文件（CUE 虚拟曲目也由 host 无损截好段，下载到本机用，
/// design-imusic-q12）。
const String kMusicStreamOptionSegment = 'segment';

abstract final class RemoteMusicWriteback {
  /// `PUT …/tracks/<uid>/lyrics/offset`：整首歌词偏移。
  static const String lyricsOffset = 'lyricsOffset';

  /// `PUT …/tracks/<uid>/lyrics`：换歌词来源（客户端选定 / 导入的一份写成 host 上的手动指定）。
  static const String lyricsChoice = 'lyricsChoice';

  /// `PUT …/videos/<id>/offset`：MV 对齐微调。
  static const String videoOffset = 'videoOffset';

  /// `POST/PUT/DELETE …/playlists…`：host 歌单的新建 / 加歌 / 删条目 / 重排 / 改名 / 删除。
  static const String playlists = 'playlists';

  static const List<String> all = <String>[
    lyricsOffset,
    lyricsChoice,
    videoOffset,
    playlists,
  ];
}

/// 曲目放不了的原因（wire 值冻结）。
abstract final class RemoteMusicUnplayable {
  /// 音频 CD：实时读光驱，无法区间串流。
  static const String cdda = 'cdda';

  /// 光盘标题（DVD / 蓝光整盘按标题入库）：要接盘共享会话。
  static const String discTitle = 'discTitle';

  /// host 上的网络来源曲目（SFTP / WebDAV / AList）：host 没接中继读取器。
  static const String networkSource = 'networkSource';
}

/// 一页。
class RemoteMusicPage<T> {
  const RemoteMusicPage({required this.items, this.nextOffset, this.total});

  final List<T> items;
  final int? nextOffset;
  final int? total;

  Map<String, Object?> toJson(Map<String, Object?> Function(T) encode) =>
      <String, Object?>{
        'items': <Map<String, Object?>>[for (final T i in items) encode(i)],
        'nextOffset': ?nextOffset,
        'total': ?total,
      };

  static RemoteMusicPage<T> fromJson<T>(
    Map<String, Object?> json,
    T? Function(Map<String, Object?>) decode,
  ) {
    final Object? raw = json['items'];
    return RemoteMusicPage<T>(
      items: <T>[
        if (raw is List)
          for (final Object? e in raw)
            if (e is Map<String, Object?>) ?decode(e),
      ],
      nextOffset: _int(json['nextOffset']),
      total: _int(json['total']),
    );
  }
}

class RemoteMusicAlbum {
  const RemoteMusicAlbum({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.year,
    this.trackCount,
    this.durationMs,
    this.coverRef,
    this.updatedAt,
  });

  /// host 的 `album_uid`。
  final String id;
  final String title;
  final String? artist;
  final String? artistId;
  final int? year;
  final int? trackCount;
  final int? durationMs;
  final String? coverRef;
  final int? updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'artist': ?artist,
    'artistId': ?artistId,
    'year': ?year,
    'trackCount': ?trackCount,
    'durationMs': ?durationMs,
    'coverRef': ?coverRef,
    'updatedAt': ?updatedAt,
  };

  static RemoteMusicAlbum? fromJson(Map<String, Object?> j) {
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    return RemoteMusicAlbum(
      id: id,
      title: title,
      artist: _str(j['artist']),
      artistId: _str(j['artistId']),
      year: _int(j['year']),
      trackCount: _int(j['trackCount']),
      durationMs: _int(j['durationMs']),
      coverRef: _str(j['coverRef']),
      updatedAt: _int(j['updatedAt']),
    );
  }
}

class RemoteMusicArtist {
  const RemoteMusicArtist({
    required this.id,
    required this.name,
    this.albumCount,
    this.coverRef,
  });

  /// host 的 `artist_uid`。
  final String id;
  final String name;
  final int? albumCount;
  final String? coverRef;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'albumCount': ?albumCount,
    'coverRef': ?coverRef,
  };

  static RemoteMusicArtist? fromJson(Map<String, Object?> j) {
    final String? id = _str(j['id']);
    final String? name = _str(j['name']);
    if (id == null || name == null) return null;
    return RemoteMusicArtist(
      id: id,
      name: name,
      albumCount: _int(j['albumCount']),
      coverRef: _str(j['coverRef']),
    );
  }
}

class RemoteMusicPlaylist {
  const RemoteMusicPlaylist({
    required this.id,
    required this.title,
    this.trackCount,
    this.durationMs,
    this.coverRef,
    this.editable = true,
    this.updatedAt,
  });

  /// host 的 `playlist_uid`。
  final String id;
  final String title;
  final int? trackCount;
  final int? durationMs;
  final String? coverRef;

  /// 客户端能不能改（写回 host，design-imusic-q3）。智能歌单不能。
  final bool editable;
  final int? updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'trackCount': ?trackCount,
    'durationMs': ?durationMs,
    'coverRef': ?coverRef,
    'editable': editable,
    'updatedAt': ?updatedAt,
  };

  static RemoteMusicPlaylist? fromJson(Map<String, Object?> j) {
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    return RemoteMusicPlaylist(
      id: id,
      title: title,
      trackCount: _int(j['trackCount']),
      durationMs: _int(j['durationMs']),
      coverRef: _str(j['coverRef']),
      editable: j['editable'] != false,
      updatedAt: _int(j['updatedAt']),
    );
  }
}

class RemoteMusicTrack {
  const RemoteMusicTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.albumId,
    this.discNo,
    this.trackNo,
    this.durationMs,
    this.container,
    this.codec,
    this.bitrateKbps,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.sizeBytes,
    this.coverRef,
    this.playlistEntryId,
    this.cueStartMs,
    this.cueEndMs,
    this.isVideo = false,
    this.unplayableReason,
    this.hasVideos = false,
    this.updatedAt,
  });

  /// host 的 `track_uid`（客户端播放身份同它，design-imusic-q1）。
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? albumId;
  final int? discNo;
  final int? trackNo;
  final int? durationMs;
  final String? container;
  final String? codec;
  final int? bitrateKbps;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final int? sizeBytes;
  final String? coverRef;

  /// 歌单条目 id（只在歌单曲目里有）。
  final String? playlistEntryId;

  /// CUE 虚拟曲目在整轨里的起止（毫秒）：流的是整轨文件，客户端按区间切（EDL）。
  final int? cueStartMs;
  final int? cueEndMs;

  /// 曲目本身是视频容器（MV 曲目）：客户端可直接用曲目自己的流当画面源。
  final bool isVideo;

  /// 非 null = 这首经互联放不了（见 [RemoteMusicUnplayable]）。
  final String? unplayableReason;

  bool get peerPlayable => unplayableReason == null;

  /// host 上有能解析成文件的 MV 绑定（值不值得请求 `…/videos`）。
  final bool hasVideos;
  final int? updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'artist': ?artist,
    'album': ?album,
    'albumId': ?albumId,
    'discNo': ?discNo,
    'trackNo': ?trackNo,
    'durationMs': ?durationMs,
    'container': ?container,
    'codec': ?codec,
    'bitrateKbps': ?bitrateKbps,
    'sampleRate': ?sampleRate,
    'bitDepth': ?bitDepth,
    'channels': ?channels,
    'sizeBytes': ?sizeBytes,
    'coverRef': ?coverRef,
    'playlistEntryId': ?playlistEntryId,
    'cueStartMs': ?cueStartMs,
    'cueEndMs': ?cueEndMs,
    if (isVideo) 'isVideo': true,
    'peerPlayable': peerPlayable,
    'unplayableReason': ?unplayableReason,
    if (hasVideos) 'hasVideos': true,
    'updatedAt': ?updatedAt,
  };

  static RemoteMusicTrack? fromJson(Map<String, Object?> j) {
    final String? id = _str(j['id']);
    final String? title = _str(j['title']);
    if (id == null || title == null) return null;
    return RemoteMusicTrack(
      id: id,
      title: title,
      artist: _str(j['artist']),
      album: _str(j['album']),
      albumId: _str(j['albumId']),
      discNo: _int(j['discNo']),
      trackNo: _int(j['trackNo']),
      durationMs: _int(j['durationMs']),
      container: _str(j['container']),
      codec: _str(j['codec']),
      bitrateKbps: _int(j['bitrateKbps']),
      sampleRate: _int(j['sampleRate']),
      bitDepth: _int(j['bitDepth']),
      channels: _int(j['channels']),
      sizeBytes: _int(j['sizeBytes']),
      coverRef: _str(j['coverRef']),
      playlistEntryId: _str(j['playlistEntryId']),
      cueStartMs: _int(j['cueStartMs']),
      cueEndMs: _int(j['cueEndMs']),
      isVideo: j['isVideo'] == true,
      // 旧字段语义：peerPlayable=false 但没给原因的，按网络来源处理（最常见）。
      unplayableReason:
          _str(j['unplayableReason']) ??
          (j['peerPlayable'] == false
              ? RemoteMusicUnplayable.networkSource
              : null),
      hasVideos: j['hasVideos'] == true,
      updatedAt: _int(j['updatedAt']),
    );
  }
}

class RemoteMusicSearchResult {
  const RemoteMusicSearchResult({
    this.albums = const <RemoteMusicAlbum>[],
    this.artists = const <RemoteMusicArtist>[],
    this.tracks = const <RemoteMusicTrack>[],
    this.playlists = const <RemoteMusicPlaylist>[],
  });

  final List<RemoteMusicAlbum> albums;
  final List<RemoteMusicArtist> artists;
  final List<RemoteMusicTrack> tracks;
  final List<RemoteMusicPlaylist> playlists;

  Map<String, Object?> toJson() => <String, Object?>{
    'albums': <Object?>[for (final RemoteMusicAlbum a in albums) a.toJson()],
    'artists': <Object?>[for (final RemoteMusicArtist a in artists) a.toJson()],
    'tracks': <Object?>[for (final RemoteMusicTrack t in tracks) t.toJson()],
    'playlists': <Object?>[
      for (final RemoteMusicPlaylist p in playlists) p.toJson(),
    ],
  };

  static RemoteMusicSearchResult fromJson(Map<String, Object?> j) =>
      RemoteMusicSearchResult(
        albums: _list(j['albums'], RemoteMusicAlbum.fromJson),
        artists: _list(j['artists'], RemoteMusicArtist.fromJson),
        tracks: _list(j['tracks'], RemoteMusicTrack.fromJson),
        playlists: _list(j['playlists'], RemoteMusicPlaylist.fromJson),
      );
}

/// host 上这首生效的那份歌词（引擎层，不联网）。时间轴缓存不传，客户端自己现解析。
class RemoteMusicLyrics {
  const RemoteMusicLyrics({
    required this.source,
    required this.format,
    required this.raw,
    this.offsetMs = 0,
    this.timingQuality = 'line',
    this.isUserEdited = false,
    this.updatedAt = 0,
  });

  /// host 上 `music_lyrics.source`（`sidecar` / `embedded` / `asr` / `user` / `provider:*`）。
  final String source;
  final String format;
  final Uint8List raw;
  final int offsetMs;
  final String timingQuality;
  final bool isUserEdited;
  final int updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source,
    'format': format,
    'raw': base64Encode(raw),
    'offsetMs': offsetMs,
    'timingQuality': timingQuality,
    'isUserEdited': isUserEdited,
    'updatedAt': updatedAt,
  };

  static RemoteMusicLyrics? fromJson(Map<String, Object?> j) {
    final String? source = _str(j['source']);
    final String? format = _str(j['format']);
    final String? raw = _str(j['raw']);
    if (source == null || format == null || raw == null) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(raw);
    } on FormatException {
      return null;
    }
    return RemoteMusicLyrics(
      source: source,
      format: format,
      raw: bytes,
      offsetMs: _int(j['offsetMs']) ?? 0,
      timingQuality: _str(j['timingQuality']) ?? 'line',
      isUserEdited: j['isUserEdited'] == true,
      updatedAt: _int(j['updatedAt']) ?? 0,
    );
  }
}

/// host 上一条解析得到文件（或 YouTube 地址）的 MV 绑定。
class RemoteMusicVideo {
  const RemoteMusicVideo({
    required this.videoId,
    required this.kind,
    required this.offsetMs,
    this.confidence,
    this.isUserBound = false,
    this.durationMs,
    this.youtubeRef,
    this.label,
    this.updatedAt = 0,
  });

  /// host 的 `music_videos.id`（只在这台 host 内有意义），流票按它签。
  final int videoId;

  /// `local` / `anime_episode` / `youtube`（`MusicVideoKind`）。
  final String kind;

  /// MV 时间 = 音频时间 + offset（对 host 曲目的音频时间轴而言）。
  final int offsetMs;
  final double? confidence;
  final bool isUserBound;
  final int? durationMs;

  /// `youtube` 绑定的地址（design-imusic-q7：下发，客户端按自己的 YouTube 合规门取流；其余种类为 null，
  /// 字节经流票从 host 读）。
  final String? youtubeRef;

  /// 列表里显示的名字（本机文件名 / YouTube 视频 id / 动画集引用），与 host 本机曲目详情同一规则。
  final String? label;
  final int updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'videoId': videoId,
    'kind': kind,
    'offsetMs': offsetMs,
    'confidence': ?confidence,
    'isUserBound': isUserBound,
    'durationMs': ?durationMs,
    'youtubeRef': ?youtubeRef,
    'label': ?label,
    'updatedAt': updatedAt,
  };

  static RemoteMusicVideo? fromJson(Map<String, Object?> j) {
    final int? id = _int(j['videoId']);
    final String? kind = _str(j['kind']);
    if (id == null || kind == null) return null;
    final Object? conf = j['confidence'];
    return RemoteMusicVideo(
      videoId: id,
      kind: kind,
      offsetMs: _int(j['offsetMs']) ?? 0,
      confidence: conf is num ? conf.toDouble() : null,
      isUserBound: j['isUserBound'] == true,
      durationMs: _int(j['durationMs']),
      youtubeRef: _str(j['youtubeRef']),
      label: _str(j['label']),
      updatedAt: _int(j['updatedAt']) ?? 0,
    );
  }
}

/// 请 host 找 MV 的来源（design-imusic-q9）：`anime` = host 视频库里的动画集，`online` = host 搜 YouTube。
abstract final class RemoteMusicVideoCandidateSource {
  static const String anime = 'anime';
  static const String online = 'online';
}

/// host 给出的一个待确认 MV 候选（与本机曲目详情「从动画找 / 在线搜索」同一份候选），客户端选了再请
/// host 绑定（`POST tracks/<uid>/videos`）。
class RemoteMusicVideoCandidate {
  const RemoteMusicVideoCandidate({
    required this.kind,
    required this.ref,
    required this.title,
    this.subtitle,
    this.offsetMs = 0,
    this.confidence,
  });

  final String kind;
  final String ref;
  final String title;
  final String? subtitle;
  final int offsetMs;
  final double? confidence;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'ref': ref,
    'title': title,
    'subtitle': ?subtitle,
    'offsetMs': offsetMs,
    'confidence': ?confidence,
  };

  static RemoteMusicVideoCandidate? fromJson(Map<String, Object?> j) {
    final String? kind = _str(j['kind']);
    final String? ref = _str(j['ref']);
    if (kind == null || ref == null) return null;
    final Object? conf = j['confidence'];
    return RemoteMusicVideoCandidate(
      kind: kind,
      ref: ref,
      title: _str(j['title']) ?? ref,
      subtitle: _str(j['subtitle']),
      offsetMs: _int(j['offsetMs']) ?? 0,
      confidence: conf is num ? conf.toDouble() : null,
    );
  }
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => switch (v) {
  final int i => i,
  final num n => n.toInt(),
  _ => null,
};

List<T> _list<T>(Object? raw, T? Function(Map<String, Object?>) decode) => <T>[
  if (raw is List)
    for (final Object? e in raw)
      if (e is Map<String, Object?>) ?decode(e),
];
