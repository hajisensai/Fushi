import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/anki/card_source_open_feedback.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/mining/mined_origin_navigation.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/storage/app_storage_areas.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoFingerprintSource, RemoteVideoFingerprintUnavailable;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show buildCollectionReaderMediaItem;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
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

/// 远端条目的字节核验（拍板台 IFCPPprIpT）：链接带指纹时，用 host 对同一个文件算的
/// 指纹比对（与本地卡同口径，防 host 上同名 bookUid 换成了别的片子）。链接不带指纹
/// （在线内容身份，BUG-3490）、host 不支持指纹（老 host 无该端点）或 host 还没算好
/// （后台预热没轮到，拍板台 left3657：互联是用户自己的设备，不为核验让用户干等
/// 整文件哈希）时按 bookUid 身份放行。新 host 担保不了字节不会走到这里：
/// [RemoteVideoFingerprintSource.fetchRemoteVideoFingerprint] 抛
/// `RemoteVideoFingerprintUnavailable`，按取不到来源处理（BUG-4782）。
bool cardSourceHostFingerprintAccepted({
  required String? linkFingerprint,
  required String? hostFingerprint,
}) =>
    linkFingerprint == null ||
    hostFingerprint == null ||
    linkFingerprint == hostFingerprint;

/// 互联 host 上卡片指向的那条视频，连同取它字节用的客户端。
typedef RemoteCardSourceVideo = ({
  RemoteVideoInfo info,
  InterconnectSyncBackend client,
});

/// 去 host 找卡片来源的结果：[value] / [cancelled] 同 [CardSourceAwaited]；
/// [fingerprintMismatch] 为 true 表示 host 上同 bookUid 的那份字节与卡片指纹不符
/// （此时 [value] 为 null，调用方提示「指纹不符」而不是「没有来源」）；
/// [hostUnreadable] 为 true 表示 host 清单里有这条、却读不了它的文件（被移走 / 删除 /
/// 读不了，BUG-4782 的 `RemoteVideoFingerprintUnavailable`），调用方提示
/// `card_source_review_host_unreadable` 而不是笼统的「此设备没有对应来源」（拍板台
/// left3657）。
typedef RemoteCardSourceLookup = ({
  RemoteCardSourceVideo? value,
  bool cancelled,
  bool fingerprintMismatch,
  bool hostUnreadable,
});

/// 在 [listing]（host 视频清单）里按 [link] 找条目，链接带指纹时再请 [fingerprints]
/// 对 host 要串流的同一个文件核验字节（`wait: false`：只要 host 已算好的，不让它当场
/// 整文件哈希）。找不到 → `info == null`；host 字节不符 → `fingerprintMismatch == true`。
/// host 读不了文件抛 `RemoteVideoFingerprintUnavailable`，网络失败原样抛给调用方。
Future<({RemoteVideoInfo? info, bool fingerprintMismatch})>
matchRemoteCardSourceVideo({
  required Future<List<RemoteVideoInfo>> listing,
  required RemoteVideoFingerprintSource fingerprints,
  required CardSourceLink link,
}) async {
  final RemoteVideoInfo? info = findRemoteVideoForCardSource(
    await listing,
    link,
  );
  final String? linkFingerprint = link.fingerprint;
  if (info == null || linkFingerprint == null) {
    return (info: info, fingerprintMismatch: false);
  }
  final String? hostFingerprint = await fingerprints
      .fetchRemoteVideoFingerprint(
        info.id,
        episodeIndex: link.episodeIndex ?? 0,
        wait: false,
      );
  return cardSourceHostFingerprintAccepted(
        linkFingerprint: linkFingerprint,
        hostFingerprint: hostFingerprint,
      )
      ? (info: info, fingerprintMismatch: false)
      : (info: null, fingerprintMismatch: true);
}

