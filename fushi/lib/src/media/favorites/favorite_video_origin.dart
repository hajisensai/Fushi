/// 视频收藏句「跳回原处」里**没有本机库行**的那一支：收藏是在远端条目上记的
/// （媒体服务器直接串流、互联对端、云盘视频、在线视频源……），bookKey 只是该来源内的
/// 条目 id。按收藏时记下的来源身份（`FavoriteSentence.originSourceId`，v179）与重开
/// 规格（`FavoriteSentence.originLocator`，v180）回到那个来源取回条目，交给远端播放页；
/// 回不去时给出具体原因（[FavoriteVideoOriginFailure]）。
///
/// 收藏夹 / 首页「收藏句子」（`FavoriteOriginNavigator`）与手机遥控跳收藏
/// （`video_fushi/remote_control.part.dart`）共用这一个解析口，失败原因在本机弹提示、
/// 在遥控协议里作 `favorite_source_unavailable` 的 `reason`。
///
/// 本文件不进 AppModel 大 import 环（`import_cycle_guard_test.dart`）：媒体服务器与在线
/// 源的起播都从环外的小文件取，AppModel 上的东西由调用方经
/// [FavoriteVideoOriginSources.live] 的参数传进来。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

import 'package:fushi/src/media/favorites/favorite_video_origin_failure.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_item_launch.dart';
import 'package:fushi/src/media/video/online/anime_source_book_spec.dart';
import 'package:fushi/src/media/video/online/anime_source_launch.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart'
    show AnimeSourceVideoClient, kAnimeSourceVideoIdPrefix;
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart'
    show isVideoOnlineSourcesAvailable;
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncBackend, SyncBackendType, resolveSyncBackend;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi/src/media/favorites/favorite_video_origin_failure.dart';

/// 一个能列出视频清单的远端库（互联对端 / 云盘）：[client] 是起播用的客户端，null =
/// 这个库不能串流（FTP 云盘只能整文件下载）；[listing] 取它的视频清单（失败即连不上）。
typedef FavoriteRemoteVideoLibrary = ({
  RemoteVideoClient? client,
  Future<List<RemoteVideoInfo>> Function() listing,
});

/// 找回来之后的起播材料：[client] 交给远端播放页；[ownsClient] = 客户端是这次现建的
/// （媒体服务器 / 在线源），交给播放页时带 `ownsRemoteClient: true`，推页之前放弃要
/// `closeOwnedRemoteVideoClient`；互联 / 云盘的客户端是共享的，不归调用方。
typedef FavoriteVideoOriginLaunch = ({
  RemoteVideoClient client,
  RemoteVideoInfo info,
  bool ownsClient,
});

/// [resolveFavoriteVideoOrigin] 的结果：恰好一个非 null。
@immutable
final class FavoriteVideoOriginResult {
  const FavoriteVideoOriginResult.found(FavoriteVideoOriginLaunch this.launch)
    : failure = null;

  const FavoriteVideoOriginResult.failed(
    FavoriteVideoOriginFailure this.failure,
  ) : launch = null;

  final FavoriteVideoOriginLaunch? launch;
  final FavoriteVideoOriginFailure? failure;
}

/// 解析器用到的各个来源（测试替身从这里注入；真 app 用 [FavoriteVideoOriginSources.live]）。
@immutable
final class FavoriteVideoOriginSources {
  const FavoriteVideoOriginSources({
    required this.mediaServers,
    required this.interconnect,
    required this.cloud,
    required this.onlineSourcesAvailable,
    required this.onlineEpisode,
  });

