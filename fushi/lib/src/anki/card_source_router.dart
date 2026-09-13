import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_source_fingerprint.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show buildCollectionReaderMediaItem;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// Resolve a portable locator through the current library. URLs never supply
/// paths, remote credentials, or arbitrary routes to the navigation layer.
Future<void> openCardSource({
  required WidgetRef ref,
  required CardSourceLink link,
}) =>
    ExternalMediaNavigation.instance.navigate(
      () => _openCardSource(ref: ref, link: link),
    );

Future<void> _openCardSource({
  required WidgetRef ref,
  required CardSourceLink link,
}) async {
  final AppModel app = ref.read(appProvider);
  final NavigatorState? navigator = app.navigatorKey.currentState;
  if (navigator == null || app.isMigrationReadonly) return;
  final EpubBookRow? book = link.kind == CardSourceKind.video
      ? null
      : await app.database.getEpubBookByUid(link.uid);
  final VideoBookRepository videos = VideoBookRepository(app.database);
  final VideoBookRow? video = link.kind == CardSourceKind.video
      ? await videos.getByBookUid(link.uid)
      : null;
  if ((link.kind == CardSourceKind.video && video == null) ||
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
  if (video != null) {
    try {
      if (link.fingerprint == null ||
          !await VideoSourceFingerprint.instance.matches(
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
  final BaseAnkiRepository repository =
      Platform.isIOS && configured is AnkiMobileRepository
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
    onReturnToReading: previousReturn ??
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
  if (video != null) {
    final Map<String, int> collections =
        await app.database.getPrimaryCollectionIdByEntry();
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
            : ReaderFushiPage(
                item: item,
                bookKey: row.bookKey,
                initialBookmarkJump: bookmark,
              ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
}
