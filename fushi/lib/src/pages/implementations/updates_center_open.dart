/// 更新中心的条目跳转（v101）。
///
/// 与页面分开：`UpdatesCenterPage` 只认识「一条更新」，跳转要认识四个域各自的页面
/// 与它们的装配，塞进页面就等于把四棵依赖树焊进一个本该能独立构建的 widget。
///
/// 四个域的落点都在 app 内：番剧播那一集、漫画开作品页、扩展开扩展页、app 新版本
/// 走应用内检查 + 下载安装。这里没有 `launchUrl`——「更新」不该把人送出 app。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, UpdateFeedEntryRow;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/app_update_check.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/utils.dart';

/// 打开更新中心页（首页横幅、系统通知的「查看更新」都落到这里）。
Future<void> openUpdatesCenter(
  BuildContext context,
  UpdateFeedService service,
) => Navigator.of(context).push(
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
          builder: (_) =>
              MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
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
    case UpdateFeedKind.animeExtension:
      if (!context.mounted) return;
      // 视频扩展页 = 同一个扩展页挂视频（Aniyomi）manager。条目只会在有视频
      // 在线源的平台投递（探针自己过门），这里再问一次门：旧库搬到 iOS 上点开
      // 也不能起在线源宿主。
      if (!isVideoOnlineSourcesAvailable) return;
      final AppModel animeAppModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) =>
              MihonExtensionsPage(manager: animeAppModel.animeMihonManager),
        ),
      );
    case UpdateFeedKind.appRelease:
      // app 新版本走应用内更新：检查 → 「发现新版本」对话框 → 下载 + 安装。
      // detailJson 里的 releaseUrl 只是投递时的元数据，**不是**落点——把用户丢
      // 到浏览器手动下载，等于绕过 UpdateChecker 已有的整条安装链路。
      if (!context.mounted) return;
      final AppModel appModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
      await checkAppUpdateNow(context, appModel);
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
