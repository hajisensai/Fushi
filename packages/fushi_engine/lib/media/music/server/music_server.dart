/// 服务器曲库（音乐方案 §13 P5「服务器曲库」）：Jellyfin（含 Emby / 飞牛等 MediaBrowser
/// 兼容层）的音乐库与 OpenSubsonic（Navidrome / Gonic / Airsonic …）。浏览 + 播放是必备契约
/// （[MusicServerBrowser]）；写回服务器的能力是可选接口，来源实现了才出现对应入口：改歌单
/// （[MusicServerPlaylistEditing]）、收藏（[MusicServerFavoriteEditing]）、流派与播放统计
/// （[MusicServerDiscovery]）、即时混音（[MusicServerInstantMix]）、播放上报
/// （[MusicServerPlaybackReporting]）、服务器歌词（[MusicServerLyricsProvider]）。
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

import 'package:fushi_engine/media/music/server/music_server_loudness.dart';

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
  youtube('youtube');

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
    this.favorite,
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

  /// 服务器上标了收藏（Jellyfin `UserData.IsFavorite` / Subsonic `starred`）；服务器没报为
  /// null。只是读到时的快照，切换后以 app 侧的收藏状态表为准。
  final bool? favorite;
}

/// 一位艺人。
class MusicServerArtist {
  const MusicServerArtist({
    required this.id,
    required this.name,
    this.albumCount,
    this.coverRef,
    this.favorite,
  });

  final String id;
  final String name;
  final int? albumCount;
  final String? coverRef;

  /// 同 [MusicServerAlbum.favorite]。
  final bool? favorite;
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
    this.favorite,
    this.loudness,
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

  /// 同 [MusicServerAlbum.favorite]。
  final bool? favorite;

  /// 服务器给的响度（Jellyfin `NormalizationGain` / OpenSubsonic `replayGain`）；服务器没测 /
  /// 文件没标签时为 null（见 `music_server_loudness.dart`）。
  final MusicServerLoudness? loudness;

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

/// 一首曲目原文件的下载地址（离线副本用）。
class MusicServerDownloadSource {
  const MusicServerDownloadSource({
    required this.uri,
    this.headers = const <String, String>{},
    this.extensionHint,
  });

  /// 原文件地址。凭据可能在 query 里（与 [MusicServerStream.uri] 同理）：只在内存里用，
  /// 不落库、不进日志 / 错误文本。
  final Uri uri;

  /// 额外请求头（没有为空）。
  final Map<String, String> headers;

  /// 服务器报的容器 / 扩展名（`flac` / `mp3` …，小写）：下完的文件头认不出时的回退。
  final String? extensionHint;
}

/// 能下载曲目**原文件**的服务器（Jellyfin `/Items/{id}/Download`、Subsonic `download`）。
/// 浏览器实现了它，曲目菜单 / 专辑页 / 艺人页才出现「下载」（离线副本）。下的是服务器上存的
/// 那份文件（不转码、不受串流码率上限影响），标签与封面原样随文件走。
abstract interface class MusicServerDownloading {
  /// 一首曲目原文件的下载地址（只拼地址、不发请求）。
  MusicServerDownloadSource downloadSourceFor(MusicServerTrack track);
}

/// 收藏 / 即时混音按条目种类发请求（Subsonic 的 `star` 分 `id` / `albumId` / `artistId`）。
enum MusicServerItemKind { track, album, artist }

/// 一种流派（Jellyfin `MusicGenre`；Subsonic 没有流派 id，[id] 就是流派名）。
class MusicServerGenre {
  const MusicServerGenre({
    required this.id,
    required this.name,
    this.albumCount,
    this.trackCount,
    this.coverRef,
  });

  final String id;
  final String name;
  final int? albumCount;
  final int? trackCount;
  final String? coverRef;
}

/// 一组混排的专辑 / 艺人 / 曲目（收藏、最常播放、最近播放）。Jellyfin 按曲目统计播放，
/// Subsonic 只按专辑统计（`getAlbumList2 frequent / recent`），所以「最常播放」在两边分别
/// 落在 [tracks] / [albums]：页面有哪组画哪组。
class MusicServerItems {
  const MusicServerItems({
    this.albums = const <MusicServerAlbum>[],
    this.artists = const <MusicServerArtist>[],
    this.tracks = const <MusicServerTrack>[],
  });

