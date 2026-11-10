/// 服务器曲目 → 播放项的纯转换。
///
/// 从 music_servers.dart 拆出：那边持有服务器注册表、要读 AppModel；曲目入库层
/// （music_remote_tracks.dart，AppModel 建音乐会话时就 import）只需要这一个纯函数，
/// 从那边取会把整条音乐会话 / 历史 / 曲库数据链拖进 import 大环（import_cycle_guard）。
library;

import 'package:fushi_engine/media/music/server/music_server.dart'
    show
        MusicServerBrowser,
        MusicServerStream,
        MusicServerTrack,
        musicServerAlbumUid,
        musicServerTrackUid;

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;

/// 一首服务器曲目 → 播放项。路径是 HTTP 流地址；源属性取服务器报的（转码时取转码后的：
/// 信号路径面板据此不把转码流判 bit-perfect）。
MusicPlayItem musicServerPlayItem(
  MusicServerBrowser browser,
  MusicServerTrack track, {
  int? maxBitrateKbps,
  String? albumTitle,
  String? coverPath,
}) {
  final MusicServerStream stream = browser.streamFor(
    track,
    maxBitrateKbps: maxBitrateKbps,
  );
  return MusicPlayItem(
    trackUid: musicServerTrackUid(browser.serverId, track.id),
    path: stream.uri.toString(),
    title: track.title,
    artist: track.artist,
    album: albumTitle ?? track.album,
    albumUid: track.albumId == null
        ? null
        : musicServerAlbumUid(browser.serverId, track.albumId!),
    discNo: track.discNo,
    trackNo: track.trackNo,
    durationMs: track.durationMs,
    coverPath: coverPath ?? browser.coverUri(track.coverRef)?.toString(),
    codec: stream.transcoded ? stream.codec : (track.codec ?? track.container),
    sampleRate: stream.transcoded ? null : track.sampleRate,
    bitDepth: stream.transcoded ? null : track.bitDepth,
    channels: track.channels,
  );
}
