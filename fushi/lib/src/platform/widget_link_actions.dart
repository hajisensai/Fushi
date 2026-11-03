import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDeckSummary;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/media.dart';
import 'package:fushi/src/anki/source_review_navigation.dart'
    show ExternalMediaNavigation;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;

// 小组件深链的落地动作（接到 [runWidgetLink] 的回调上）。都在 navigator 已退回首页
// 根路由之后才被调用，各自返回「有没有真的打开」，没打开时调用方停在对应 tab。

/// 小组件「继续」指向的条目是不是此刻正开着的那一个（纯判定，便于单测）。
///
/// [openMediaIdentifier] 是书 / 漫画当前打开条目的 `mediaIdentifier`（没开媒体为
/// null）；[activeVideoUid] 是视频播放页登记的当前 bookUid（没在播 / 互联远端视频
/// 为 null）。
bool isWidgetContinueItemOpen(
  WidgetContinueLink link, {
  required String? openMediaIdentifier,
  required String? activeVideoUid,
}) {
  if (link.id.isEmpty) return false;
  return link.kind == WidgetMediaKind.video
      ? activeVideoUid == link.id
      : openMediaIdentifier == link.id;
}

/// [isWidgetContinueItemOpen] 的运行时取值：书 / 漫画走 `AppModel.openMedia` 登记
/// 的 [AppModel.currentMediaItem]（关闭媒体时清空）；视频不经 `openMedia`，播放页
/// 自己在 [ExternalMediaNavigation] 登记当前 bookUid。
bool isWidgetContinueItemCurrentlyOpen(
  AppModel appModel,
  WidgetContinueLink link, {
  ExternalMediaNavigation? media,
}) => isWidgetContinueItemOpen(
  link,
  openMediaIdentifier: appModel.isMediaOpen
      ? appModel.currentMediaItem?.mediaIdentifier
      : null,
  activeVideoUid: (media ?? ExternalMediaNavigation.instance).activeVideoUid,
);

/// 打开小组件「继续」卡指向的条目。条目已被删 / 已读完（不在书架里了）返回 false。
///
/// - 书 / 漫画：在 `fushiBooksProvider` 里按 `mediaIdentifier` 找，走与首页
///   「继续」卡同一个 `AppModel.openMedia`。
/// - 视频：按 `bookUid` 取行，走与首页同一个 `openLocalVideoBook`（合集成员带
///   主合集 id，从合集续播）。
Future<bool> openWidgetContinueItem(
  WidgetRef ref,
  AppModel appModel,
  WidgetContinueLink link,
) async {
  if (link.id.isEmpty) return false;
  if (link.kind == WidgetMediaKind.video) {
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final VideoBookRow? row = await repo.getByBookUid(link.id);
    final BuildContext? context = appModel.navigatorKey.currentContext;
    if (row == null || context == null || !context.mounted) return false;
    final Map<String, ({int collectionId, int sortIndex})> membership =
        await appModel.database.getLocalPrimaryCollectionMembership();
    if (!context.mounted) return false;
    await openLocalVideoBook(
      context: context,
      repo: repo,
      bookUid: link.id,
      playlistCollectionId:
          membership[MediaKind.video.compositeKey(link.id)]?.collectionId,
    );
    return true;
  }
  final List<MediaItem> books = await ref.read(
    fushiBooksProvider(JapaneseLanguage.instance).future,
  );
  MediaItem? item;
  for (final MediaItem candidate in books) {
    if (candidate.mediaIdentifier == link.id) {
      item = candidate;
      break;
    }
  }
  if (item == null) return false;
  await appModel.openMedia(
    ref: ref,
    mediaSource: item.getMediaSource(appModel: appModel),
    item: item,
  );
  return true;
}

/// 开始内置复习：落到第一个还有待复习卡的顶层牌组（与首页复习条「开始复习」同
/// 一口径）。没有待复习的卡 / 复习模块没就绪返回 false。
Future<bool> openWidgetSrsReview(WidgetRef ref, AppModel appModel) async {
  final SrsDeckListData? data = await ref.read(srsDeckListProvider.future);
  final SrsDeckSummary? deck = data?.firstRootWithWork;
  final BuildContext? context = appModel.navigatorKey.currentContext;
  if (deck == null || context == null || !context.mounted) return false;
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (BuildContext context) =>
          SrsReviewPage(deckId: deck.deck.id, deckName: deck.fullName),
    ),
  );
  bumpSrsRevision(ref);
  return true;
}

/// 打开统计中心（首页「今日」旁的唯一入口同一个页面）。
Future<void> openWidgetStats(AppModel appModel) async {
  final BuildContext? context = appModel.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => const StatisticsCenterPage(),
    ),
  );
}
