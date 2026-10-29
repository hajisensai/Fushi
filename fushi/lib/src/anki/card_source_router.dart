import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/mining/mined_origin_navigation.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_source_fingerprint.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show buildCollectionReaderMediaItem;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// Finds the local book/manga row a card link points at. The link's `uid` is
/// minted per device at import (sync / interconnect re-import a book and get a
/// fresh one), so a card mined on another device only matches here through the
/// cross-device `bookKey`. `uid` goes first: it survives a local rename, which
/// changes the title-derived `bookKey`.
Future<EpubBookRow?> resolveCardSourceBook(
  FushiDatabase db,
  CardSourceLink link,
) async {
  final EpubBookRow? byUid = await db.getEpubBookByUid(link.uid);
  if (byUid != null) return byUid;
  final String? bookKey = link.bookKey;
  return bookKey == null ? null : db.getEpubBook(bookKey);
}

/// 在互联 host 的视频清单里找卡片链接指向的那条。远端视频的 id 就是 host 库里的
/// `bookUid`，与卡片链接的 `uid` 同一个键；找不到返回 null。
///
/// 卡片可能制在别的设备上（电脑 / 无头服务端有原文件，本机只有远端占位），本机库里
/// 没有对应的 VideoBookRow——只查本地库会误报「此设备没有对应来源」，而 host 明明有。
RemoteVideoInfo? findRemoteVideoForCardSource(
  Iterable<RemoteVideoInfo> videos,
  CardSourceLink link,
) {
  if (link.kind != CardSourceKind.video) return null;
  for (final RemoteVideoInfo video in videos) {
    // host 列出但没有字节可给的条目（网络流书 / `.strm`，BUG-3875）跳过：点过去
    // 只会撞 `/streamurl` 404，按「没有来源」提示才是真话。
    if (video.id == link.uid && video.peerPlayable) return video;
  }
  return null;
}

/// 本地库没有该视频时，去已配对的互联 host 取它的清单并按 [link] 找条目。互联未启用 /
/// 未配对 / host 不可达都返回 null（调用方按「没有来源」提示，不吞成别的错）。
Future<({RemoteVideoInfo info, InterconnectSyncBackend client})?>
resolveRemoteCardSourceVideo(
  AppModel app,
  WidgetRef ref,
  CardSourceLink link,
) async {
  final SyncRepository syncRepo = SyncRepository(app.database);
  if (!await syncRepo.isInterconnectEnabled()) return null;
  final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
  if (!await backend.restoreAuth(syncRepo)) return null;
  try {
    final List<RemoteVideoInfo> videos = await ref
        .read(remoteLibraryCacheProvider)
        .read<List<RemoteVideoInfo>>(
          sourceId: backend.remoteLibrarySourceId,
          key: RemoteLibraryCacheKeys.videos,
          fetch: backend.listRemoteVideos,
        );
    final RemoteVideoInfo? info = findRemoteVideoForCardSource(videos, link);
    return info == null ? null : (info: info, client: backend);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('card_source.remoteVideo', error, stack);
    return null;
  }
}

/// Resolve a portable locator through the current library. URLs never supply
/// paths, remote credentials, or arbitrary routes to the navigation layer.
Future<void> openCardSource({
  required WidgetRef ref,
  required CardSourceLink link,
}) => ExternalMediaNavigation.instance.navigate(
  () => _openCardSource(ref: ref, link: link),
);

