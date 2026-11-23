/// 服务器曲库（音乐方案 §13 P5「服务器曲库」）：Jellyfin（含 Emby / 飞牛等 MediaBrowser
/// 兼容层）的音乐库与 OpenSubsonic（Navidrome / Gonic / Airsonic …）。**只读浏览 + 播放**。
///
/// 契约形态照视频的 `MediaServerBrowser`（`fushi/lib/src/media/video/media_server/`）：服务器
/// 有自己的树（专辑 / 艺人 / 曲目），按父级分页原样暴露，客户端只持有当前屏幕那一页，不把
/// 整库拍平成本地曲库行（几万首的服务器一进曲库页就全量拉是 BUG-1891 同一个坑）。混排进
/// 本地曲库是显式 opt-in（与视频 `jellyfin_show_in_library` 同模式），混进去的也只是专辑卡。
///
/// 播放：交给音乐引擎的是一条 HTTP 流地址（[MusicServerBrowser.streamUri]）。原样直出
/// （direct play，无损按原格式走 mpv 解码）是缺省；用户选了码率上限才请服务器转码（服务器
/// 不支持转码时仍直出，并在 [MusicServerStream.transcoded] 里如实说）。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 服务器协议家族（持久化值冻结）。
enum MusicServerKind {
  /// Jellyfin / Emby / 飞牛影视等 MediaBrowser 兼容层（凭据复用视频的媒体服务器配置）。
  jellyfin('jellyfin'),

  /// OpenSubsonic / Subsonic API（Navidrome、Gonic、Airsonic-Advanced、Ampache …）。
  subsonic('subsonic'),

  /// Apple Music catalog（MusicKit 方案 P1b：Worker 代签 developer token，只浏览 + 30 秒
  /// 试听；`fushi_engine/media/music/apple_music/`）。
  appleMusic('apple_music'),

  /// YouTube 内置音源（反馈 0tRY-D2JgG）：只搜曲目 + 起播时取 audio-only 流，没有专辑 /
  /// 艺人 / 歌单树；`fushi_engine/media/music/youtube/`。
  youtube('youtube'),

  /// 已配对的 Fushi 互联 host 的曲库（设计 docs/specs/2026-11-23-interconnect-music-library-design.md）：
  /// 曲目 id 就是 host 的 `track_uid`，播放身份同它（拍板 design-imusic-q1 选 a），取流要先向 host
  /// 签统一流票（起播时才取，[kFushiHostMusicScheme] 占位）。
  fushiHost('fushi_host');

  const MusicServerKind(this.wire);

  final String wire;

  static MusicServerKind? fromWire(Object? raw) {
    for (final MusicServerKind k in values) {
      if (k.wire == raw) return k;
    }
    return null;
  }
}

/// 一张专辑。
class MusicServerAlbum {
  const MusicServerAlbum({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.year,
    this.trackCount,
    this.durationMs,
    this.coverRef,
  });

  final String id;
  final String title;
  final String? artist;
  final String? artistId;
  final int? year;
  final int? trackCount;
  final int? durationMs;

  /// 封面引用（交给 [MusicServerBrowser.coverUri]；没有封面为 null）。
  final String? coverRef;
}

/// 一位艺人。
class MusicServerArtist {
  const MusicServerArtist({
    required this.id,
    required this.name,
    this.albumCount,
    this.coverRef,
  });

  final String id;
  final String name;
  final int? albumCount;
  final String? coverRef;
}

/// 一个歌单（服务器上的用户歌单 / Apple Music 编辑歌单与资料库歌单）。
class MusicServerPlaylist {
  const MusicServerPlaylist({
    required this.id,
    required this.title,
    this.description,
    this.curator,
    this.trackCount,
    this.durationMs,
    this.coverRef,
    this.editable = false,
  });

  final String id;
  final String title;

  /// 简介（纯文本；服务器给的是富文本时由实现剥成纯文本）。
  final String? description;

  /// 歌单作者 / 编辑（Apple Music 的 curator、服务器上的 owner）。
  final String? curator;
  final int? trackCount;
  final int? durationMs;
  final String? coverRef;

  /// 当前账号能往里加歌（Apple Music 资料库里自己建的歌单）。
  final bool editable;
}

/// 一首曲目（服务器报的源属性：信号路径面板与格式徽章用）。
class MusicServerTrack {
  const MusicServerTrack({
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
    this.path,
  });

  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? albumId;
  final int? discNo;
  final int? trackNo;
  final int? durationMs;

