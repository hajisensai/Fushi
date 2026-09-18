import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_grid_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

/// 分区内三层视图之间的跳转全走这里。`Navigator.of(context)` 在浏览页里解析到的是
/// 分区自己的嵌套 Navigator（见 `MediaServerBrowsePage`），所以这些 push 只在分区
/// 内叠层，页签、返回键都还归分区管；**播放页**不在此列——它要压在整个 app 之上，
/// 由 [MediaServerSession.play] 走根 Navigator。
void openMediaServerGrid(
  BuildContext context,
  MediaServerSession session, {
  required String? parentId,
  required String title,
}) {
  Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MediaServerGridView(
        session: session,
        parentId: parentId,
        title: title,
      ),
    ),
  );
}

void openMediaServerDetail(
  BuildContext context,
  MediaServerSession session,
  MediaServerItem item, {
  String? initialSeasonId,
}) {
  Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MediaServerDetailView(
        session: session,
        item: item,
        initialSeasonId: initialSeasonId,
      ),
    ),
  );
}

/// 点一张卡：电影 / 集直接播（电影不带同伴；集带上 [siblings] 里已加载的同季
/// 集），剧进详情，季进所属剧的详情并选中该季，文件夹 / BoxSet 进同一网格视图
/// （parentId 换成它）。
void openMediaServerItem(
  BuildContext context,
  MediaServerSession session,
  MediaServerItem item, {
  List<MediaServerItem> siblings = const <MediaServerItem>[],
}) {
  switch (item.type) {
    case MediaServerItemType.movie:
      session.playItem(context, item);
    case MediaServerItemType.episode:
      session.playItem(context, item, siblings: siblings);
    case MediaServerItemType.series:
      openMediaServerDetail(context, session, item);
    case MediaServerItemType.season:
      final String? seriesId = item.seriesId;
      if (seriesId == null || seriesId.isEmpty) {
        openMediaServerGrid(
          context,
          session,
          parentId: item.id,
          title: item.name,
        );
        return;
      }
      openMediaServerDetail(
        context,
        session,
        MediaServerItem(
          id: seriesId,
          name: item.seriesName ?? item.name,
          type: MediaServerItemType.series,
        ),
        initialSeasonId: item.id,
      );
    case MediaServerItemType.folder:
      openMediaServerGrid(
        context,
        session,
        parentId: item.id,
        title: item.name,
      );
  }
}

/// 长按 / 桌面右键 / 「详情」：可播放叶子与剧都进详情（电影是简版：简介 + 播放）；
/// 其余类型与短按同义。
void openMediaServerItemDetail(
  BuildContext context,
  MediaServerSession session,
  MediaServerItem item,
) {
  switch (item.type) {
    case MediaServerItemType.movie || MediaServerItemType.series:
      openMediaServerDetail(context, session, item);
    case MediaServerItemType.episode:
      final String? seriesId = item.seriesId;
      if (seriesId == null || seriesId.isEmpty) {
        session.playItem(context, item);
        return;
      }
      openMediaServerDetail(
        context,
        session,
        MediaServerItem(
          id: seriesId,
          name: item.seriesName ?? item.name,
          type: MediaServerItemType.series,
        ),
        initialSeasonId: item.seasonId,
      );
    case MediaServerItemType.season || MediaServerItemType.folder:
      openMediaServerItem(context, session, item);
  }
}
