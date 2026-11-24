/// 没入库的媒体服务器条目（从服务器浏览页直接串流、没「加入媒体库」）按条目 id 找回
/// 并起播：收藏夹 / 手机遥控跳回收藏原处用（BUG-5402）。
///
/// 从 `media_server_library.dart`（入库 / 刮削服务，在 AppModel 大 import 环里）拆出：
/// 收藏跳回的解析器（`favorite_video_origin.dart`）只要这一段，不该为此进环
/// （`import_cycle_guard_test.dart`）。`media_server_library.dart` 原样 export 本文件。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart'
    show PlexApiException;
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/remote_client_teardown.dart'
    show closeOwnedRemoteVideoClient;
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinApiException;
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 没入库的媒体服务器条目找回来之后的起播材料：现建的播放客户端（**归调用方**，交给
/// 播放页时带 `ownsRemoteClient: true`，退页收尾后由播放页关）+ 起播详情。
typedef MediaServerItemLaunch = ({
  RemoteVideoClient client,
  RemoteVideoInfo info,
});

/// [sourceId]（`RemoteLibrarySource.remoteLibrarySourceId`，收藏记下的来源身份）是不是
/// 某台媒体服务器（[MediaServerConfig.sourceId]）：各家 `sourceIdFor` 一律以
/// `<MediaServerKind.wireName>:` 开头（`jellyfin:<地址>|<用户>`、
/// `plex:<机器>|<账号>`）；互联对端 / 在线源 / 直链的身份不带这些前缀。
bool isMediaServerSourceId(String sourceId) => MediaServerKind.values.any(
  (MediaServerKind kind) => sourceId.startsWith('${kind.wireName}:'),
);

/// [resolveMediaServerItemLaunch] 找不回来的原因（调用方按它给不同提示）。
enum MediaServerItemLaunchFailure {
  /// 收藏记着的那台服务器不在已登录列表里（退出登录 / 删掉了）；旧收藏（没记来源）
  /// 时 = 一台媒体服务器都没登录。
  serverSignedOut,

  /// 服务器答了话，但没有这个可播条目（删了 / 换了 id / 旧收藏在哪台上都对不上标题）。
  itemMissing,

  /// 连不上服务器（离线 / 超时 / 拒绝访问 / 服务器出错），条目在不在不知道。
  serverUnreachable,
}

/// [resolveMediaServerItemLaunch] 的结果：恰好一个非 null。
@immutable
final class MediaServerItemLaunchResult {
  const MediaServerItemLaunchResult.found(MediaServerItemLaunch this.launch)
    : failure = null;

  const MediaServerItemLaunchResult.failed(
    MediaServerItemLaunchFailure this.failure,
  ) : launch = null;

  final MediaServerItemLaunch? launch;
  final MediaServerItemLaunchFailure? failure;
}

/// [error] 是不是「服务器答了话：没有这个条目」（不认得这个 id 的服务器回 404，
/// Jellyfin 家族对非 GUID 的 id 回 400）。其余（连不上、超时、401/403、5xx）都算
/// 服务器不可用。
bool _isMediaServerItemMissing(Object error) => switch (error) {
  JellyfinApiException(:final int statusCode) =>
    statusCode == 404 || statusCode == 400,
  PlexApiException(:final int statusCode) =>
    statusCode == 404 || statusCode == 400,
  _ => false,
};

/// 没有本机库行的媒体服务器条目（从服务器浏览页直接串流、没「加入媒体库」）的起播：
/// 收藏 / 遥控跳回原处时用。收藏的 bookKey 就是服务器条目 id（[VideoFushiPage.remote]
/// 的 `bookUid = info.id`），而 Plex ratingKey / Emby id 是各服务器自增数字、跨服务器
/// 会撞号，所以**按收藏时记下的来源身份**（[originSourceId] =
/// `FavoriteSentence.originSourceId` = [MediaServerConfig.sourceId] 同口径）精确找回
/// 那一台，不挨台问（BUG-5402）。
///
/// [originSourceId] 为 null 的是 v179 之前的旧收藏：只能挨台问已登录的服务器，而且
/// 详情标题必须与收藏时的标题 [expectedTitle] 一致才算命中——不核对就会跳到别台
/// 服务器上同 id 的无关视频；核对后仍有不止一台命中（同 id 同标题）时取第一台，两台
/// 本就是同一部内容。
///
/// 详情按 `forLaunch: true` 取：命中的那一次结果留给随后的取流
/// （`LaunchItemDetailMemo`），不重取。没命中的几台的客户端这里就关掉。
///
/// 单台服务器的异常（不是「没有这个条目」的那类）记 [ErrorLogService] 并归为
/// [MediaServerItemLaunchFailure.serverUnreachable]；[loadConfigs] 自己抛出则原样传给
/// 调用方。
Future<MediaServerItemLaunchResult> resolveMediaServerItemLaunch({
  required String itemId,
  required String? originSourceId,
  required String expectedTitle,
  required Future<List<MediaServerConfig>> Function() loadConfigs,
}) async {
  if (itemId.isEmpty) {
    return const MediaServerItemLaunchResult.failed(
      MediaServerItemLaunchFailure.itemMissing,
    );
  }
  final List<MediaServerConfig> configs = await loadConfigs();
  final List<MediaServerConfig> candidates = originSourceId == null
      ? configs
      : <MediaServerConfig>[
          for (final MediaServerConfig c in configs)
            if (c.sourceId == originSourceId) c,
        ];
  if (candidates.isEmpty) {
    return const MediaServerItemLaunchResult.failed(
      MediaServerItemLaunchFailure.serverSignedOut,
    );
  }
  final String wantedTitle = expectedTitle.trim();
  bool unreachable = false;
  for (final MediaServerConfig config in candidates) {
    final MediaServerBrowser browser = config.buildBrowser();
    try {
      final MediaServerItem detail = await browser.itemDetail(
        itemId,
        forLaunch: true,
      );
      if (detail.isPlayable) {
        final RemoteVideoInfo info = browser.toRemoteVideoInfo(detail);
        if (originSourceId != null || info.title.trim() == wantedTitle) {
          return MediaServerItemLaunchResult.found((
            client: browser.playbackClient,
            info: info,
          ));
        }
      }
    } on Object catch (error, stack) {
      if (!_isMediaServerItemMissing(error)) {
        unreachable = true;
        ErrorLogService.instance.log(
          'MediaServerLibrary.resolveItemLaunch(${config.kind.wireName})',
          error,
          stack,
        );
      }
    }
    closeOwnedRemoteVideoClient(browser.playbackClient);
  }
  return MediaServerItemLaunchResult.failed(
    unreachable
        ? MediaServerItemLaunchFailure.serverUnreachable
        : MediaServerItemLaunchFailure.itemMissing,
  );
}