  /// 真 app 的来源：媒体服务器配置与互联 / 云盘开关读 [database]；在线源扩展经
  /// [animeManager]（用到在线源时才取，它首次取用会起扩展运行时）；[subtitleLanguage] 是在线源默认字幕轨的语言（与在线作品页同一
  /// 条链）；[cache] 是库页的远端清单缓存（互联 / 云盘的清单命中它就不再问一次）。
  factory FavoriteVideoOriginSources.live({
    required FushiDatabase database,
    required MihonManager Function() animeManager,
    String? Function()? subtitleLanguage,
    RemoteLibraryCache? cache,
  }) {
    final SyncRepository syncRepo = SyncRepository(database);
    Future<List<RemoteVideoInfo>> Function() listingOf(
      String sourceId,
      Future<List<RemoteVideoInfo>> Function() fetch,
    ) => cache == null
        ? fetch
        : () => cache.read<List<RemoteVideoInfo>>(
            sourceId: sourceId,
            key: RemoteLibraryCacheKeys.videos,
            fetch: fetch,
          );
    return FavoriteVideoOriginSources(
      mediaServers: syncRepo.getMediaServers,
      interconnect: () async {
        if (!await syncRepo.isInterconnectEnabled()) return null;
        final InterconnectSyncBackend backend =
            InterconnectSyncBackend.instance;
        if (!await backend.restoreAuth(syncRepo)) return null;
        return (
          client: backend,
          listing: listingOf(
            backend.remoteLibrarySourceId,
            backend.listRemoteVideos,
          ),
        );
      },
      cloud: (String sourceId) async {
        if (!await syncRepo.isCloudSyncEnabled()) return null;
        final SyncBackendType type = await syncRepo.getBackendType();
        if (type == SyncBackendType.fushiServer ||
            cloudRemoteLibrarySourceId(type.name) != sourceId) {
          return null;
        }
        final SyncBackend backend = resolveSyncBackend(type);
        if (!await backend.restoreAuth(syncRepo)) return null;
        final CloudRemoteVideoClient cloud = CloudRemoteVideoClient(
          backend: backend,
          backendType: type,
        );
        return (
          client: cloud.streamingClient(),
          listing: listingOf(sourceId, cloud.listRemoteVideos),
        );
      },
      // 合规门 + 运行时平台门：iOS 不带在线源宿主、没有 Mihon 宿主的平台不起
      // 宿主（与播放页重开入库在线行同一判据）。
      onlineSourcesAvailable: isVideoOnlineSourcesAvailable,
      onlineEpisode: (AnimeSourceBookSpec spec, String bookUid) async {
        final ({AnimeSourceVideoClient client, RemoteVideoInfo info}) launch =
            await buildAnimeSourceEpisodeLaunch(
              spec: spec,
              bookUid: bookUid,
              manager: animeManager(),
              subtitleLanguageResolver: subtitleLanguage,
            );
        return (client: launch.client, info: launch.info);
      },
    );
  }

  /// 已登录的媒体服务器配置。
  final Future<List<MediaServerConfig>> Function() mediaServers;

  /// 互联对端的库；null = 没开互联或没有配对。
  final Future<FavoriteRemoteVideoLibrary?> Function() interconnect;

  /// 来源身份为 [sourceId]（`cloud:<后端类型>`）的云盘视频库；null = 云同步关着，
  /// 或现在用的不是这种云盘。
  final Future<FavoriteRemoteVideoLibrary?> Function(String sourceId) cloud;

  /// 本机能不能跑在线视频源（[isVideoOnlineSourcesAvailable]：iOS 商店合规不带在线源
  /// 宿主，或平台没有 Mihon 宿主）。为假时在线源收藏一律
  /// [FavoriteVideoOriginFailure.onlineSourceUnsupported]，不碰 [onlineEpisode]——
  /// 门外取扩展 manager 会在不该有宿主的平台上起宿主。
  final bool onlineSourcesAvailable;

  /// 在线视频源按重开规格建这一集的客户端（现建、归调用方）。扩展没装 / 停用抛
  /// [AnimeSourceLaunchUnavailable]。
  final Future<({RemoteVideoClient client, RemoteVideoInfo info})> Function(
    AnimeSourceBookSpec spec,
    String bookUid,
  )
  onlineEpisode;
}