  final List<MusicServerAlbum> albums;
  final List<MusicServerArtist> artists;
  final List<MusicServerTrack> tracks;

  bool get isEmpty => albums.isEmpty && artists.isEmpty && tracks.isEmpty;
}

/// 能收藏的服务器（Jellyfin `FavoriteItems` / Subsonic `star` · `unstar` · `getStarred2`）。
abstract interface class MusicServerFavoriteEditing {
  /// 标 / 取消收藏。失败抛。
  Future<void> setFavorite(
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  });

  /// 当前账号收藏的专辑 / 艺人 / 曲目（各自至多 [limit] 条）。
  Future<MusicServerItems> listFavorites({int limit = kMusicServerPageSize});

  /// 一首曲目此刻是否已收藏（「正在播放」页的心形：播放项不带列表里读到的收藏状态）。
  /// 服务器上没有这首回 null；网络 / 服务器错误抛。
  Future<bool?> trackFavorite(String trackId);
}

/// 能按流派 / 最近添加 / 播放统计浏览的服务器（Jellyfin `MusicGenres` 与 `Items` 排序；
/// Subsonic `getGenres` / `getSongsByGenre` / `getAlbumList2`）。
abstract interface class MusicServerDiscovery {
  Future<List<MusicServerGenre>> listGenres();

  /// 一个流派的专辑（按名排）。
  Future<List<MusicServerAlbum>> genreAlbums(
    MusicServerGenre genre, {
    int limit = kMusicServerPageSize,
  });

  /// 一个流派的曲目（「播放这个流派」用）。
  Future<List<MusicServerTrack>> genreTracks(
    MusicServerGenre genre, {
    int limit = kMusicServerPageSize,
  });

  /// 最近加进服务器的专辑（新的在前）。
  Future<List<MusicServerAlbum>> recentlyAddedAlbums({int limit = 30});

  /// 播放次数最多的（服务器自己的统计；见 [MusicServerItems] 的曲目 / 专辑之分）。
  Future<MusicServerItems> mostPlayed({int limit = 30});

  /// 最近播放的（新的在前）。
  Future<MusicServerItems> recentlyPlayed({int limit = 30});
}

/// 能按一首 / 一张专辑 / 一位艺人生成「即时混音」的服务器（Jellyfin `InstantMix`；
/// Subsonic `getSimilarSongs`，服务器没接相似度数据源时可能为空）。
abstract interface class MusicServerInstantMix {
  Future<List<MusicServerTrack>> instantMix(
    MusicServerItemKind kind,
    String id, {
    int limit = 50,
  });
}

/// 服务器流地址里认出来的曲目（[MusicServerStreamIdentity.streamRefOf]）。
class MusicServerStreamRef {
  const MusicServerStreamRef({required this.trackId, required this.transcoded});

  final String trackId;

  /// 这条流是请服务器转码的（上报的 `PlayMethod` 据此）。
  final bool transcoded;
}

/// 能从自己发出的流地址（[MusicServerBrowser.streamFor]）认回曲目 id 的服务器。播放项只带
/// 流地址（从最近播放 / 曲库还原的也一样），播放上报与服务器歌词靠它找回服务器侧曲目；
/// 调用方再用 [musicServerTrackUid] 核对播放项的 uid，别的服务器的同形地址不会认错。
abstract interface class MusicServerStreamIdentity {
  /// [uri] 不是本类服务器的流地址时回 null。
  MusicServerStreamRef? streamRefOf(Uri uri);
}

/// 一次播放上报的状态。
class MusicServerPlaybackReport {
  const MusicServerPlaybackReport({
    required this.trackId,
    required this.playSessionId,
    required this.positionMs,
    required this.startedAtMs,
    this.durationMs,
    this.paused = false,
    this.transcoded = false,
  });

  final String trackId;

  /// 本机为这一次播放生成的会话 id（同一次播放的开始 / 进度 / 停止共用）。
  final String playSessionId;
  final int positionMs;

  /// 开播时刻（epoch 毫秒；Subsonic scrobble 的 `time`）。
  final int startedAtMs;
  final int? durationMs;
  final bool paused;
  final bool transcoded;
}

/// 进度上报附带的事件（Jellyfin `EventName`）。
enum MusicServerPlaybackEvent { pause, unpause }

