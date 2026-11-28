/// 视频作品（剧集合集 / 散装电影）的「横幅…」面板装配：在线来源、片中来源与写入口
/// （[BannerPickerTarget]），面板本体见 `banner_picker_sheet.dart`。
///
/// - **在线**：刮削已经存下的全部背景图（作品图组 `video_metadata_images` 的
///   backdrop——刮削默认存 10 张、详情页只轮换 / 首页只铺第一张；附加图组里刮削写回
///   的 backdrop），再加作品的 TMDB 身份现拉一次完整资料里列出的背景图（经刮削
///   controller 的 [VideoBannerWorkFetcher]，与「手动指定作品」同一条链，AniDB /
///   MAL 只给海报、不在这里拉）。不引入新的刮削源（动画刮削白名单见
///   docs/agent/anime-scraping.md）。只在「在线服务」模块开着时提供。
/// - **片中**：已在盘上的分集画面——各集的封面 / 帧缩略图（`video_books.cover_path`）、
///   刮削的分集剧照（作品图组的 thumb、附加图组的 title_card），只留横版的；不另抽帧。
/// - **写入**：[MediaImageUserStore] 用户口径（`media_images` 的来源锁 v184，之后的
///   视频刮削 / 媒体服务器入库都不覆盖）；移除 = 只移除用户选的那张并解锁，作品图组里
///   的刮削背景归刮削管（所以当前横幅是刮削的时不出「移除」）。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/image_download.dart'
    show downloadImageToTempFile;
import 'package:fushi_engine/media/video/media_image_user_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_local_images.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/banner_target_writes.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_image_provider.dart'
    show metadataRemoteImage;
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;

/// 拉 [lookup] 指向作品的完整资料（刮削 controller 的 `fetchWorkForLookup`）；
/// provider 不可用返回 null。
typedef VideoBannerWorkFetcher =
    Future<VideoMetadataWork?> Function(VideoMetadataLookup lookup);

/// 在线候选的网格预览解码宽度（TMDB 原图很大，预览不按原图解）。
const int _onlinePreviewWidth = 480;

/// [owner] 对应的规范作品行（合集 → 剧集作品、视频 → 电影作品）；没刮过为 null。
Future<VideoMetadataWorkRow?> videoBannerWorkOf(
  FushiDatabase db,
  MediaImageOwner owner,
) => owner.collectionId != null
    ? db.getVideoMetadataWorkByCollection(owner.collectionId!)
    : db.getVideoMetadataWorkByBook(owner.bookUid!);

Future<List<MediaImageRow>> _mediaImagesOf(
  FushiDatabase db,
  MediaImageOwner owner,
) => owner.collectionId != null
    ? db.getMediaImagesForCollection(owner.collectionId!)
    : db.getMediaImagesForBook(owner.bookUid!);

String? _providerLabel(String provider) =>
    switch (VideoMetadataProviderKind.values.asNameMap()[provider]) {
      VideoMetadataProviderKind.tmdb => 'TMDB',
      VideoMetadataProviderKind.anidb => 'AniDB',
      VideoMetadataProviderKind.mal => 'MAL',
      VideoMetadataProviderKind.fanart => 'Fanart.tv',
      _ => null,
    };