/// 本地库没有该视频（或本地那份字节对不上）时，去已配对的互联 host 取它的清单并按
/// [link] 找条目，再请 host 核验字节指纹（[matchRemoteCardSourceVideo]）。互联未启用 /
/// 未配对 / host 不可达 / 清单里没有都是 `value: null`（调用方按「没有来源」提示，不吞
/// 成别的错）；host 字节与卡片不符是 `fingerprintMismatch: true`；host 清单里有、却读
/// 不了文件是 `hostUnreadable: true`；用户在等待时取消是 `cancelled: true`（调用方静默
/// 放弃这次跳转）。
///
/// 要真去 host 等结果时（清单缓存不新鲜：首次 / 过了 TTL / 有在途请求；或要问 host
/// 指纹——新 host 只答已算好的、立即返回，不认 `wait=0` 的老 host 仍会当场算完整个
/// 文件，几 GB 的片子要几十秒），整段等待在 [navigator] 上挂可取消的进度反馈
/// （[awaitWithCardSourceOpeningFeedback]，反馈 7gkdbfCXQ0）；新鲜缓存命中且不用核验
/// 指纹是立即可得的，不弹对话框免得闪一下。
Future<RemoteCardSourceLookup> resolveRemoteCardSourceVideo(
  AppModel app,
  WidgetRef ref,
  CardSourceLink link, {
  required NavigatorState navigator,
}) async {
  const RemoteCardSourceLookup unavailable = (
    value: null,
    cancelled: false,
    fingerprintMismatch: false,
    hostUnreadable: false,
  );
  final SyncRepository syncRepo = SyncRepository(app.database);
  if (!await syncRepo.isInterconnectEnabled()) return unavailable;
  final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
  if (!await backend.restoreAuth(syncRepo)) return unavailable;
  try {
    final RemoteLibraryCache cache = ref.read(remoteLibraryCacheProvider);
    final String sourceId = backend.remoteLibrarySourceId;
    const String key = RemoteLibraryCacheKeys.videos;
    // 与 [RemoteLibraryCache.read] 同一判据：有在途请求（如视频页正在下拉刷新）
    // 时 read 会等它，这里也算「不立即可得」、照样挂反馈。
    final bool cached = cache.wouldReadImmediately(
      sourceId: sourceId,
      key: key,
    );
    final Future<List<RemoteVideoInfo>> listing = cache
        .read<List<RemoteVideoInfo>>(
          sourceId: sourceId,
          key: key,
          fetch: backend.listRemoteVideos,
        );
    final Future<({RemoteVideoInfo? info, bool fingerprintMismatch})> work =
        matchRemoteCardSourceVideo(
          listing: listing,
          fingerprints: backend,
          link: link,
        );
    final CardSourceAwaited<({RemoteVideoInfo? info, bool fingerprintMismatch})>
    matched = cached && link.fingerprint == null
        ? (value: await work, cancelled: false)
        : await awaitWithCardSourceOpeningFeedback<
            ({RemoteVideoInfo? info, bool fingerprintMismatch})
          >(navigator: navigator, work: work);
    if (matched.cancelled) {
      return (
        value: null,
        cancelled: true,
        fingerprintMismatch: false,
        hostUnreadable: false,
      );
    }
    final RemoteVideoInfo? info = matched.value!.info;
    return (
      value: info == null ? null : (info: info, client: backend),
      cancelled: false,
      fingerprintMismatch: matched.value!.fingerprintMismatch,
      hostUnreadable: false,
    );
  } on RemoteVideoFingerprintUnavailable catch (error, stack) {
    // host 清单里有这条，却担保不了它的字节（文件被移走 / 删除 / 读不了，BUG-4782）：
    // 不放行，但要说清是 host 那边读不了，不是「此设备没有对应来源」。
    ErrorLogService.instance.log('card_source.remoteVideo', error, stack);
    return (
      value: null,
      cancelled: false,
      fingerprintMismatch: false,
      hostUnreadable: true,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('card_source.remoteVideo', error, stack);
    return unavailable;
  }
}

/// 本机同 uid 视频行的字节核验结果。
enum CardSourceLocalVideoCheck {
  /// 本机这份可作卡片来源（字节一致，或链接不带指纹）。
  verified,

  /// 本机库里没有同 uid 的行。
  absent,

  /// 有同 uid 的行，但字节与卡片指纹不符。
  mismatch,

  /// 有同 uid 的行，但读不了它的字节（文件不在 / 不是本地文件 / 算的期间被改写）。
  unreadable,
}

/// 核验本机同 uid 的那份视频（[videoPath] 为 null = 本机没有这一行）。视频 uid 由
/// 文件名派生、跨设备会撞，字节对不上的不是这张卡的来源。BUG-3490：无指纹的链接只
/// 可能指向在线内容身份（CardSourceLink 校验保证），没有本地字节可比，按库身份放行。
Future<CardSourceLocalVideoCheck> checkLocalCardSourceVideo({
  required String? videoPath,
  required String? linkFingerprint,
  required VideoSourceFingerprint fingerprints,
}) async {
  if (videoPath == null) return CardSourceLocalVideoCheck.absent;
  if (linkFingerprint == null) return CardSourceLocalVideoCheck.verified;
  try {
    return await fingerprints.matches(videoPath, linkFingerprint)
        ? CardSourceLocalVideoCheck.verified
        : CardSourceLocalVideoCheck.mismatch;
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('card_source.localVideo', error, stack);
    return CardSourceLocalVideoCheck.unreadable;
  }
}

/// 视频卡片回跳的去向。
enum CardSourceVideoAction {
  openLocal,
  openRemote,

  /// 用户在等 host 时取消：静默放弃这次跳转。
  cancelled,

  /// 提示 `card_source_review_fingerprint_mismatch`。
  fingerprintMismatch,

  /// 提示 `card_source_review_host_unreadable`（host 清单里有、却读不了文件）。
  hostUnreadable,

  /// 提示 `card_source_review_local_required`。
  localRequired,

  /// 提示 `card_source_review_media_missing`。
  mediaMissing,
}

/// 由本机核验结果 [local] 与去 host 找的结果 [lookup]（本机已核验通过时不去找，为
/// null）决定视频卡片回跳的去向：本机通过 → 本地播；否则 host 有同一份字节 → 在线播；
/// 都没有时，任一侧字节不符优先提示「不一致」，其次 host 读不了文件提示「host 读不了」
/// （本机那份也读不了时让用户去「先下载」也下不成），再次本机读不了提示「先下载」，
/// 最后才是「没有来源」。
CardSourceVideoAction decideCardSourceVideoAction({
  required CardSourceLocalVideoCheck local,
  required RemoteCardSourceLookup? lookup,
}) {
  if (local == CardSourceLocalVideoCheck.verified) {
    return CardSourceVideoAction.openLocal;
  }
  if (lookup?.cancelled ?? false) return CardSourceVideoAction.cancelled;
  if (lookup?.value != null) return CardSourceVideoAction.openRemote;
  if (local == CardSourceLocalVideoCheck.mismatch ||
      (lookup?.fingerprintMismatch ?? false)) {
    return CardSourceVideoAction.fingerprintMismatch;
  }
  if (lookup?.hostUnreadable ?? false) {
    return CardSourceVideoAction.hostUnreadable;
  }
  if (local == CardSourceLocalVideoCheck.unreadable) {
    return CardSourceVideoAction.localRequired;
  }
  return CardSourceVideoAction.mediaMissing;
}

/// Resolve a portable locator through the current library. URLs never supply
/// paths, remote credentials, or arbitrary routes to the navigation layer.
/// 「回到出处」的跳转动作签名（[openCardSource]）。
typedef CardSourceOpener =
    Future<void> Function({
      required WidgetRef ref,
      required CardSourceLink link,
    });

/// 复习页「回到出处」各入口（顶栏图标、媒体胶囊、例句卡 ↩、卡面来源链接）共用的跳转动作。
/// 默认就是 [openCardSource]；做成 provider 是为了让 widget 测试能确认这些入口落到同一个动作上。
final Provider<CardSourceOpener> cardSourceOpenerProvider =
    Provider<CardSourceOpener>((Ref ref) => openCardSource);

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
  VideoBookRow? chosenVideo;
  RemoteCardSourceVideo? chosenRemote;
  if (link.kind == CardSourceKind.video) {
    final VideoBookRow? localRow = await videos.getByBookUid(link.uid);
    final CardSourceLocalVideoCheck local = await checkLocalCardSourceVideo(
      videoPath: localRow?.videoPath,
      linkFingerprint: link.fingerprint,
      fingerprints: VideoSourceFingerprint.instance,
    );
    // 拍板台 IFCPPprIpT：本机没有（或字节对不上）就经互联在 host 上找同一份字节在线播
    // ——远程播放 host 视频制的卡、以及在别的设备本地制的卡都走这里。
    final RemoteCardSourceLookup? lookup =
        local == CardSourceLocalVideoCheck.verified
        ? null
        : await resolveRemoteCardSourceVideo(
            app,
            ref,
            link,
            navigator: navigator,
          );
    if (lookup != null && !navigator.mounted) return;
    switch (decideCardSourceVideoAction(local: local, lookup: lookup)) {
      case CardSourceVideoAction.openLocal:
        chosenVideo = localRow;
      case CardSourceVideoAction.openRemote:
        chosenRemote = lookup!.value;
      case CardSourceVideoAction.cancelled:
        return;
      case CardSourceVideoAction.fingerprintMismatch:
        FushiToast.show(msg: t.card_source_review_fingerprint_mismatch);
        return;
      case CardSourceVideoAction.hostUnreadable:
        FushiToast.show(msg: t.card_source_review_host_unreadable);
        return;
      case CardSourceVideoAction.localRequired:
        FushiToast.show(msg: t.card_source_review_local_required);
        return;
      case CardSourceVideoAction.mediaMissing:
        FushiToast.show(msg: t.card_source_review_media_missing);
        return;
    }
  }
  // 下方路由回调会捕获它们：用 final 副本保住空安全提升。
  final VideoBookRow? video = chosenVideo;
  final RemoteCardSourceVideo? remote = chosenRemote;
  if (link.kind != CardSourceKind.video && book == null) {
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
          targetResetNotice: () => t.anki_mine_to_server_target_reset,
        )
      : configured;
  final SourceReviewSession session = SourceReviewSession(
    link: link,
    repository: repository,
    draftStore: SourceReviewDraftStore(
      Directory(
        AppStorageArea.cardSourceDrafts.pathUnder(app.appDirectory.path),
      ),
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
    // 远端条目：身份是 host 的 bookUid，字节已由 host 对原文件算指纹核验过
    // （[resolveRemoteCardSourceVideo]），播放页对远端复习不再比本地指纹。
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