  /// 容器 / 扩展名（`flac` / `mp3` / `m4a` …）。
  final String? container;

  /// 编码（`flac` / `alac` / `mp3` / `aac` / `opus` …，小写）。
  final String? codec;
  final int? bitrateKbps;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final int? sizeBytes;
  final String? coverRef;

  /// 歌单条目 id（只在歌单曲目里有：Jellyfin 的 `PlaylistItemId`）。删条目 / 挪位置按它，
  /// 同一首在歌单里出现两次时两条 id 不同。
  final String? playlistEntryId;

  /// 服务器上的文件路径（服务器愿意报时才有，Jellyfin 的 `Path`）。只用于导出 `.m3u8`；
  /// 播放一律走 [MusicServerBrowser.streamFor]。
  final String? path;

  bool get isLossless => isLosslessMusicCodec(codec ?? container);
}

/// 无损编码 / 容器（服务器报的值，小写比较）。
bool isLosslessMusicCodec(String? codec) {
  final String c = (codec ?? '').toLowerCase();
  return const <String>{
        'flac',
        'alac',
        'ape',
        'wavpack',
        'wv',
        'tak',
        'tta',
        'wav',
        'aiff',
        'aif',
        'dsf',
        'dff',
        'dsd',
      }.contains(c) ||
      c.startsWith('pcm_') ||
      c.startsWith('dsd_');
}

/// 一页。[nextOffset] 为 null = 没有下一页（翻页只认它）。
class MusicServerPage<T> {
  const MusicServerPage({required this.items, this.nextOffset, this.total});

  final List<T> items;
  final int? nextOffset;
  final int? total;

  bool get hasMore => nextOffset != null;
}

/// 专辑排序。
enum MusicServerAlbumSort { name, newest, artist, year }

/// 一次搜索的结果。
class MusicServerSearchResult {
  const MusicServerSearchResult({
    this.albums = const <MusicServerAlbum>[],
    this.artists = const <MusicServerArtist>[],
    this.tracks = const <MusicServerTrack>[],
    this.playlists = const <MusicServerPlaylist>[],
  });

  final List<MusicServerAlbum> albums;
  final List<MusicServerArtist> artists;
  final List<MusicServerTrack> tracks;
  final List<MusicServerPlaylist> playlists;

  bool get isEmpty =>
      albums.isEmpty && artists.isEmpty && tracks.isEmpty && playlists.isEmpty;
}

/// 一条播放流。
class MusicServerStream {
  const MusicServerStream({
    required this.uri,
    required this.transcoded,
    this.codec,
    this.bitrateKbps,
    this.isPreview = false,
  });

  /// 交给 mpv 的地址（凭据在 query 里：mpv 没有头通道；日志一律经凭据脱敏）。
  final Uri uri;

  /// 是不是请服务器转码了（信号路径面板据此判非 bit-perfect、源属性取转码后的）。
  final bool transcoded;
  final String? codec;
  final int? bitrateKbps;

  /// 只是曲目的试听片段（Apple Music 未登录 / 无订阅时的约 30 秒预览），不是整首：
  /// 曲目元数据里的时长是整首的，不能当这条流的长度（反馈 okvRZINcQU）。
  final bool isPreview;
}

/// 能改歌单的服务器（Jellyfin / Emby）。浏览器实现了它，歌单页与曲目菜单才出现新建 /
/// 加歌 / 删条目 / 重排 / 改名 / 删除。失败一律抛（无权限 = 服务器 4xx）。
abstract interface class MusicServerPlaylistEditing {
  /// 新建歌单（[trackIds] 按顺序成为初始条目）。
  Future<MusicServerPlaylist> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  });

  /// 把 [trackIds] 追加到歌单末尾。
  Future<void> addToPlaylist(String playlistId, List<String> trackIds);

  /// 删掉几条条目（[MusicServerTrack.playlistEntryId]）。
  Future<void> removeFromPlaylist(String playlistId, List<String> entryIds);

  /// 把一条条目挪到 [newIndex]（0 起，最终下标）。
  Future<void> movePlaylistEntry(
    String playlistId,
    String entryId,
    int newIndex,
  );

  Future<void> renamePlaylist(String playlistId, String name);

  Future<void> deletePlaylist(String playlistId);
}