/// 能接收播放上报的服务器：播放次数 / 最近播放 / 「正在播放」由服务器自己统计。
/// Jellyfin 走 `/Sessions/Playing*`（开播即计一次播放）；Subsonic 走 `scrobble`（开播报
/// 「正在播放」，停止时听够一半或 4 分钟才提交一次播放），没有进度上报。上报失败一律抛，
/// 由调用方吞掉记日志（不影响播放）。
abstract interface class MusicServerPlaybackReporting
    implements MusicServerStreamIdentity {
  Future<void> reportPlaybackStarted(MusicServerPlaybackReport report);

  Future<void> reportPlaybackProgress(
    MusicServerPlaybackReport report, {
    MusicServerPlaybackEvent? event,
  });

  Future<void> reportPlaybackStopped(MusicServerPlaybackReport report);
}

/// Subsonic / Last.fm 通行的「算听过一次」门槛：听够一半或 4 分钟（时长未知时只认 4 分钟）。
bool musicScrobbleThresholdReached(int positionMs, int? durationMs) {
  const int fourMinutes = 4 * 60 * 1000;
  if (positionMs >= fourMinutes) return true;
  return durationMs != null && durationMs > 0 && positionMs * 2 >= durationMs;
}

/// 服务器存的一行歌词。
class MusicServerLyricLine {
  const MusicServerLyricLine({required this.text, this.startMs});

  final String text;

  /// 行起点（毫秒）；不带时间的纯文本歌词为 null。
  final int? startMs;
}

/// 服务器存的一首歌词（Jellyfin `/Audio/{id}/Lyrics`、OpenSubsonic `getLyricsBySongId`）。
class MusicServerLyrics {
  const MusicServerLyrics({required this.lines});

  final List<MusicServerLyricLine> lines;

  /// 每行都带时间（逐行同步歌词）。
  bool get synced =>
      lines.isNotEmpty &&
      lines.every((MusicServerLyricLine l) => l.startMs != null);

  /// 转成交给歌词解析器的原文：同步歌词 → LRC（`lrc`），否则纯文本（`txt`）。
  ({String text, String format}) toRaw() {
    if (!synced) {
      return (
        text: lines.map((MusicServerLyricLine l) => l.text).join('\n'),
        format: 'txt',
      );
    }
    final StringBuffer b = StringBuffer();
    for (final MusicServerLyricLine l in lines) {
      final int ms = l.startMs!;
      final int min = ms ~/ 60000;
      final int sec = (ms % 60000) ~/ 1000;
      final int cs = (ms % 1000) ~/ 10;
      b.writeln(
        '[${min.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}]${l.text}',
      );
    }
    return (text: b.toString(), format: 'lrc');
  }
}

/// 存着歌词的服务器。这首没有歌词回 null；网络 / 服务器错误抛（调用方不当「没有」缓存）。
abstract interface class MusicServerLyricsProvider
    implements MusicServerStreamIdentity {
  Future<MusicServerLyrics?> lyricsFor(String trackId);
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

/// 播放项里的服务器曲目身份（不含任何凭据）：播放流 / 封面地址带账号凭据、`trackUid` 是哈希，
/// 两样都推不回是哪台服务器的哪一首。播放上报、服务器歌词、起播期补查响度、生成字幕时取流都
/// 按它找回当前配置的那台服务器（[MusicServerBrowser.serverId]）与服务器侧条目；离线副本的
/// 播放项也带着它（路径是本机文件时照样认得出是哪首）。
class MusicServerTrackRef {
  const MusicServerTrackRef({
    required this.kind,
    required this.serverId,
    required this.trackId,
    this.albumId,
    this.coverRef,
  });

  final MusicServerKind kind;

  /// [MusicServerBrowser.serverId]。
  final String serverId;

  /// 服务器侧曲目 id。
  final String trackId;

  /// 服务器侧专辑 id（Jellyfin 的专辑响度挂在专辑条目上，补查时一并取）。
  final String? albumId;

  /// 服务器侧封面引用（[MusicServerBrowser.coverUri] 的入参）。
  final String? coverRef;

  /// 播放身份（[musicServerTrackUid]），与播放项的 `trackUid` 相同。
  String get trackUid => musicServerTrackUid(serverId, trackId);

  @override
  bool operator ==(Object other) =>
      other is MusicServerTrackRef &&
      other.kind == kind &&
      other.serverId == serverId &&
      other.trackId == trackId &&
      other.albumId == albumId &&
      other.coverRef == coverRef;

  @override
  int get hashCode => Object.hash(kind, serverId, trackId, albumId, coverRef);
}
