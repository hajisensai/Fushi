/// 更新中心的条目跳转（v101）。
///
/// 与页面分开：`UpdatesCenterPage` 只认识「一条更新」，跳转要认识四个域各自的页面
/// 与它们的装配，塞进页面就等于把四棵依赖树焊进一个本该能独立构建的 widget。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, UpdateFeedEntryRow;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/utils.dart';

/// 打开更新中心页（首页横幅、系统通知的「查看更新」都落到这里）。
Future<void> openUpdatesCenter(
  BuildContext context,
  UpdateFeedService service,
) =>
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext pageContext) => UpdatesCenterPage(
          service: service,
          onOpenEntry: (UpdateFeedEntryRow entry) =>
              openUpdateFeedEntry(pageContext, entry),
        ),
      ),
    );

/// 打开一条更新。
///
/// 番剧新集直接**播放那一集**：走 [VideoFushiPage.neutralized]——与「从 app 外
/// 打开视频」同一条进程级入口，只要 bookUid + 合集 id，不需要合集详情页那五个
/// 回调（那套装配只在 `home_video_page` 有一份，这里不复制第二份）。带上
/// `playlistCollectionId` 播放器就有兄弟集列表、上下集与连播。
Future<void> openUpdateFeedEntry(
  BuildContext context,
  UpdateFeedEntryRow entry,
) async {
  final UpdateFeedKind? kind = UpdateFeedKind.fromDbValue(entry.kind);
  if (kind == null) return;
  final Map<String, Object?> detail = decodeUpdateFeedDetail(entry.detailJson);
  switch (kind) {
    case UpdateFeedKind.mangaChapter:
      final String? bookKey = detail['bookKey'] as String?;
      if (bookKey == null || !context.mounted) return;
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => MangaSeriesPage(
            target: ShelfMangaSeriesTarget(bookKey),
          ),
        ),
      );
    case UpdateFeedKind.mangaExtension:
      if (!context.mounted) return;
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => const MihonExtensionsPage(),
        ),
      );
    case UpdateFeedKind.appRelease:
      final String? url = detail['releaseUrl'] as String?;
      if (url == null || url.isEmpty) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    case UpdateFeedKind.videoEpisode:
      final String? bookUid = detail['bookUid'] as String?;
      final int? collectionId = detail['collectionId'] as int?;
      if (bookUid == null || !context.mounted) return;
      final FushiDatabase database = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider).database;
      final VideoBookRepository repo = VideoBookRepository(database);
      // 那集可能已被用户删掉：不进播放页对着空路径报错，留在列表里。
      if (await repo.getByBookUid(bookUid) == null || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage.neutralized(
            bookUid: bookUid,
            repo: repo,
            playlistCollectionId: collectionId,
          ),
        ),
      );
  }
}
