/// Apple Music 电台的播放项（app 侧）：电台本身进 Fushi 队列的那一项，以及电台里放到某首时
/// 引擎用来就地替换它的那一项（[appleMusicStationNowPlayingItem]）。
///
/// 路径 / 身份的编解码在 `fushi_engine/media/music/apple_music/apple_music_station.dart`。
library;

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show appleMusicArtworkUri, appleMusicSongUri, normalizeAppleMusicStorefront;
import 'package:fushi_engine/media/music/apple_music/apple_music_station.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';

/// 一个 catalog 电台 → 播放项（交给 `MusicPlayerEngine.playQueue`，通常单独成一个队列）。
/// [storefront] 是浏览这个电台所用 catalog 的 storefront（电台里每首歌的身份按它派生，
/// 与从同一 catalog 点播同一首一致）；[coverUrl] 是已定尺寸的封面地址。
MusicPlayItem appleMusicStationPlayItem({
  required String stationId,
  required String storefront,
  required String name,
  String? coverUrl,
}) {
  final String sf = normalizeAppleMusicStorefront(storefront);
  return MusicPlayItem(
    trackUid: appleMusicStationTrackUid(stationId, sf),
    path: appleMusicStationUri(stationId, storefront: sf).toString(),
    title: name,
    coverPath: coverUrl,
  );
}

/// 电台 [station] 里现在放到 [now] → 引擎就地替换当前项用的播放项。
///
/// - 是 catalog 歌曲（有 songId）：身份 = 同一 storefront 的 catalog 曲目身份，路径 = 这首的
///   整曲地址（播放历史里点它重播的是这首歌，而不是整个电台；电台本身由引擎另记、重开用它）。
/// - 直播 / 节目（没有 songId）：身份与路径仍是电台本身，只换显示的标题 / 艺人 / 封面。
///
/// 封面缺了用电台的封面。
MusicPlayItem appleMusicStationNowPlayingItem(
  MusicPlayItem station,
  AppleMusicNowPlaying now,
) {
  final String sf =
      appleMusicStationStorefrontFromPath(station.path) ??
      normalizeAppleMusicStorefront(null);
  final String? cover =
      appleMusicArtworkUri(now.artworkUrl)?.toString() ?? station.coverPath;
  final String? songId = now.songId;
  if (songId == null) {
    return MusicPlayItem(
      trackUid: station.trackUid,
      path: station.path,
      title: now.title ?? station.title,
      artist: now.artist,
      album: now.album ?? station.title,
      durationMs: now.durationMs,
      coverPath: cover,
    );
  }
  return MusicPlayItem(
    trackUid: appleMusicStationSongTrackUid(sf, songId),
    path: appleMusicSongUri(songId).toString(),
    title: now.title ?? '',
    artist: now.artist,
    album: now.album,
    durationMs: now.durationMs,
    coverPath: cover,
    codec: 'aac',
  );
}