/// 服务器曲库的浏览器。失败一律抛（断网 / 令牌失效 / 服务器 5xx），页面显示错误与重试。
abstract interface class MusicServerBrowser {
  MusicServerKind get kind;

  /// 服务器身份（同 id = 同一台服务器 + 同一个账号）：页面状态 / 混排开关 / 播放项 uid 都按它。
  String get serverId;

  /// 用户可见的服务器名。
  String get displayName;

  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  });

  /// 一张专辑的曲目（按碟号 / 轨号）。
  Future<List<MusicServerTrack>> albumTracks(String albumId);

  Future<List<MusicServerArtist>> listArtists();

  Future<List<MusicServerAlbum>> artistAlbums(String artistId);

  /// 歌单（服务器：当前账号能看到的歌单；Apple Music catalog：该地区的热门歌单榜；
  /// Apple Music 资料库：用户资料库里的歌单）。
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  });

  /// 一个歌单的曲目（歌单自身顺序；放不了的曲目不列出）。
  Future<List<MusicServerTrack>> playlistTracks(String playlistId);

  /// 搜专辑 / 艺人 / 曲目。空白查询不发请求。
  Future<MusicServerSearchResult> search(String query, {int limit = 30});

  /// 播放流。[maxBitrateKbps] 为 null = 原样直出；给了且服务器支持转码时请服务器转码。
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps});

  /// 封面地址（服务器侧缩放）。
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize});

  void close();
}

/// 能给出歌词的服务器（互联 host：host 上生效的那份，引擎层、不联网）。
abstract interface class MusicServerLyricsSource {
  /// host 上这首生效的歌词：原文 + 格式 + 整首偏移 + 来源；没有为 null。
  Future<MusicServerLyrics?> lyricsFor(String trackId);

  /// 把整首偏移写回 host（[source] 是 [MusicServerLyrics.source]）。
  Future<void> setLyricsOffset(
    String trackId, {
    required String source,
    required int offsetMs,
  });

  /// 把用户在本机选定的一份写成 host 上的手动指定。
  Future<void> chooseLyrics(
    String trackId, {
    required String format,
    required List<int> raw,
    required int offsetMs,
  });
}

/// 歌词服务按**播放路径**问歌词的那一层（互联 host 曲目：路径是 [fushiHostMusicTrackPath] 占位，
/// 实现按占位找到 host 再转给它的 [MusicServerLyricsSource]）。不认识的路径回 null / 什么都不做。
abstract interface class MusicHostLyricsLayer {
  /// 这条路径是不是本层负责的曲目。
  bool handles(String path);

  Future<MusicServerLyrics?> lyricsFor(String path);

  Future<void> setLyricsOffset(
    String path, {
    required String source,
    required int offsetMs,
  });

  Future<void> chooseLyrics(
    String path, {
    required String format,
    required List<int> raw,
    required int offsetMs,
  });
}

/// 服务器给的一份歌词。
class MusicServerLyrics {
  const MusicServerLyrics({
    required this.source,
    required this.format,
    required this.raw,
    this.offsetMs = 0,
    this.isUserEdited = false,
  });

  final String source;
  final String format;
  final List<int> raw;
  final int offsetMs;
  final bool isUserEdited;
}

/// 能给出 MV 绑定的服务器（互联 host 上自动匹配 / 手动绑定好的 MV）。
abstract interface class MusicServerVideoSource {
  /// 这首曲目在服务器上的 MV 绑定（解析得到画面的才出）。
  Future<List<MusicServerVideo>> videosFor(String trackId);

  /// 起播时取 MV 画面流（带票，[MusicServerMediaLease.release] 释放）。
  Future<MusicServerMediaLease> openVideo(MusicServerVideo video);

  /// 把 MV 对齐微调写回服务器。
  Future<void> setVideoOffset(MusicServerVideo video, int offsetMs);
}

/// 服务器上的一条 MV 绑定。`offsetMs`：MV 时间 = 音频时间 + offset。
class MusicServerVideo {
  const MusicServerVideo({
    required this.id,
    required this.kind,
    required this.offsetMs,
    this.isUserBound = false,
    this.youtubeRef,
  });

  final String id;

  /// `local` / `anime_episode` / `youtube`（`MusicVideoKind`）。
  final String kind;
  final int offsetMs;
  final bool isUserBound;

