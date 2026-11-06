/// 在线音源插件的 app 侧装配（docs/specs/2026-10-28-music-plugins.md §5）：播放路径、
/// 播放身份、取流解析，以及 mpv 后端用的全局装配点。
///
/// 插件曲目的播放项路径是 `fushi-music-plugin://<插件 id>/<曲目 id>`——一个只认身份、不带
/// 地址的占位：真正的流地址在 mpv 后端打开这一首（[resolveMusicPluginMedia]）时才向插件要，
/// 平台给的短时效地址随每次重开自然刷新。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';

/// 插件曲目播放路径的 scheme。
const String kMusicPluginScheme = 'fushi-music-plugin';

/// 插件曲目 → 播放路径。
String musicPluginTrackPath(String pluginId, String trackId) => Uri(
  scheme: kMusicPluginScheme,
  host: pluginId,
  pathSegments: <String>[trackId],
).toString();

/// 播放路径 → (插件 id, 曲目 id)；不是插件曲目返回 null。
({String pluginId, String trackId})? parseMusicPluginTrackPath(String path) {
  if (!path.startsWith('$kMusicPluginScheme://')) return null;
  final Uri? uri = Uri.tryParse(path);
  if (uri == null || uri.host.isEmpty || uri.pathSegments.length != 1) {
    return null;
  }
  return (pluginId: uri.host, trackId: uri.pathSegments.single);
}

bool isMusicPluginPath(String path) => parseMusicPluginTrackPath(path) != null;

String _uid(String prefix, String domain, String pluginId, String id) {
  final List<int> d = sha1
      .convert(utf8.encode('$domain\u0000$pluginId\u0000$id'))
      .bytes;
  final StringBuffer b = StringBuffer(prefix);
  for (int i = 0; i < 15; i++) {
    b.write(d[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// 插件曲目在本机的播放身份（与本地曲库 / 服务器曲目的 uid 命名空间不同）。
String musicPluginTrackUid(String pluginId, String trackId) =>
    _uid('plg', 'fushi-music-plugin-track-v1', pluginId, trackId);

String musicPluginAlbumUid(String pluginId, String albumId) =>
    _uid('plga', 'fushi-music-plugin-album-v1', pluginId, albumId);

/// 插件曲目 → 播放项。源属性（编码 / 采样率）此时未知，取流后由信号路径面板按 mpv 实测显示。
MusicPlayItem musicPluginPlayItem(
  String pluginId,
  MusicPluginTrack track, {
  String? albumTitle,
  String? coverUrl,
}) => MusicPlayItem(
  trackUid: musicPluginTrackUid(pluginId, track.id),
  path: musicPluginTrackPath(pluginId, track.id),
  title: track.title,
  artist: track.artists.isEmpty ? null : track.artistText,
  album: track.albumTitle ?? albumTitle,
  albumUid: track.albumId == null
      ? null
      : musicPluginAlbumUid(pluginId, track.albumId!),
  discNo: track.discNo,
  trackNo: track.trackNo,
  durationMs: track.durationMs,
  coverPath: track.coverUrl ?? coverUrl,
  artistRefs: <MusicPlayArtistRef>[
    for (final MusicPluginArtistRef a in track.artists)
      MusicPlayArtistRef(id: a.id, name: a.name),
  ],
  sourceAlbumId: track.albumId,
);

/// 设置里的服务器码率上限（kbps，0 = 原样）→ 插件取流音质档：同一个「流媒体音质」设置。
MusicPluginQuality musicPluginQualityForBitrate(int maxKbps) =>
    switch (maxKbps) {
      <= 0 => MusicPluginQuality.lossless,
      >= 320 => MusicPluginQuality.high,
      _ => MusicPluginQuality.standard,
    };

/// 取流失败（插件报错 / 只给试听 / 地址越权）：消息直接给用户看。
final class MusicPluginStreamUnavailable implements Exception {
  const MusicPluginStreamUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 插件曲目路径 → 流（mpv 后端取流用；缺省 [resolveMusicPluginStream]，测试注入替身）。
/// 失败抛 [MusicPluginStreamUnavailable]。
typedef MusicPluginStreamResolver =
    Future<MusicPluginStream> Function(String path);

/// 插件给的流地址提前多久视为过期：预排的下一首在到期前这么久重取，免得放到它（或长暂停
/// 后续播）时拿着已失效的地址。
const Duration kMusicPluginStreamRefreshMargin = Duration(seconds: 60);

/// mpv 后端用的全局装配点：`AppModel` 建音乐会话时装上（合规门没过 / 未装配时为 null，
/// 插件曲目按不可播放处理）。管理器按需懒建：重启后从队列恢复的插件曲目也能取流。
class MusicPluginPlaybackHost {
  const MusicPluginPlaybackHost({required this.manager, required this.quality});

  final MusicPluginManager Function() manager;
  final MusicPluginQuality Function() quality;
}

MusicPluginPlaybackHost? musicPluginPlaybackHost;

/// 插件曲目 → 可交给 mpv 的流（URL + 请求头）。失败抛 [MusicPluginStreamUnavailable]。
Future<MusicPluginStream> resolveMusicPluginStream(String path) async {
  final ({String pluginId, String trackId})? ref = parseMusicPluginTrackPath(
    path,
  );
  final MusicPluginPlaybackHost? host = musicPluginPlaybackHost;
  if (ref == null || host == null) {
    throw const MusicPluginStreamUnavailable('插件音源不可用');
  }
  try {
    final MusicPluginStream s = await host
        .manager()
        .source(ref.pluginId)
        .stream(ref.trackId, quality: host.quality());
    if (s.isTrial) {
      throw const MusicPluginStreamUnavailable('该曲目只能试听片段');
    }
    return s;
  } on MusicPluginException catch (e) {
    throw MusicPluginStreamUnavailable(e.message);
  }
}
