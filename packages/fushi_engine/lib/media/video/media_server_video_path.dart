/// 媒体服务器（Jellyfin / Emby / 飞牛 / Plex）入库条目的 `VideoBooks.videoPath` 标识。
///
/// 2026-10-23：媒体服务器详情页「加入媒体库」与在线视频源同一形态（见
/// `anime_source_video_path.dart`）——每个可播叶子落一行 `VideoBooks`，`bookUid` =
/// 服务器条目 id（与分区里直接播放时的 `RemoteVideoInfo.id` 同口径，断点 / 字幕记忆
/// 入库前后连续）；流地址带令牌、换线路就变，所以 `videoPath` 不存 URL，而是一个
/// **非 http** 的自定义 scheme 标识，重开规格（服务器身份 + 条目）放在
/// `streamSpecJson`，起播时按设置里的服务器配置现建客户端。
///
/// 形如 `media-server://<条目 id>/<作品名> - S01E03`：最后一段只为可读，身份永远是
/// bookUid + spec。
///
/// 凡是「按 http 前缀判是不是本地文件」的门都必须同时认它——判据只在这里写一次，
/// `strm_file.dart` 的 `isNetworkOnlyVideoPath` 并入。
library;

import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// 自定义 scheme（不带 `://`）。
const String kMediaServerVideoPathScheme = 'media-server';

const String _prefix = '$kMediaServerVideoPathScheme://';

/// [path] 是不是媒体服务器入库条目的标识（大小写不敏感，容忍首尾空白）。
bool isMediaServerVideoPath(String? path) {
  if (path == null) return false;
  final String trimmed = path.trimLeft();
  return trimmed.length >= _prefix.length &&
      trimmed.substring(0, _prefix.length).toLowerCase() == _prefix;
}

/// 拼一个条目的标识。[label] 是可读的末段，非法路径字符替换掉。
String mediaServerVideoPath({required String itemId, required String label}) {
  final String safeId = safeWindowsFileName(itemId).trim();
  final String safe = safeWindowsFileName(label).trim();
  return '$_prefix${safeId.isEmpty ? 'item' : safeId}/'
      '${safe.isEmpty ? 'video' : safe}';
}