  /// `youtube` 绑定的地址：画面由客户端自己的 YouTube 音源取（受客户端合规门约束）。
  final String? youtubeRef;
}

/// 一条起播时才签的媒体流：[uri] 交给播放器，用完调 [release]（幂等）。
class MusicServerMediaLease {
  const MusicServerMediaLease({required this.uri, required this.release});

  final Uri uri;
  final Future<void> Function() release;
}

/// 互联 host 曲目的播放占位（`fushi-host-music:///<hostId>/<trackUid>`）：起播时才签票取流。
const String kFushiHostMusicScheme = 'fushi-host-music';

/// 互联 host 封面的占位（`fushi-host-music-cover:///<hostId>/<coverRef>`）：封面组件经钉扎通道取。
const String kFushiHostMusicCoverScheme = 'fushi-host-music-cover';

String fushiHostMusicTrackPath(String hostId, String trackUid) =>
    _hostPath(kFushiHostMusicScheme, hostId, trackUid);

String fushiHostMusicCoverPath(String hostId, String coverRef) =>
    _hostPath(kFushiHostMusicCoverScheme, hostId, coverRef);

/// [fushiHostMusicTrackPath] 的逆；不是这种路径回 null。
({String hostId, String trackUid})? parseFushiHostMusicTrackPath(String path) =>
    _parseHostPath(path, kFushiHostMusicScheme);

/// [fushiHostMusicCoverPath] 的逆（`trackUid` 位是封面引用）。
({String hostId, String trackUid})? parseFushiHostMusicCoverPath(String path) =>
    _parseHostPath(path, kFushiHostMusicCoverScheme);

bool isFushiHostMusicPath(String path) =>
    path.startsWith('$kFushiHostMusicScheme:///');

// 两段都放在路径里（authority 留空）：放进 URI host 会被 `Uri.parse` 小写化，配对身份 / uid 要
// 原样保住。两段各自百分号编码。
String _hostPath(String scheme, String hostId, String id) =>
    '$scheme:///${Uri.encodeComponent(hostId)}/${Uri.encodeComponent(id)}';

({String hostId, String trackUid})? _parseHostPath(String path, String scheme) {
  final String prefix = '$scheme:///';
  if (!path.startsWith(prefix)) return null;
  final List<String> parts = path.substring(prefix.length).split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  try {
    return (
      hostId: Uri.decodeComponent(parts[0]),
      trackUid: Uri.decodeComponent(parts[1]),
    );
  } on Object {
    return null; // 坏的百分号编码
  }
}

const int kMusicServerPageSize = 100;
const int kMusicServerCoverSize = 400;

/// 服务器曲目在本机的播放身份（音乐引擎的 `trackUid`）：服务器身份 + 条目 id 派生，
/// 与本地曲库的内容派生 uid 不撞（命名空间不同）。
String musicServerTrackUid(String serverId, String trackId) {
  final List<int> d = sha1
      .convert(
        utf8.encode('fushi-music-server-track-v1\u0000$serverId\u0000$trackId'),
      )
      .bytes;
  final StringBuffer b = StringBuffer('srv');
  for (int i = 0; i < 15; i++) {
    b.write(d[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 一首服务器曲目在本机的播放身份：互联 host 直接用 host 的 `track_uid`（同一首歌在两台设备是同一首，
/// 歌单 / 播放记录 / 断点 / 歌词偏移与 host 同键，design-imusic-q1 选 a）；其余服务器走 `srv` 命名空间。
String musicServerPlaybackUid(MusicServerBrowser browser, String trackId) =>
    browser.kind == MusicServerKind.fushiHost
    ? trackId
    : musicServerTrackUid(browser.serverId, trackId);

/// 专辑同理（互联 host 用 host 的 `album_uid`）。
String musicServerPlaybackAlbumUid(
  MusicServerBrowser browser,
  String albumId,
) => browser.kind == MusicServerKind.fushiHost
    ? albumId
    : musicServerAlbumUid(browser.serverId, albumId);

/// 服务器专辑混排进本地曲库时的专辑 uid（同上，命名空间不同）。
String musicServerAlbumUid(String serverId, String albumId) {
  final List<int> d = sha1
      .convert(
        utf8.encode('fushi-music-server-album-v1\u0000$serverId\u0000$albumId'),
      )
      .bytes;
  final StringBuffer b = StringBuffer('srv');
  for (int i = 0; i < 15; i++) {
    b.write(d[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}
