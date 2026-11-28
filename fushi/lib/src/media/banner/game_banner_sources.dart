/// 游戏的「横幅…」面板装配：在线来源与写入口（[BannerPickerTarget]），面板本体见
/// `banner_picker_sheet.dart`。
///
/// - **在线**：游戏已绑的元数据源里能给横图的——VNDB 这部 VN 的截图（实机画面，
///   只留成人 / 暴力分级都不高于 `kVndbScreenshotMaxRating` 的，
///   [VndbMetadataAdapter.fetchScreenshots]），以及各源存下的 draft 里的
///   `backdropUrl`。bgm / DLsite 只给竖版封面，不在这里拉。只在「在线服务」模块
///   开着时提供（与游戏刮削同一道门）。
/// - **游戏中**：不提供。app 没有在本地留游戏截图（制卡截图进 Anki，不在库里），
///   不为这里另截一张。
/// - **写入**：`ItemScrapeStore` 用户口径（`item_images` v183 来源锁，之后的游戏
///   刮削 `GalgameRepository.applyScrapedBackdrop` 不覆盖）；移除 = 解锁。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:fushi_engine/media/metadata/image_download.dart'
    show downloadImageToTempFile;
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/media/banner/banner_target_writes.dart';
import 'package:fushi/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart'
    show GalgameMetadataException;
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;
import 'package:fushi/src/utils/net/app_http_image.dart';

/// 游戏 [gameId] 的在线候选：VNDB 截图 + 各源 draft 的 `backdropUrl`，按地址去重。
/// VNDB 失败不挡别的；一张都没有且失败时抛那个错误。
Future<List<BannerCandidate>> loadGameBannerOnlineCandidates({
  required FushiDatabase db,
  required String gameId,
  VndbMetadataAdapter Function()? vndbFactory,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final List<BannerCandidate> out = <BannerCandidate>[];
  final Set<String> seen = <String>{};
  void add(
    String id,
    String url, {
    String? thumbnail,
    String? label,
    int? width,
    int? height,
  }) {
    if (url.isEmpty || !seen.add(url)) return;
    out.add(
      BannerCandidate(
        id: id,
        preview: AppHttpImage(thumbnail ?? url),
        resolve: () => download(url),
        label: label,
        width: width,
        height: height,
        sourceUrl: url,
      ),
    );
  }

  final List<GalgameSourceRow> sources = await db.getGalgameSources(gameId);
  for (final GalgameSourceRow row in sources) {
    final GalgameMetadataDraft? draft = _decodeDraft(row.dataJson);
    final String? url = draft?.backdropUrl;
    if (url != null) add('game-${row.source}-backdrop', url);
  }
  GalgameMetadataException? failure;
  final String? vndbId = sources
      .where(
        (GalgameSourceRow r) =>
            r.source == GalgameMetadataSource.vndb.key &&
            (r.externalId?.trim().isNotEmpty ?? false),
      )
      .map((GalgameSourceRow r) => r.externalId!.trim())
      .firstOrNull;
  if (vndbId != null) {
    final VndbMetadataAdapter vndb =
        vndbFactory?.call() ?? VndbMetadataAdapter();
    try {
      int i = 0;
      for (final VndbScreenshot shot in await vndb.fetchScreenshots(vndbId)) {
        add(
          'game-vndb-${i++}',
          shot.url,
          thumbnail: shot.thumbnail,
          label: 'VNDB',
          width: shot.width,
          height: shot.height,
        );
      }
    } on GalgameMetadataException catch (e) {
      failure = e;
    } finally {
      if (vndbFactory == null) vndb.close();
    }
  }
  if (out.isEmpty && failure != null) throw failure;
  return out;
}

GalgameMetadataDraft? _decodeDraft(String raw) {
  try {
    final Object? json = jsonDecode(raw);
    return json is Map ? GalgameMetadataDraft.fromJson(json) : null;
  } on FormatException {
    return null;
  }
}

/// 装配游戏 [gameId] 的面板：读当前横幅与来源锁，接上在线来源与 [ItemScrapeStore]
/// 用户口径的写入口。[onlineEnabled] = 「在线服务」模块开着。[store] /
/// [vndbFactory] / [download] 是测试接缝。
Future<BannerPickerTarget> loadGameBannerPickerTarget({
  required FushiDatabase db,
  required String gameId,
  required bool onlineEnabled,
  ItemScrapeStore? store,
  VndbMetadataAdapter Function()? vndbFactory,
  Future<File> Function(String url) download = downloadImageToTempFile,
}) async {
  final ItemScrapeKey key = ItemScrapeKey(MediaKind.game, gameId);
  final ItemScrapeStore writer =
      store ?? ItemScrapeStore(db, downloadImage: download);
  final ItemImageRow? current = await currentItemBackdrop(db, key);
  return BannerPickerTarget(
    current: current == null ? null : resizedFileImage(File(current.path)),
    currentUserChosen: current?.userChosen ?? false,
    onlineEmptyMessage: t.media_banner_game_online_empty,
    loadOnline: onlineEnabled
        ? () => loadGameBannerOnlineCandidates(
            db: db,
            gameId: gameId,
            vndbFactory: vndbFactory,
            download: download,
          )
        : null,
    download: download,
    apply: (File file, {String? sourceUrl}) =>
        applyItemBannerFile(writer, key, file, sourceUrl: sourceUrl),
    clear: () => writer.clearUserImage(key, MediaImageKind.backdrop),
  );
}
