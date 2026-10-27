import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_grid_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
  MediaServerLibrary? library,
  String? initialQuery,
}) {
  Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MediaServerGridView(
        session: session,
        parentId: parentId,
        title: title,
        library: library,
        initialQuery: initialQuery,
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
  // 作品详情接管整个窗口（push 到根 Navigator）：媒体服务器分区是库页外壳里的
  // 嵌套 Navigator，留在里面时外壳的大标题 + 页签胶囊与详情自己的浮动顶栏三层
  // 叠在顶部，hero 背景被压在下面、宽度也被外壳内容区截住。根路由的返回键 /
  // 系统返回与本地系列详情（同样是根路由）一致；返回后回到分区里原来那一层。
  Navigator.of(context, rootNavigator: true).push<void>(
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

/// 点一张卡：电影与剧一样进详情（海报 / 简介 / 版本选择 / 播放，BUG-3329——
/// 电影直接播时用户既看不到详情、也选不了版本），集直接播（带上 [siblings] 里
/// 已加载的同季集），季进所属剧的详情并选中该季，文件夹 / BoxSet 进同一网格视图
/// （parentId 换成它）。
void openMediaServerItem(
  BuildContext context,
  MediaServerSession session,
  MediaServerItem item, {
  List<MediaServerItem> siblings = const <MediaServerItem>[],
}) {
  switch (item.type) {
    case MediaServerItemType.movie || MediaServerItemType.series:
      openMediaServerDetail(context, session, item);
    case MediaServerItemType.episode:
      session.playItem(context, item, siblings: siblings);
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

/// 「继续观看」卡：这一行就是为了接着看，可播叶子（电影 / 集）直接从断点播，
/// 不先进详情；其余类型与 [openMediaServerItem] 同义。
void resumeMediaServerItem(
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
    case MediaServerItemType.series ||
        MediaServerItemType.season ||
        MediaServerItemType.folder:
      openMediaServerItem(context, session, item, siblings: siblings);
  }
}

/// 长按 / 桌面右键：电影与剧进详情，集进所属剧的详情并选中它的季；其余类型
/// 与短按同义。
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

/// 「继续观看」卡长按 / 右键菜单里的一项。
enum MediaServerContinueMenuAction { resume, details }

/// 「继续观看」卡的长按 / 右键菜单（a-XEzglLaq）：「继续播放」（与点按同义，
/// [resumeMediaServerItem]）+「打开详情」（集进所属剧的详情并选中它的季，
/// [openMediaServerItemDetail]）。菜单锚在 [context] 所在的卡上（设计系统分派的
/// [showFushiMenu]：MD3 菜单面 + 淡入下拉 / Apple 玻璃面板 + 变形展开）。
Future<void> showMediaServerContinueMenu(
  BuildContext context,
  MediaServerSession session,
  MediaServerItem item, {
  List<MediaServerItem> siblings = const <MediaServerItem>[],
}) async {
  final RenderObject? overlay = Overlay.of(context).context.findRenderObject();
  final RenderObject? card = context.findRenderObject();
  assert(
    card is RenderBox,
    'showMediaServerContinueMenu needs the card’s own context, '
    'not a list / sliver context (got ${card.runtimeType})',
  );
  if (overlay is! RenderBox || card is! RenderBox || !card.hasSize) return;
  // 坐标经 Overlay 换算，消掉界面缩放（BUG-781 同族纪律）。
  final Rect anchor = Rect.fromPoints(
    card.localToGlobal(Offset.zero, ancestor: overlay),
    card.localToGlobal(card.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  PopupMenuItem<MediaServerContinueMenuAction> entry(
    MediaServerContinueMenuAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem<MediaServerContinueMenuAction>(
    key: ValueKey<String>('media-server-continue-menu-${value.name}'),
    value: value,
    child: Row(
      children: <Widget>[
        FushiIcon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );
  final MediaServerContinueMenuAction? action =
      await showFushiMenu<MediaServerContinueMenuAction>(
        context: context,
        position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
        items: <PopupMenuEntry<MediaServerContinueMenuAction>>[
          entry(
            MediaServerContinueMenuAction.resume,
            FushiIcons.play,
            t.media_server_continue_menu_resume,
          ),
          entry(
            MediaServerContinueMenuAction.details,
            FushiIcons.info,
            t.media_server_continue_menu_details,
          ),
        ],
      );
  if (action == null || !context.mounted) return;
  switch (action) {
    case MediaServerContinueMenuAction.resume:
      resumeMediaServerItem(context, session, item, siblings: siblings);
    case MediaServerContinueMenuAction.details:
      openMediaServerItemDetail(context, session, item);
  }
}