/// 在线候选：已存的作品图组 backdrop（本地文件在就用本地的）→ 附加图组里刮削写回的
/// backdrop → [fetchWork] 现拉的 TMDB 背景图，按地址去重。现拉失败不挡已存的；
/// 什么都没有且现拉失败时抛那个错误。
Future<List<BannerCandidate>> loadVideoBannerOnlineCandidates({
  required FushiDatabase db,
  required MediaImageOwner owner,
  VideoBannerWorkFetcher? fetchWork,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final List<BannerCandidate> out = <BannerCandidate>[];
  final Set<String> seen = <String>{};
  final VideoMetadataWorkRow? work = await videoBannerWorkOf(db, owner);

  void addRemote(
    String id,
    String url, {
    String? label,
    int? width,
    int? height,
  }) {
    if (url.isEmpty || !seen.add(url)) return;
    out.add(
      BannerCandidate(
        id: id,
        preview: metadataRemoteImage(url, width: _onlinePreviewWidth),
        resolve: () => download(url),
        label: label,
        width: width,
        height: height,
        sourceUrl: url,
      ),
    );
  }

  if (work != null) {
    final List<VideoMetadataImageRow> rows =
        (await db.getVideoMetadataImages(workId: work.id))
            .where(
              (VideoMetadataImageRow r) =>
                  r.kind == VideoMetadataImageKind.backdrop.name,
            )
            .toList()
          ..sort(
            (VideoMetadataImageRow a, VideoMetadataImageRow b) =>
                a.position.compareTo(b.position),
          );
    for (final VideoMetadataImageRow row in rows) {
      final String? local = row.localPath;
      if (local != null && local.isNotEmpty && await File(local).exists()) {
        if (!seen.add(row.remoteUrl.isEmpty ? local : row.remoteUrl)) {
          continue;
        }
        out.add(
          BannerCandidate(
            id: 'video-work-${row.id}',
            preview: resizedFileImage(
              File(local),
              width: kBannerLocalPreviewWidth,
            ),
            resolve: () async => File(local),
            label: _providerLabel(row.provider),
            width: row.width,
            height: row.height,
            sourceUrl: row.remoteUrl.isEmpty ? null : row.remoteUrl,
          ),
        );
      } else {
        addRemote(
          'video-work-${row.id}',
          row.remoteUrl,
          label: _providerLabel(row.provider),
          width: row.width,
          height: row.height,
        );
      }
    }
  }
  for (final MediaImageRow row in await _mediaImagesOf(db, owner)) {
    if (row.userChosen || row.kind != MediaImageKind.backdrop.dbValue) {
      continue;
    }
    final String key = row.sourceUrl ?? row.path;
    if (!seen.add(key) || !await File(row.path).exists()) continue;
    out.add(
      BannerCandidate(
        id: 'video-media-${row.id}',
        preview: resizedFileImage(
          File(row.path),
          width: kBannerLocalPreviewWidth,
        ),
        resolve: () async => File(row.path),
        sourceUrl: row.sourceUrl,
      ),
    );
  }
  Exception? failure;
  if (work != null && fetchWork != null) {
    final List<VideoMetadataLookup> lookups = <VideoMetadataLookup>[
      for (final VideoMetadataLookup lookup in await VideoMetadataDatabaseStore(
        db,
      ).lookupsForWorkRow(work))
        if (lookup.provider == VideoMetadataProviderKind.tmdb) lookup,
    ];
    for (final VideoMetadataLookup lookup in lookups.take(1)) {
      try {
        final VideoMetadataWork? fetched = await fetchWork(lookup);
        int i = 0;
        for (final VideoMetadataImage image
            in fetched?.images ?? const <VideoMetadataImage>[]) {
          if (image.kind != VideoMetadataImageKind.backdrop ||
              image.seasonNumber != null ||
              image.episodeNumber != null) {
            continue;
          }
          addRemote('video-tmdb-${i++}', image.url, label: 'TMDB');
        }
      } on Exception catch (e) {
        failure = e;
      }
    }
  }
  if (out.isEmpty && failure != null) throw failure;
  return out;
}

/// 片中候选：作品各集（合集成员 / 电影本身）的封面 / 帧缩略图、作品图组的分集剧照
/// （thumb）、附加图组的 title_card，只留横版的（[loadLocalBannerCandidates]）。
Future<List<BannerCandidate>> loadVideoBannerFromWork({
  required FushiDatabase db,
  required MediaImageOwner owner,
}) async {
  final List<String> uids = owner.collectionId != null
      ? <String>[
          for (final MediaCollectionItemRow item in await db.getCollectionItems(
            owner.collectionId!,
          ))
            if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
        ]
      : <String>[owner.bookUid!];
  final List<VideoBookRow> books = await db.getVideoBooksByBookUids(uids);
  final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
    for (final VideoBookRow b in books) b.bookUid: b,
  };
  final List<BannerLocalImage> images = <BannerLocalImage>[];
  for (final String uid in uids) {
    final VideoBookRow? book = byUid[uid];
    if (book == null) continue;
    final String label = book.title;
    for (final VideoMetadataEpisodeRow episode
        in await db.getVideoMetadataEpisodesByBook(uid)) {
      for (final VideoMetadataImageRow row in await db.getVideoMetadataImages(
        episodeId: episode.id,
      )) {
        final String? local = row.localPath;
        if (local != null && local.isNotEmpty) {
          images.add((path: local, label: label));
        }
      }
    }
    for (final MediaImageRow row in await db.getMediaImagesForBook(uid)) {
      if (row.kind == MediaImageKind.titleCard.dbValue) {
        images.add((path: row.path, label: label));
      }
    }
    if (book.coverPath case final String cover when cover.isNotEmpty) {
      images.add((path: cover, label: label));
    }
  }
  return loadLocalBannerCandidates(images, idPrefix: 'video-still');
}

