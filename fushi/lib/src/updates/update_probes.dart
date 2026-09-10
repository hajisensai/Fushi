/// 三个域的后台检查动作（v101）。番剧不在此列——它走自己的相位学习节奏，见
/// `update_check_scheduler.dart` 的库注释。
///
/// 每个 probe 都是「拉一次真相 → 交给既有的投递路径」，**自己不判重、不发通知**：
/// 那两件事是 `UpdateFeedService` 的，重复实现一份就会有两套判据。
library;

import 'dart:convert' show jsonEncode;

import 'package:fushi_core/fushi_core.dart'
    show EpubBookRow, FushiDatabase, MangaExtensionRow;

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_updates.dart';
import 'package:fushi/src/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';

/// 书架里的在线漫画条目（本地导入的 mokuro 漫画没有 `sourceMetadata`，天然被
/// [OnlineMangaLibraryEntry.tryParse] 排除）。
List<({EpubBookRow book, OnlineMangaLibraryEntry entry})> onlineMangaLibraryRows(
  Iterable<EpubBookRow> books,
) {
  final List<({EpubBookRow book, OnlineMangaLibraryEntry entry})> out =
      <({EpubBookRow book, OnlineMangaLibraryEntry entry})>[];
  for (final EpubBookRow book in books) {
    final OnlineMangaLibraryEntry? entry =
        OnlineMangaLibraryEntry.tryParse(book.sourceMetadata);
    if (entry != null) out.add((book: book, entry: entry));
  }
  return out;
}

/// 在线漫画库检查：逐条联网刷新，新章由
/// `OnlineMangaLibraryService.refresh` 自己投递（那里是唯一的 diff 点）。
///
/// **串行**而不是并发：几十条书架条目并发打同一个源站等于自制一次小型压测，
/// 而这是后台任务，快几秒对用户没有任何意义。
///
/// 单条失败（源挂了、Cloudflare 拦截、章节列表返回空）只跳过这一条：一条书架
/// 条目的源出问题，不该让后面几十条都查不成。
Future<int> runOnlineMangaUpdateProbe({
  required FushiDatabase database,
  required OnlineMangaLibraryService Function(OnlineMangaRuntimeKind) serviceFor,
  void Function(Object error, String bookKey)? onError,
}) async {
  final List<EpubBookRow> books = await database.getAllEpubBooks();
  int refreshed = 0;
  for (final ({EpubBookRow book, OnlineMangaLibraryEntry entry}) row
      in onlineMangaLibraryRows(books)) {
    try {
      await serviceFor(row.entry.runtime).refreshFromSource(
        bookKey: row.book.bookKey,
        entry: row.entry,
      );
      refreshed++;
    } on Object catch (error) {
      onError?.call(error, row.book.bookKey);
    }
  }
  return refreshed;
}

/// 漫画扩展检查：拉一次仓库索引，把「已装且仓库里更高版本」的投递出去。
///
/// [refreshStores] 由调用方给（`MihonManager.refreshStores`），因为拉索引这件事
/// 的 etag/304、错误分类、并发保护全在 manager 里，这里再实现一遍只会有两套。
Future<int> runMangaExtensionUpdateProbe({
  required UpdateFeedService feed,
  required Future<void> Function() refreshStores,
  required List<MihonAvailableExtension> Function() available,
  required List<MangaExtensionRow> Function() installed,
}) async {
  await refreshStores();
  final List<MihonExtensionUpdate> updates = mihonExtensionUpdates(
    available: available(),
    installed: installed(),
  );
  if (updates.isEmpty) return 0;
  await feed.publishBatch(
    UpdateFeedKind.mangaExtension,
    <UpdateFeedDraft>[
      for (final MihonExtensionUpdate update in updates)
        UpdateFeedDraft(
          kind: UpdateFeedKind.mangaExtension,
          targetKey: mangaExtensionTargetKey(
            packageName: update.packageName,
            versionCode: update.versionCode,
          ),
          title: update.available.name,
          subtitle: update.available.versionName,
          detailJson: jsonEncode(<String, Object?>{
            'packageName': update.packageName,
            'versionCode': update.versionCode,
            'storeUrl': update.available.storeUrl,
          }),
        ),
    ],
  );
  return updates.length;
}

/// app 新版本检查：由调用方给「有没有新版、版本号是多少」的判据
/// （`UpdateChecker` 那套发布通道 / 渠道过滤逻辑不该在这里复刻一份）。
///
/// [releaseUrl] 进 detailJson，更新页点条目时直接落到发布页。
Future<bool> publishAppReleaseUpdate({
  required UpdateFeedService feed,
  required String version,
  String? releaseNotes,
  String? releaseUrl,
}) async {
  final UpdateFeedPublishResult result = await feed.publish(
    UpdateFeedDraft(
      kind: UpdateFeedKind.appRelease,
      targetKey: appReleaseTargetKey(version),
      title: version,
      subtitle: releaseNotes == null || releaseNotes.trim().isEmpty
          ? null
          : releaseNotes.trim().split('\n').first,
      detailJson: jsonEncode(<String, Object?>{
        'version': version,
        if (releaseUrl != null) 'releaseUrl': releaseUrl,
      }),
    ),
  );
  return result.hasNew;
}
