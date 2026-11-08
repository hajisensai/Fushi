/// 服务器曲库的 app 侧装配（音乐方案 §13 P5）：哪些服务器、怎么播、混不混进本地曲库。
///
/// - **Jellyfin 家族**：凭据就是视频的媒体服务器配置（`SyncRepository.getMediaServers` 里的
///   `JellyfinServerConfig`），登录 / 登出 / 换线路都在原来的设置页，这里不另存一份；
/// - **OpenSubsonic**：用户在 设置 › 在线服务 › 媒体服务器 › 服务器曲库 里自配（`music_subsonic_servers`，
///   凭据键、设备本地）；
/// - 混排进本地曲库是每台服务器的显式 opt-in（`music_server_library_mix`），混进去的是专辑卡，
///   点开仍走服务器专辑页（按需取曲目）。
/// - **Apple Music catalog**（MusicKit 方案 P1b / P2）：设置里显式打开后出现；未连接账号时只浏览 +
///   30 秒试听，连接了且订阅有效（[AppleMusicAccount.canPlayFullTracks]）时整曲播放、按账号所在
///   storefront 浏览，并多出「Apple Music 资料库」来源。都不参与混排（catalog 没有「整库」可混，
///   资料库按方案 §4 v1 不混）。
library;

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_personal_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_token_source.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_account.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/youtube_music_gate.dart';
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
      final AppleMusicAccount account = app.appleMusicAccount;
      // 没连接时不碰桥（网页桥读状态要起隐藏 WebView）；连接了读一次（有缓存）。
      if (account.connected) await account.refresh();
      final bool full = account.canPlayFullTracks;
      out.add(
        AppleMusicCatalogClient(
          tokens: appleMusicTokenSource,
          // 整曲时按账号所在地区浏览：别区的曲目账号放不了。
          storefront: full
              ? (account.state.storefront ??
                    app.prefsRepo.musicAppleMusicStorefront)
              : app.prefsRepo.musicAppleMusicStorefront,
          fullTracks: full,
        ),
      );
      if (full) {
        out.add(
          AppleMusicLibraryClient(
            credentials: account.userCredentials,
            displayName: t.music_apple_music_library_name,
          ),
        );
      }
    }
    if (isYoutubeMusicSourceAvailable && app.prefsRepo.musicYoutubeEnabled) {
      out.add(YoutubeMusicClient(displayName: 'YouTube'));
    }
  }
  return out;
}

/// 一个 Apple Music 来源连带的另外几份能力：catalog（播放 / 榜单 / 电台）、资料库（歌单读写）、
/// 个人数据（推荐 / 最近 / 评分 / 加入资料库）。未登录或没有订阅时只有 [catalog]（试听）。
class AppleMusicLinkedSources {
  AppleMusicLinkedSources({
    required this.catalog,
    this.library,
    this.personal,
    this.ownsCatalog = false,
    this.ownsLibrary = false,
  });

  /// 这两份是不是本对象新建的（[close] 只关自己建的，调用方传进来的浏览器归调用方）。
  final bool ownsCatalog;
  final bool ownsLibrary;

  final AppleMusicCatalogClient catalog;
  final AppleMusicLibraryClient? library;
  final AppleMusicPersonalClient? personal;

  /// 能整曲播放（已登录且订阅有效）：电台、评分、资料库写操作都只在这时可用。
  bool get signedIn => personal != null;

  /// 一首曲目在 catalog 里的 id（评分 / 加入资料库 / 加歌单 / 起电台都按它）。资料库曲目经
  /// [AppleMusicLibraryClient.catalogIdOf] 换算，没换算过回 null。
  String? catalogSongIdOf(MusicServerBrowser browser, MusicServerTrack track) =>
      switch (browser) {
        AppleMusicCatalogClient() => track.id,
        AppleMusicLibraryClient() => browser.catalogIdOf(track.id),
        _ => null,
      };

  void close() {
    if (ownsCatalog) catalog.close();
    if (ownsLibrary) library?.close();
    personal?.close();
  }
}

/// 给一个 Apple Music 浏览器配齐关联来源（非 Apple Music 来源回 null）。[browser] 本身是
/// catalog / 资料库时原样复用，免得同一页里出现两份「列出过的曲目」登记表。
AppleMusicLinkedSources? appleMusicLinkedSourcesFor(
  AppModel app,
  MusicServerBrowser browser,
) {
  if (browser.kind != MusicServerKind.appleMusic || !app.isPreferencesReady) {
    return null;
  }
  final AppleMusicAccount account = app.appleMusicAccount;
  final bool full = account.canPlayFullTracks;
  final AppleMusicCatalogClient catalog = switch (browser) {
    AppleMusicCatalogClient() => browser,
    _ => AppleMusicCatalogClient(
      tokens: appleMusicTokenSource,
      storefront:
          account.state.storefront ?? app.prefsRepo.musicAppleMusicStorefront,
      fullTracks: full,
    ),
  };
  final bool ownsCatalog = !identical(catalog, browser);
  if (!full) {
    return AppleMusicLinkedSources(catalog: catalog, ownsCatalog: ownsCatalog);
  }
  return AppleMusicLinkedSources(
    catalog: catalog,
    ownsCatalog: ownsCatalog,
    ownsLibrary: browser is! AppleMusicLibraryClient,
    library: browser is AppleMusicLibraryClient
        ? browser
        : AppleMusicLibraryClient(
            credentials: account.userCredentials,
            displayName: t.music_apple_music_library_name,
          ),
    personal: AppleMusicPersonalClient(
      credentials: account.userCredentials,
      catalog: catalog,
    ),
  );
}

/// 这类来源能不能混排进本地曲库（Apple Music 只有热门榜、没有「整库」，不混）。
bool musicServerSupportsLibraryMix(MusicServerKind kind) => switch (kind) {
  MusicServerKind.jellyfin || MusicServerKind.subsonic => true,
  MusicServerKind.appleMusic || MusicServerKind.youtube => false,
};

/// 这类来源有没有可浏览的树（专辑 / 艺人 / 歌单 / 榜单）：「推荐」页与推荐首页的服务器货架只列
/// 有的。YouTube 内置音源只有搜索。
bool musicServerHasBrowse(MusicServerKind kind) => switch (kind) {
  MusicServerKind.jellyfin ||
  MusicServerKind.subsonic ||
  MusicServerKind.appleMusic => true,
  MusicServerKind.youtube => false,
};

/// 来源列表 / 设置里的副标题（Apple Music 分试听与整曲）。
String musicServerSubtitle(MusicServerBrowser server) => switch (server) {
  AppleMusicLibraryClient() => t.music_server_apple_music_full_subtitle,
  AppleMusicCatalogClient(fullTracks: true) =>
    t.music_server_apple_music_full_subtitle,
  _ => switch (server.kind) {
    MusicServerKind.jellyfin => t.music_server_jellyfin_subtitle,
    MusicServerKind.subsonic => t.music_server_subsonic_subtitle,
    MusicServerKind.appleMusic => t.music_server_apple_music_subtitle,
    MusicServerKind.youtube => t.music_server_youtube_subtitle,
  },
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