Future<void> _openCardSource({
  required WidgetRef ref,
  required CardSourceLink link,
}) async {
  final AppModel app = ref.read(appProvider);
  final NavigatorState? navigator = app.navigatorKey.currentState;
  if (navigator == null || app.isMigrationReadonly) return;
  // 游戏 / 音乐出处没有「回看并改原卡」的审阅形态（游戏台词不在可重放的正文里，
  // 音乐只是一段原曲）：直接落到出处本身，不建 [SourceReviewSession]。
  switch (link.kind) {
    case CardSourceKind.game:
      await openGameOrigin(
        navigator: navigator,
        db: app.database,
        gameId: link.uid,
      );
      return;
    case CardSourceKind.music:
      await playMusicOriginClip(
        app: app,
        trackUid: link.uid,
        positionMs: link.startMs ?? 0,
      );
      return;
    case CardSourceKind.book:
    case CardSourceKind.manga:
    case CardSourceKind.video:
      break;
  }
  final EpubBookRow? book = link.kind == CardSourceKind.video
      ? null
      : await resolveCardSourceBook(app.database, link);
  final VideoBookRepository videos = VideoBookRepository(app.database);
  final VideoBookRow? video = link.kind == CardSourceKind.video
      ? await videos.getByBookUid(link.uid)
      : null;
  final ({RemoteVideoInfo info, InterconnectSyncBackend client})? remote =
      link.kind == CardSourceKind.video && video == null
      ? await resolveRemoteCardSourceVideo(app, ref, link)
      : null;
  if ((link.kind == CardSourceKind.video && video == null && remote == null) ||
      (link.kind != CardSourceKind.video && book == null)) {
    FushiToast.show(msg: t.card_source_review_media_missing);
    return;
  }
  if (book != null) {
    final BookFormat format = BookFormat.parseOrEpub(book.format);
    if ((link.kind == CardSourceKind.manga && format != BookFormat.manga) ||
        (link.kind == CardSourceKind.book && format != BookFormat.epub)) {
      FushiToast.show(msg: t.card_source_review_invalid);
      return;
    }
    if (link.kind == CardSourceKind.book &&
        (link.chapterIndex == null ||
            link.chapterIndex! >= book.chapterCount)) {
      FushiToast.show(msg: t.card_source_review_invalid);
      return;
    }
  }
  // BUG-3490：无指纹的链接只可能指向在线内容身份（CardSourceLink 校验保证），
  // 没有本地字节可比，按库身份直接回看在线播放。
  if (video != null && link.fingerprint != null) {
    try {
      if (!await VideoSourceFingerprint.instance.matches(
        video.videoPath,
        link.fingerprint!,
      )) {
        FushiToast.show(msg: t.card_source_review_fingerprint_mismatch);
        return;
      }
    } catch (_) {
      FushiToast.show(msg: t.card_source_review_local_required);
      return;
    }
  }

  final MediaItem? previousItem = app.currentMediaItem;
  final MediaSource? previousSource = app.currentMediaSource;
  final String? previousVideoUid =
      ExternalMediaNavigation.instance.activeVideoUid;
  final Future<void> Function()? previousReturn =
      ExternalMediaNavigation.instance.returnToReading;
  if (!await ExternalMediaNavigation.instance.closeActive()) {
    FushiToast.show(msg: t.card_source_review_failed);
    return;
  }
  // A background audiobook must finish its normal final write before the
  // review installs temporary persistence callbacks on a new controller.
  await app.audiobookSession.stop();
  if (!navigator.mounted) return;

  final BaseAnkiRepository configured = ref.read(ankiRepositoryProvider);
  // provider 恒返回装饰器链（待发队列 / 自动重排），`configured is
  // AnkiMobileRepository` 永远不成立——必须拆装饰器判「卡落在哪」。
  final BaseAnkiRepository repository =
      Platform.isIOS && minesOnLocalAnkiMobile(configured)
      ? RemoteMiningAnkiRepository(
          local: configured,
          client: app.createRemoteMiningClient(),
        )
      : configured;
  final SourceReviewSession session = SourceReviewSession(
    link: link,
    repository: repository,
    draftStore: SourceReviewDraftStore(
      Directory('${app.appDirectory.path}/card_source_drafts'),
    ),
    onReturnToReading:
        previousReturn ??
        () => ExternalMediaNavigation.instance.navigate(() async {
          if (!await ExternalMediaNavigation.instance.closeActive()) return;
          await app.audiobookSession.stop();
          if (!navigator.mounted) return;
          if (previousVideoUid != null) {
            final VideoBookRow? previous = await videos.getByBookUid(
              previousVideoUid,
            );
            if (previous != null && navigator.mounted) {
              unawaited(
                navigator.push<void>(
                  adaptivePageRoute<void>(
                    context: navigator.context,
                    builder: (_) => VideoFushiPage.neutralized(
                      bookUid: previousVideoUid,
                      repo: videos,
                    ),
                  ),
                ),
              );
            }
          } else if (previousItem != null && previousSource != null) {
            await app.openMedia(
              ref: ref,
              mediaSource: previousSource,
              item: previousItem,
              waitUntilClosed: false,
            );
          }
          await WidgetsBinding.instance.endOfFrame;
        }),
  );
  if (remote != null) {
    // 远端条目：身份是 host 的 bookUid，字节指纹只有 host 的原文件能对，本机无从核验
    // （播放页对远端复习同样不比指纹）。
    unawaited(
      navigator.push<void>(
        adaptivePageRoute<void>(
          context: navigator.context,
          builder: (_) => SourceReviewScope(
            session: session,
            child: VideoFushiPage.neutralizedRemote(
              info: remote.info,
              repo: videos,
              client: remote.client,
              sourceReview: link,
              sourceReviewSession: session,
              initialEpisodeIndex: link.episodeIndex,
            ),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    return;
  }
  if (video != null) {
    final Map<String, int> collections = await app.database
        .getPrimaryCollectionIdByEntry();
    if (!navigator.mounted) return;
    unawaited(
      navigator.push<void>(
        adaptivePageRoute<void>(
          context: navigator.context,
          builder: (_) => SourceReviewScope(
            session: session,
            child: VideoFushiPage.neutralized(
              bookUid: video.bookUid,
              repo: videos,
              playlistCollectionId:
                  collections[MediaKind.video.compositeKey(video.bookUid)],
              sourceReview: link,
              sourceReviewSession: session,
            ),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    return;
  }
  final EpubBookRow row = book!;
  final BookFormat format = BookFormat.parseOrEpub(row.format);
  final MediaItem item = buildCollectionReaderMediaItem(
    bookKey: row.bookKey,
    title: row.title,
    format: format,
  );
  final Bookmark bookmark = Bookmark(
    sectionIndex: link.chapterIndex ?? 0,
    normCharOffset: 0,
    charAnchor: link.charOffset,
    charAnchorLength: link.charLength,
    preserveSavedPosition: true,
    label: '',
    createdAt: DateTime.now(),
  );
  await app.openMedia(
    ref: ref,
    mediaSource: item.getMediaSource(appModel: app),
    item: item,
    recordHistory: false,
    waitUntilClosed: false,
    launchPageBuilder: () => SourceReviewScope(
      session: session,
      child: FushiAppUiScaleNeutralizer(
        child: link.kind == CardSourceKind.manga
            ? MangaFushiPage(
                item: item,
                bookKey: row.bookKey,
                sourceReview: link,
              )
            : LyricsThemeHost(
                child: ReaderFushiPage(
                  item: item,
                  bookKey: row.bookKey,
                  initialBookmarkJump: bookmark,
                ),
              ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
}
