import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// [decideMediaServerVersionBeforePlay] 的结果：要不要接着播，以及这次查到的
/// 版本表（详情页缓存它，集卡据此显示「N 个版本」，下次点同一集不再问服务器）。
class MediaServerVersionDecision {
  const MediaServerVersionDecision({
    required this.proceed,
    required this.versions,
  });

  /// false = 用户在版本选择里取消了，不播。
  final bool proceed;

  /// 这一集的全部版本（不支持多版本 / 查失败为空）。
  final List<MediaServerVersion> versions;
}

/// 点一集（或电影）**之前**的版本决定（mxYhpVcwOX）：
///
/// 1. 服务器不支持按条目取版本（`browser is! MediaServerItemVersions`，如 Plex v1）
///    → 直接播；
/// 2. 版本表：[knownVersions]（详情页已缓存的）> 条目自带的 [MediaServerItem.versions]
///    > 现问服务器 [MediaServerItemVersions.listItemVersions]。查失败记日志、按服务器
///    默认版本播（播放页画质菜单里照样能换）；
/// 3. 不足两个版本 → 直接播；
/// 4. [alwaysAsk] 为 false 且记住的选择对得上（本集选过，或同剧选过同名 / 同规格，
///    [matchRememberedMediaServerVersion]）→ 直接播，取流时客户端按记忆选版本；
/// 5. 否则弹版本选择（[showMediaServerVersionPicker]），选中即记住（本集 + 同剧），
///    取消就不播。
Future<MediaServerVersionDecision> decideMediaServerVersionBeforePlay({
  required BuildContext context,
  required MediaServerBrowser browser,
  required MediaServerItem item,
  List<MediaServerVersion>? knownVersions,
  bool alwaysAsk = false,
}) async {
  if (browser is! MediaServerItemVersions || !item.isPlayable) {
    return const MediaServerVersionDecision(
      proceed: true,
      versions: <MediaServerVersion>[],
    );
  }
  List<MediaServerVersion> versions =
      knownVersions ??
      (item.versions.isNotEmpty ? item.versions : const <MediaServerVersion>[]);
  if (knownVersions == null && item.versions.isEmpty) {
    try {
      versions = await (browser as MediaServerItemVersions).listItemVersions(
        item,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MediaServerVersionPicker.listItemVersions',
        error,
        stack,
      );
      return const MediaServerVersionDecision(
        proceed: true,
        versions: <MediaServerVersion>[],
      );
    }
  }
  if (versions.length < 2) {
    return MediaServerVersionDecision(proceed: true, versions: versions);
  }
  if (!alwaysAsk &&
      matchRememberedMediaServerVersion(
            serverId: browser.serverId,
            itemId: item.id,
            seriesId: item.seriesId,
            versions: versions,
          ) !=
          null) {
    return MediaServerVersionDecision(proceed: true, versions: versions);
  }
  if (!context.mounted) {
    return MediaServerVersionDecision(proceed: false, versions: versions);
  }
  final int? picked = await showMediaServerVersionPicker(
    context: context,
    versions: versions,
    selectedIndex: resolveMediaServerVersionIndex(
      serverId: browser.serverId,
      itemId: item.id,
      seriesId: item.seriesId,
      versions: versions,
    ),
  );
  if (picked == null) {
    return MediaServerVersionDecision(proceed: false, versions: versions);
  }
  rememberMediaServerVersion(
    serverId: browser.serverId,
    itemId: item.id,
    seriesId: item.seriesId,
    version: versions[picked],
  );
  return MediaServerVersionDecision(proceed: true, versions: versions);
}

/// 版本选择对话框：设计系统分派的单选对话框（[showFushiChoiceDialog]：M3E 选中
/// 胶囊 + 对勾 / Apple 分组列表，进出场走对话框路由的共享动效，墨水屏与「减弱
/// 动态效果」下瞬切）。每行主文案是版本名（没有就规格），副行是规格摘要；打开时
/// 焦点落在 [selectedIndex]。返回选中下标，null = 取消。
Future<int?> showMediaServerVersionPicker({
  required BuildContext context,
  required List<MediaServerVersion> versions,
  required int selectedIndex,
}) {
  return showFushiChoiceDialog<int>(
    context: context,
    title: t.media_server_version_pick_title,
    icon: FushiIcons.video,
    selected: selectedIndex,
    options: <FushiChoiceOption<int>>[
      for (int i = 0; i < versions.length; i++)
        FushiChoiceOption<int>(
          value: i,
          label: versions[i].title,
          subtitle:
              versions[i].qualitySummary.isEmpty ||
                  versions[i].qualitySummary == versions[i].title
              ? null
              : versions[i].qualitySummary,
        ),
    ],
  );
}
