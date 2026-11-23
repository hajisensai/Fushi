/// 服务器曲目 → 播放项的纯转换。
///
/// 从 music_servers.dart 拆出：那边持有服务器注册表、要读 AppModel；曲目入库层
/// （music_remote_tracks.dart，AppModel 建音乐会话时就 import）只需要这一个纯函数，
/// 从那边取会把整条音乐会话 / 历史 / 曲库数据链拖进 import 大环（import_cycle_guard）。
library;

import 'package:fushi_engine/media/music/server/music_server.dart'
    show
        MusicServerBrowser,
        MusicServerKind,
        MusicServerStream,
        MusicServerTrack,
        MusicServerTrackRef,
        musicServerAlbumUid,
        musicServerTrackUid;
import 'package:fushi_engine/media/music/server/music_server_loudness.dart'
    show MusicServerLoudness;

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;

/// 一首服务器曲目在本机的离线副本（v172 `music_server_downloads`：下完的原文件）。
/// [serverId] / [trackId] 是这首在服务器上的身份（行里存的服务器配置身份与条目 id，不含
/// 凭据）：离线副本的播放项照样带 [MusicPlayItem.serverTrack]，播放上报、服务器歌词、
/// 响度补查、生成字幕都认得出是哪首。[loudness] 是下载时一并存下的服务器响度（离线时用）。
typedef MusicServerLocalCopy = ({
  String path,
  String? coverPath,
  String? codec,
  String serverId,
  String trackId,
  MusicServerLoudness? loudness,
});

/// 按播放身份（[musicServerTrackUid]）查离线副本；没有回 null。
typedef MusicServerLocalCopyLookup =
    MusicServerLocalCopy? Function(String trackUid);

/// 进程级装配点：`AppModel` 建音乐会话时装上（`music_server_downloads.dart` 的进程内索引，
/// 只认文件确实在的行）。未装配（测试 / 无头入口）时服务器曲目一律串流。
MusicServerLocalCopyLookup? musicServerLocalCopyLookup;

/// 一首服务器曲目 → 播放项。路径是 HTTP 流地址（带账号凭据，只活在内存里；落库只用
/// [MusicPlayItem.serverTrack] 这份身份，BUG-5267）；响度取服务器给的
/// （[MusicServerTrack.loudness]，没给时起播期按 [MusicPlayItem.serverTrack] 补查）；源属性取
/// 服务器报的（转码时取转码后的：
/// 信号路径面板据此不把转码流判 bit-perfect）。
///
/// 这首有离线副本（[musicServerLocalCopyLookup]）时路径是本机文件：不连服务器、不转码
/// （码率上限只管串流），封面也优先用下好的那张——服务器离线照样能放、能显示。
MusicPlayItem musicServerPlayItem(
  MusicServerBrowser browser,
  MusicServerTrack track, {
  int? maxBitrateKbps,
  String? albumTitle,
  String? coverPath,
}) {
  final String uid = musicServerTrackUid(browser.serverId, track.id);
  final MusicServerLocalCopy? local = musicServerLocalCopyLookup?.call(uid);
  if (local != null) {
    return musicServerLocalPlayItem(
      uid,
      local,
      track,
      albumUid: track.albumId == null
          ? null
          : musicServerAlbumUid(browser.serverId, track.albumId!),
      albumTitle: albumTitle,
      fallbackCoverPath:
          coverPath ?? browser.coverUri(track.coverRef)?.toString(),
      kind: browser.kind,
    );
  }
  final MusicServerStream stream = browser.streamFor(
    track,
    maxBitrateKbps: maxBitrateKbps,
  );
  final MusicServerLoudness? loudness = track.loudness;
  return MusicPlayItem(
    trackUid: uid,
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
    rgTrackGain: loudness?.trackGainDb,
    rgTrackPeak: loudness?.trackPeak,
    rgAlbumGain: loudness?.albumGainDb,
    rgAlbumPeak: loudness?.albumPeak,
    serverTrack: MusicServerTrackRef(
      kind: browser.kind,
      serverId: browser.serverId,
      trackId: track.id,
      albumId: track.albumId,
      coverRef: track.coverRef,
    ),
    isPreview: stream.isPreview,
  );
}

/// 有离线副本的服务器曲目 → 播放项（不需要服务器配置：曲库里的这首在服务器删了 / 离线时
/// 也能放）。uid 与串流时一致；封面优先本机那张，没有才用 [fallbackCoverPath]。
///
/// [kind] 是这台服务器的协议家族（这台设备上还配着它时由调用方给）：给了才带
/// [MusicPlayItem.serverTrack]（播放上报 / 响度补查 / 生成字幕要找回那台服务器）。响度取
/// 列表接口当场给的（[MusicServerTrack.loudness]），没有时用下载时存下的那份。
MusicPlayItem musicServerLocalPlayItem(
  String trackUid,
  MusicServerLocalCopy local,
  MusicServerTrack track, {
  String? albumUid,
  String? albumTitle,
  String? fallbackCoverPath,
  MusicServerKind? kind,
}) {
  final MusicServerLoudness? loudness = track.loudness ?? local.loudness;
  return MusicPlayItem(
    trackUid: trackUid,
    path: local.path,
    title: track.title,
    artist: track.artist,
    album: albumTitle ?? track.album,
    albumUid: albumUid,
    discNo: track.discNo,
    trackNo: track.trackNo,
    durationMs: track.durationMs,
    coverPath: local.coverPath ?? fallbackCoverPath,
    codec: local.codec ?? track.codec ?? track.container,
    sampleRate: track.sampleRate,
    bitDepth: track.bitDepth,
    channels: track.channels,
    rgTrackGain: loudness?.trackGainDb,
    rgTrackPeak: loudness?.trackPeak,
    rgAlbumGain: loudness?.albumGainDb,
    rgAlbumPeak: loudness?.albumPeak,
    serverTrack: kind == null
        ? null
        : MusicServerTrackRef(
            kind: kind,
            serverId: local.serverId,
            trackId: local.trackId,
            albumId: track.albumId,
            coverRef: track.coverRef,
          ),
  );
}
