import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/video/remote_video_source_resolver.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_registry.dart' show isHomeTabVisible;
import 'package:fushi/src/models/video_collection_open_request.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_track_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/remote_video_client.dart' show RemoteVideoSource;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/music_cover_source.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart'
    show OnlineSourcesDomain;
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
import 'package:fushi/src/media/media_source.dart';

/// 「同一作品」区块的远端视频来源（[MediaLinksSection.remoteVideoSource]）：与视频库
/// 页同一条判据（[resolveVisibleRemoteVideoSource]，「显示远端条目」关着时 null），
/// 远端合集卡据此取服务器海报。
Future<RemoteVideoSource?> Function() mediaLinkRemoteVideoSource({
  required WidgetRef ref,
}) => () {
  final AppModel appModel = ref.read(appProvider);
  return resolveVisibleRemoteVideoSource(
    prefs: appModel.prefsRepo,
    database: appModel.database,
  );
};

/// 「未入库」灰卡的「去搜」：交给各模块**已有**的获取入口，标题预填。返回 null =
/// 本平台 / 本配置没有可用入口（灰卡就只是灰卡，不渲染一个点了没去处的按钮）。
///
/// - 视频合集 / 单个视频：番剧下载对话框（与合集详情页「相关作品 › 去下载」同一个），
///   门是「浏览」模块开着——该模块的 `availableOn` 已委托 `StoreRestrictedCapability`，
///   iOS 上恒关；
/// - 书 / 游戏：发现页同一个「AI 下载」入口（[discoveryAiAcquireAction]），合规门
///   （下载 / 外部发现）与 AI 模块门都在它里面，不在这里另写平台判断；
/// - 音乐：音乐模块落地前没有获取入口。
ValueChanged<String>? mediaLinkSearchAction({
  required BuildContext context,
  required WidgetRef ref,
  required MediaLinkKind kind,
}) {
  final AppModel appModel = ref.read(appProvider);
  switch (kind) {
    case MediaLinkKind.videoCollection:
    case MediaLinkKind.videoEpisode:
      if (!appModel.moduleVisibility.isEnabled(ModuleId.browse)) return null;
      return (String title) => unawaited(
        showAppDialog<void>(
          context: context,
          builder: (_) =>
              AnimeDownloadDialog(showTasks: false, initialSearchQuery: title),
        ),
      );
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      return discoveryAiAcquireAction(
        context: context,
        readAppModel: () => ref.read(appProvider),
        domain: AiMediaAcquisitionDomain.novel,
        domainLabel: mediaLinkKindLabel(kind),
        onlineDomain: OnlineSourcesDomain.novel,
      );
    case MediaLinkKind.game:
      return discoveryAiAcquireAction(
        context: context,
        readAppModel: () => ref.read(appProvider),
        domain: AiMediaAcquisitionDomain.game,
        domainLabel: mediaLinkKindLabel(kind),
      );
    case MediaLinkKind.musicAlbum:
    case MediaLinkKind.musicTrack:
      return null;
  }
}

/// 打开作品图谱另一端在本机的条目：各模块已有的那个出口，不另起页面。
///
/// - 视频合集 → 切到视频 tab，由视频库页用它的合集出口打开（带远端上下文，
///   [requestVideoCollectionOpen]）；
/// - 单个视频 → 播放器（属于合集就作为合集一集打开，与统计页 / ctl 同一口径）；
/// - 书 / 有声书 → 漫画进作品页，其余与书架点卡同一条 [AppModel.openMedia]；
/// - 游戏 → 游戏详情页；
/// - 音乐曲目 → 曲目详情页（出现在哪些集 / 同一作品）；专辑 → 专辑页。
Future<void> openMediaLinkEntry({
  required BuildContext context,
  required WidgetRef ref,
  required MediaLinkEntry entry,
}) async {
  final AppModel appModel = ref.read(appProvider);
  final FushiDatabase db = appModel.database;
  final NavigatorState navigator = Navigator.of(context);
  final MediaLinkEndpoint e = entry.endpoint;
  switch (e.kind) {
    case MediaLinkKind.videoCollection:
      final int? id = collectionIdOfTagEntryKey(e.key);
      final MediaCollectionRow? target = id == null
          ? null
          : await db.getMediaCollectionById(id);
      if (target == null || !navigator.mounted) return;
      // 视频合集只由视频库页打开（[requestVideoCollectionOpen] 文件头）：成员可能是
      // Jellyfin / 互联上「本机没有」的集，只有视频库页持有解析它们的远端上下文。
      // 回到首页壳、切到视频 tab、发请求——与追踪卡片打开书架合集同一形态。
      if (!isHomeTabVisible(HomeTab.video, appModel.moduleVisibility)) {
        ScaffoldMessenger.of(navigator.context)
          ..hideCurrentSnackBar()
          ..showSnackBar(FushiSnackBar(content: Text(t.module_disabled_hint)));
        return;
      }
      Navigator.of(
        navigator.context,
        rootNavigator: true,
      ).popUntil((Route<Object?> route) => route.isFirst);
      homeShellTabNotifier.value = HomeTab.video;
      requestVideoCollectionOpen(target.id);
    case MediaLinkKind.videoEpisode:
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow? row = await repo.getByBookUid(e.key);
      if (row == null) return;
      final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
      if (!navigator.mounted) return;
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => VideoFushiPage.neutralized(
              bookUid: row.bookUid,
              repo: repo,
              playlistCollectionId:
                  primary[MediaKind.video.compositeKey(row.bookUid)],
            ),
          ),
        ),
      );
    case MediaLinkKind.book:
    case MediaLinkKind.audiobook:
      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey(e.key);
      if (item == null || !navigator.mounted) return;
      if (item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey) {
        unawaited(
          navigator.push<void>(
            adaptivePageRoute<void>(
              context: navigator.context,
              builder: (_) => MangaSeriesPage(
                target: ShelfMangaSeriesTarget(e.key, item: item),
              ),
            ),
          ),
        );
        return;
      }
      unawaited(
        appModel.openMedia(
          ref: ref,
          mediaSource: item.getMediaSource(appModel: appModel),
          item: item,
          waitUntilClosed: false,
        ),
      );
    case MediaLinkKind.game:
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => GalgameDetailPage(gameId: e.key, initialTab: 0),
          ),
        ),
      );
    case MediaLinkKind.musicTrack:
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => MusicTrackDetailPage(trackUid: e.key),
          ),
        ),
      );
    case MediaLinkKind.musicAlbum:
      final MusicAlbumRow? album = await db.getMusicAlbum(e.key);
      if (album == null) return;
      final List<MusicTrackRow> tracks = sortAlbumTracks(<MusicTrackRow>[
        for (final MusicTrackRow tr in await db.listMusicTracks(
          albumUid: album.albumUid,
        ))
          if (tr.deletedAt == null) tr,
      ]);
      final String? embedded = await musicAlbumEmbeddedCoverPath(db, album);
      if (!navigator.mounted) return;
      unawaited(
        navigator.push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (_) => MusicAlbumPage(
              album: album,
              tracks: tracks,
              embeddedCoverPath: embedded,
            ),
          ),
        ),
      );
  }
}