/// 装配一部视频作品（[owner] = 剧集合集或散装电影）的面板：读当前横幅与来源锁，接上
/// 在线 / 片中来源与 [MediaImageUserStore] 用户口径的写入口。
///
/// [onlineEnabled] = 「在线服务」模块开着；[fetchWork] = 刮削 controller 的现拉入口
/// （没装配刮削时为 null，只给已存的图）。[store] / [download] 是测试接缝。
Future<BannerPickerTarget> loadVideoBannerPickerTarget({
  required FushiDatabase db,
  required MediaImageOwner owner,
  required bool onlineEnabled,
  VideoBannerWorkFetcher? fetchWork,
  MediaImageUserStore? store,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final MediaImageUserStore writer =
      store ?? MediaImageUserStore(db, downloadImage: download);
  final MediaImageRow? user = await currentMediaImageBackdrop(
    db,
    owner,
    userChosenOnly: true,
  );
  final ImageProvider? scraped = user != null
      ? null
      : await _scrapedBackdrop(db, owner);
  return BannerPickerTarget(
    fromWorkLabel: t.media_banner_source_from_video,
    fromWorkEmptyMessage: t.media_banner_video_empty,
    fromWorkFailedMessage: t.media_banner_local_failed,
    onlineEmptyMessage: t.media_banner_video_online_empty,
    current: user != null ? resizedFileImage(File(user.path)) : scraped,
    currentUserChosen: user != null,
    loadOnline: onlineEnabled
        ? () => loadVideoBannerOnlineCandidates(
            db: db,
            owner: owner,
            fetchWork: fetchWork,
            download: download,
          )
        : null,
    loadFromWork: () => loadVideoBannerFromWork(db: db, owner: owner),
    download: download,
    apply: (File file, {String? sourceUrl}) =>
        applyMediaImageBannerFile(writer, owner, file, sourceUrl: sourceUrl),
    clear: user == null
        ? null
        : () => writer.clearUserImage(owner, MediaImageKind.backdrop),
  );
}

/// 当前铺着的刮削背景（详情页同一顺序：作品图组本地 → 附加图组 → 作品图组远程）。
Future<ImageProvider?> _scrapedBackdrop(
  FushiDatabase db,
  MediaImageOwner owner,
) async {
  final VideoMetadataWorkRow? work = await videoBannerWorkOf(db, owner);
  final List<VideoMetadataImageRow> rows = work == null
      ? const <VideoMetadataImageRow>[]
      : ((await db.getVideoMetadataImages(workId: work.id))
            .where(
              (VideoMetadataImageRow r) =>
                  r.kind == VideoMetadataImageKind.backdrop.name,
            )
            .toList()
          ..sort(
            (VideoMetadataImageRow a, VideoMetadataImageRow b) =>
                a.position.compareTo(b.position),
          ));
  for (final VideoMetadataImageRow row in rows) {
    final String? local = row.localPath;
    if (local != null && local.isNotEmpty && await File(local).exists()) {
      return resizedFileImage(File(local));
    }
  }
  for (final MediaImageRow row in await _mediaImagesOf(db, owner)) {
    if (row.kind == MediaImageKind.backdrop.dbValue &&
        await File(row.path).exists()) {
      return resizedFileImage(File(row.path));
    }
  }
  for (final VideoMetadataImageRow row in rows) {
    if (row.remoteUrl.isNotEmpty) return metadataRemoteImage(row.remoteUrl);
  }
  return null;
}
