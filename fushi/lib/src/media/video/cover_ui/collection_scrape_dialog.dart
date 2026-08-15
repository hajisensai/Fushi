import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/cover_ui/cover_match_dialog.dart';
import 'package:fushi/src/media/video/cover_ui/video_scrape_actions.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/collection_relations_scrape.dart';
import 'package:fushi/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/tmdb_client.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 合集「刮削资料与封面」共享流程（BUG-1662 从 home_video_page 抽出）：库页合集
/// 长按/右键菜单与合集详情页管理菜单共用同一入口，行为完全一致。
///
/// 换的是**合集自己的封面**（`MediaCollections.coverPath`，schema v61）+ 合集级
/// 刮削资料，一个成员都不动（BUG-1211）。弹窗从合集入口打开时不出「同时应用到
/// 本合集全部 N 集」勾选，「使用」只下载一张图落进
/// `<video_covers>/collections/<id>.jpg` 并写合集那一列。
///
/// 本地成员仍要找一个当**搜索种子**（用它的文件路径解析番名预填搜索框）；找不到
/// 就没有可预填的片名，给可见提示而不是静默返回——菜单已自行关闭，静默 return 在
/// 用户看来就是「点了没反应」（同 BUG-1081 的判据）。
///
/// 不做菜单项置灰：能不能刮取决于「有没有**解析得出**的本地成员」，那要
/// `getCollectionItems` + 逐 uid 查 repo 才知道，为每次右键都付这份 IO 不划算；
/// 用扩展名式的近似预判去置灰则会撒谎（灰的其实能用 / 亮的其实不能用）。
Future<void> showCollectionScrapeDialog({
  required BuildContext context,
  required FushiDatabase db,
  required VideoBookRepository repository,
  required String configuredTmdbKey,
  required MediaCollectionRow collection,
  required VoidCallback onApplied,
}) async {
  final List<MediaCollectionItemRow> items =
      await db.getCollectionItems(collection.id);
  final List<String> uids = <String>[
    for (final MediaCollectionItemRow m in items)
      if (m.mediaType == MediaKind.video.dbValue) m.entryKey,
  ];
  VideoBookRow? seed;
  for (final String uid in uids) {
    seed = await repository.getByBookUid(uid);
    if (seed != null) break;
  }
  if (!context.mounted) return;
  if (seed == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.video_collection_no_local_member)),
    );
    return;
  }
  final VideoScraperBundle bundle = await createVideoScraperBundle(
    repository: repository,
    configuredTmdbKey: configuredTmdbKey,
    artifactDatabase: db,
  );
  if (!context.mounted) return;
  await showCoverMatchDialog(
    context: context,
    service: bundle.service,
    book: seed,
    // 合集入口下弹窗不读成员表（不出「应用到全部」勾选）；只传种子自身，让
    // 「误传整表 → 又被当成批量目标」这条路在类型/数据两层都不存在。
    collectionMemberUids: <String>[seed.bookUid],
    onApplied: onApplied,
    collection: CoverMatchCollectionTarget(
      id: collection.id,
      name: collection.name,
      applyScrape: (
        CollectionScrapeResult result, {
        required String? confirmedTitle,
      }) async {
        await applyCollectionScrape(
          db,
          collection.id,
          result,
          confirmedTitle: confirmedTitle,
        );
        // TODO-2484：同一次刮削顺带拉「相关作品」。fire-and-forget——弹窗
        // 主流程（封面+资料）已落库成功，关系区块是增量数据，拉取失败只记
        // 日志、下次重刮补齐，不把弹窗关闭卡在第二轮网络请求上。
        unawaited(runCollectionRelationsScrape(
          db: db,
          collectionId: collection.id,
          configuredTmdbKey: configuredTmdbKey,
        ));
      },
    ),
  );
}

/// 合集刮削后的「相关作品」拉取（TODO-2484）。独立函数：applyScrape 闭包只管
/// 触发；失败（含逐源错误）统一进 ErrorLogService，不上 UI。
Future<void> runCollectionRelationsScrape({
  required FushiDatabase db,
  required int collectionId,
  required String configuredTmdbKey,
}) async {
  // 用户自填 key 优先，其次内置 key（resolveTmdbApiKey）——与封面刮削同一
  // 取值规则；读裸偏好会让只靠内置 key 的用户 TMDB 关系路静默失效。
  final String tmdbKey = resolveTmdbApiKey(configuredTmdbKey);
  final BangumiClient bangumi = BangumiClient();
  final TmdbClient? tmdb = tmdbKey.isEmpty ? null : TmdbClient(apiKey: tmdbKey);
  try {
    final CollectionRelationsScrapeReport report =
        await scrapeCollectionRelations(
      db: db,
      collectionId: collectionId,
      bangumi: bangumi,
      tmdb: tmdb,
    );
    for (final MapEntry<String, String> entry in report.sourceErrors.entries) {
      ErrorLogService.instance.log(
        'CollectionRelations.${entry.key}',
        entry.value,
      );
    }
  } catch (e, stack) {
    ErrorLogService.instance.log('CollectionRelations', e, stack);
  } finally {
    bangumi.close();
    tmdb?.close();
  }
}
