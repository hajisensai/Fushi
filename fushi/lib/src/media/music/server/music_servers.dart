/// 服务器曲库的 app 侧装配（音乐方案 §13 P5）：哪些服务器、怎么播、混不混进本地曲库。
///
/// - **Jellyfin 家族**：凭据就是视频的媒体服务器配置（`SyncRepository.getMediaServers` 里的
///   `JellyfinServerConfig`），登录 / 登出 / 换线路都在原来的设置页，这里不另存一份；
/// - **OpenSubsonic**：用户在 设置 › 音乐 › 服务器曲库 里自配（`music_subsonic_servers`，
///   凭据键、设备本地）；
/// - 混排进本地曲库是每台服务器的显式 opt-in（`music_server_library_mix`），混进去的是专辑卡，
///   点开仍走服务器专辑页（按需取曲目）。
/// - **Apple Music catalog**（MusicKit 方案 P1b）：设置里显式打开后出现；只浏览 + 30 秒试听，
///   不参与混排（没有「整库」可混，专辑分区只是热门榜）。
library;

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_token_source.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;
import 'package:fushi/src/sync/sync_repository.dart';

/// app 内共享的 developer token 来源：浏览器实例每次新建，token 缓存要跨实例复用。
final AppleMusicTokenSource appleMusicTokenSource = AppleMusicTokenSource();

/// 本机配置的全部音乐服务器（每次调用新建浏览器，不缓存实例：设置页登入 / 登出立即反映）。
Future<List<MusicServerBrowser>> loadMusicServerBrowsers(AppModel app) async {
  final List<MusicServerBrowser> out = <MusicServerBrowser>[];
  if (app.isDatabaseReady) {
    for (final MediaServerConfig c in await SyncRepository(
      app.database,
    ).getMediaServers()) {
      if (c is JellyfinServerConfig) out.add(JellyfinMusicClient(c));
    }
  }
  // 偏好还没装好（测试替身 / 独立 entry point）时没有自配服务器，不抛。
  if (app.isPreferencesReady) {
    for (final SubsonicServerConfig c in app.prefsRepo.musicSubsonicServers) {
      if (c.enabled) out.add(SubsonicMusicClient(c));
    }
    if (app.prefsRepo.musicAppleMusicEnabled) {
      out.add(
        AppleMusicCatalogClient(
          tokens: appleMusicTokenSource,
          storefront: app.prefsRepo.musicAppleMusicStorefront,
        ),
      );
    }
  }
  return out;
}

/// 这类来源能不能混排进本地曲库（Apple Music 只有热门榜、没有「整库」，不混）。
bool musicServerSupportsLibraryMix(MusicServerKind kind) => switch (kind) {
  MusicServerKind.jellyfin || MusicServerKind.subsonic => true,
  MusicServerKind.appleMusic => false,
};

/// 设置里可选的转码码率上限（kbps）；0（原样直出）另列。
const List<int> kMusicServerBitrateChoices = <int>[320, 192, 128];

/// 服务器码率上限（设置）→ [MusicServerBrowser.streamFor] 的参数：0 = 原样直出。
int? musicServerBitrateLimit(int settingKbps) =>
    settingKbps <= 0 ? null : settingKbps;

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

/// 混排进曲库的一张服务器专辑（专辑网格里与本地专辑并列）。
class MusicServerAlbumRef {
  const MusicServerAlbumRef({required this.browser, required this.album});

  final MusicServerBrowser browser;
  final MusicServerAlbum album;
}

/// 每台混排服务器最多取多少张专辑进曲库网格（防一进曲库页就把几万张专辑全拉下来；
/// 更多的去服务器页里翻）。
const int kMusicServerMixAlbumLimit = 500;

/// 已 opt-in 混排的服务器的专辑（按名排，每台至多 [kMusicServerMixAlbumLimit] 张）。一台
/// 服务器取不到（断网 / 令牌失效）只丢它自己那份并记进 [failures]，不连坐本地曲库。
Future<List<MusicServerAlbumRef>> loadMixedServerAlbums(
  AppModel app, {
  Map<String, Object>? failures,
}) async {
  if (!app.isPreferencesReady) return const <MusicServerAlbumRef>[];
  final Set<String> mix = app.prefsRepo.musicServerLibraryMix;
  if (mix.isEmpty) return const <MusicServerAlbumRef>[];
  final List<MusicServerAlbumRef> out = <MusicServerAlbumRef>[];
  for (final MusicServerBrowser b in await loadMusicServerBrowsers(app)) {
    if (!mix.contains(b.serverId) || !musicServerSupportsLibraryMix(b.kind)) {
      continue;
    }
    try {
      int offset = 0;
      while (out.where((MusicServerAlbumRef r) => r.browser == b).length <
          kMusicServerMixAlbumLimit) {
        final MusicServerPage<MusicServerAlbum> page = await b.listAlbums(
          offset: offset,
        );
        out.addAll(<MusicServerAlbumRef>[
          for (final MusicServerAlbum a in page.items)
            MusicServerAlbumRef(browser: b, album: a),
        ]);
        final int? next = page.nextOffset;
        if (next == null) break;
        offset = next;
      }
    } on Object catch (e) {
      failures?[b.serverId] = e;
    }
  }
  return out;
}