/// 按收藏时记下的来源回到没有本机库行的远端条目 [itemId]（收藏的 bookKey）。
///
/// - [originSourceId] 是媒体服务器：只问那一台（`resolveMediaServerItemLaunch`）。
/// - 互联对端（`interconnect`）：对端在线时在它的清单里按 id 找（要有可串流的字节）。
///   互联的 bookUid 是对端库的全局身份，换了对端也不会错认。
/// - 云盘（`cloud:<类型>`）：现用的就是那种云盘时在它的视频目录里按 id 找。
/// - 在线视频源（`anime-source:…`）：按 [originLocator]（作品 + 集）重建客户端；本机
///   不能跑在线源（iOS / 无 Mihon 宿主）是 [FavoriteVideoOriginFailure.onlineSourceUnsupported]。
/// - 直链 / 音乐 MV 等临时播放，或没记重开规格的在线源：[FavoriteVideoOriginFailure.notReopenable]。
/// - null（v179 之前的旧收藏）：先挨台问媒体服务器（核对标题），再问互联对端（核对
///   标题）；哪儿都没有是 [FavoriteVideoOriginFailure.originUnknown]，有一处连不上
///   则报那一处连不上。
///
/// 单个来源的异常记 [ErrorLogService] 并归成「连不上」；[sources] 里读配置本身抛出
/// （数据库坏了）原样传给调用方。
Future<FavoriteVideoOriginResult> resolveFavoriteVideoOrigin({
  required String itemId,
  required String? originSourceId,
  required String? originLocator,
  required String expectedTitle,
  required FavoriteVideoOriginSources sources,
}) async {
  if (itemId.isEmpty) {
    return const FavoriteVideoOriginResult.failed(
      FavoriteVideoOriginFailure.noLink,
    );
  }
  final String? origin = originSourceId;
  if (origin == null) {
    return _resolveLegacy(itemId, expectedTitle.trim(), sources);
  }
  if (isMediaServerSourceId(origin)) {
    final MediaServerItemLaunchResult result =
        await resolveMediaServerItemLaunch(
          itemId: itemId,
          originSourceId: origin,
          expectedTitle: expectedTitle,
          loadConfigs: sources.mediaServers,
        );
    final MediaServerItemLaunch? launch = result.launch;
    if (launch != null) return _found(launch.client, launch.info, owns: true);
    return FavoriteVideoOriginResult.failed(switch (result.failure!) {
      MediaServerItemLaunchFailure.serverSignedOut =>
        FavoriteVideoOriginFailure.serverSignedOut,
      MediaServerItemLaunchFailure.itemMissing =>
        FavoriteVideoOriginFailure.serverItemMissing,
      MediaServerItemLaunchFailure.serverUnreachable =>
        FavoriteVideoOriginFailure.serverUnreachable,
    });
  }
  if (origin == kInterconnectRemoteLibrarySourceId) {
    return _resolveInLibrary(
      itemId,
      await sources.interconnect(),
      unavailable: FavoriteVideoOriginFailure.peerUnavailable,
      unreachable: FavoriteVideoOriginFailure.peerOffline,
      missing: FavoriteVideoOriginFailure.peerItemMissing,
      logTag: 'interconnect',
    );
  }
  if (origin.startsWith(kCloudRemoteLibrarySourceIdPrefix)) {
    return _resolveInLibrary(
      itemId,
      await sources.cloud(origin),
      unavailable: FavoriteVideoOriginFailure.cloudUnavailable,
      unreachable: FavoriteVideoOriginFailure.cloudUnreachable,
      missing: FavoriteVideoOriginFailure.cloudItemMissing,
      logTag: 'cloud',
    );
  }
  if (origin.startsWith(kAnimeSourceVideoIdPrefix)) {
    if (!sources.onlineSourcesAvailable) {
      return const FavoriteVideoOriginResult.failed(
        FavoriteVideoOriginFailure.onlineSourceUnsupported,
      );
    }
    final AnimeSourceBookSpec? spec = AnimeSourceBookSpec.tryParse(
      originLocator,
    );
    if (spec == null) {
      return const FavoriteVideoOriginResult.failed(
        FavoriteVideoOriginFailure.notReopenable,
      );
    }
    try {
      final ({RemoteVideoClient client, RemoteVideoInfo info}) launch =
          await sources.onlineEpisode(spec, itemId);
      return _found(launch.client, launch.info, owns: true);
    } on AnimeSourceLaunchUnavailable catch (error, stack) {
      ErrorLogService.instance.log(
        'FavoriteVideoOrigin.onlineSource',
        error,
        stack,
      );
      return const FavoriteVideoOriginResult.failed(
        FavoriteVideoOriginFailure.onlineSourceMissing,
      );
    }
  }
  // 粘贴的直链（`url_stream`）、音乐 MV（`music_online_mv`）等临时播放：没有能按
  // 条目 id 找回的库。
  return const FavoriteVideoOriginResult.failed(
    FavoriteVideoOriginFailure.notReopenable,
  );
}

