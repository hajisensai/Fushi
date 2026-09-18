import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 播放出口的回调形态：浏览页只产出「播什么、带哪些同伴、从第几个起播」，
/// **不**自己 push 播放页——生产由 [MediaServerBrowsePage] 缺省接到
/// `VideoFushiPage.neutralizedRemote`，测试注入回调直接断言参数。
typedef MediaServerPlayHandler =
    void Function(BuildContext context, MediaServerPlayRequest request);

/// 一次播放请求。[members] 长度 > 1 时播放页才建剧集列表 + 上下集连播
/// （与 `home_video_page._openRemote` 的 `remoteCollectionMembers` 口径一致）。
class MediaServerPlayRequest {
  const MediaServerPlayRequest({
    required this.browser,
    required this.info,
    this.members = const <RemoteVideoInfo>[],
    this.initialIndex = 0,
  });

  final MediaServerBrowser browser;
  final RemoteVideoInfo info;
  final List<RemoteVideoInfo> members;
  final int initialIndex;

  /// 只有多于一个成员时才值得让播放页建剧集面板。
  bool get hasCollection => members.length > 1;
}

/// 一台服务器的浏览会话：浏览器 + 播放出口。首页 / 网格 / 详情三层视图共用同一份，
/// 切服务器就是换一份会话，所以 PageStorage / 焦点 id 都用 [serverId] 做前缀，
/// 两台服务器的滚动位置与搜索词不会串。
class MediaServerSession {
  const MediaServerSession({required this.browser, required this.play});

  final MediaServerBrowser browser;
  final MediaServerPlayHandler play;

  String get serverId => browser.serverId;

  /// 播一个可播放叶子。[siblings] 是同一季（或同一容器）里**已加载**的全部叶子，
  /// 用来给播放页建剧集列表；[item] 不在其中时退化成单播。
  void playItem(
    BuildContext context,
    MediaServerItem item, {
    List<MediaServerItem> siblings = const <MediaServerItem>[],
  }) {
    final List<MediaServerItem> playable = <MediaServerItem>[
      for (final MediaServerItem sibling in siblings)
        if (sibling.isPlayable) sibling,
    ];
    final int index = playable.indexWhere(
      (MediaServerItem m) => m.id == item.id,
    );
    if (index < 0) {
      play(
        context,
        MediaServerPlayRequest(
          browser: browser,
          info: browser.toRemoteVideoInfo(item),
        ),
      );
      return;
    }
    play(
      context,
      MediaServerPlayRequest(
        browser: browser,
        info: browser.toRemoteVideoInfo(item),
        members: <RemoteVideoInfo>[
          for (final MediaServerItem m in playable)
            browser.toRemoteVideoInfo(m),
        ],
        initialIndex: index,
      ),
    );
  }
}