FavoriteVideoOriginResult _found(
  RemoteVideoClient client,
  RemoteVideoInfo info, {
  required bool owns,
}) => FavoriteVideoOriginResult.found((
  client: client,
  info: info,
  ownsClient: owns,
));

/// 互联对端 / 云盘：在 [library] 的清单里按 id 找。互联清单里对端没有字节可给的条目
/// （网络流书 / `.strm`，[RemoteVideoInfo.peerPlayable] 为假）点过去只会撞 404，按
/// 「没有这个视频」处理。
Future<FavoriteVideoOriginResult> _resolveInLibrary(
  String itemId,
  FavoriteRemoteVideoLibrary? library, {
  required FavoriteVideoOriginFailure unavailable,
  required FavoriteVideoOriginFailure unreachable,
  required FavoriteVideoOriginFailure missing,
  required String logTag,
}) async {
  if (library == null) return FavoriteVideoOriginResult.failed(unavailable);
  final RemoteVideoClient? client = library.client;
  if (client == null) {
    return const FavoriteVideoOriginResult.failed(
      FavoriteVideoOriginFailure.notReopenable,
    );
  }
  final List<RemoteVideoInfo> videos;
  try {
    videos = await library.listing();
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('FavoriteVideoOrigin.$logTag', error, stack);
    return FavoriteVideoOriginResult.failed(unreachable);
  }
  for (final RemoteVideoInfo video in videos) {
    if (video.id == itemId && video.peerPlayable) {
      return _found(client, video, owns: false);
    }
  }
  return FavoriteVideoOriginResult.failed(missing);
}

/// v179 之前的旧收藏（没记来源）：媒体服务器挨台问（解析器自己核对标题），再看互联
/// 对端的清单（同样核对标题——旧收藏不知道来自哪儿，id 撞上的未必是它）。
Future<FavoriteVideoOriginResult> _resolveLegacy(
  String itemId,
  String wantedTitle,
  FavoriteVideoOriginSources sources,
) async {
  final MediaServerItemLaunchResult media = await resolveMediaServerItemLaunch(
    itemId: itemId,
    originSourceId: null,
    expectedTitle: wantedTitle,
    loadConfigs: sources.mediaServers,
  );
  final MediaServerItemLaunch? mediaLaunch = media.launch;
  if (mediaLaunch != null) {
    return _found(mediaLaunch.client, mediaLaunch.info, owns: true);
  }
  bool peerOffline = false;
  final FavoriteRemoteVideoLibrary? peer = await sources.interconnect();
  final RemoteVideoClient? peerClient = peer?.client;
  if (peer != null && peerClient != null) {
    try {
      for (final RemoteVideoInfo video in await peer.listing()) {
        if (video.id == itemId &&
            video.peerPlayable &&
            video.title.trim() == wantedTitle) {
          return _found(peerClient, video, owns: false);
        }
      }
    } on Object catch (error, stack) {
      peerOffline = true;
      ErrorLogService.instance.log(
        'FavoriteVideoOrigin.legacyInterconnect',
        error,
        stack,
      );
    }
  }
  if (media.failure == MediaServerItemLaunchFailure.serverUnreachable) {
    return const FavoriteVideoOriginResult.failed(
      FavoriteVideoOriginFailure.serverUnreachable,
    );
  }
  return FavoriteVideoOriginResult.failed(
    peerOffline
        ? FavoriteVideoOriginFailure.peerOffline
        : FavoriteVideoOriginFailure.originUnknown,
  );
}
