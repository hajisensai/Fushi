import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;
import 'package:fushi/src/sync/plex_video_client.dart' show PlexServerConfig;

/// 持久化 JSON → 具体配置的**唯一**分发点（按 [MediaServerKind]）。
///
/// 加一种服务器类型 = 在 [MediaServerKind] 加一个值 + 在这里加一个分支 + 实现
/// [MediaServerConfig]；页面与入口都不需要改（它们只认 `MediaServerBrowser`）。
///
/// 返回 null = 该项不可用（缺必填字段 / 认不出的 `kind`），调用方逐项丢弃。
MediaServerConfig? decodeMediaServerConfig(Map<String, dynamic> json) =>
    switch (MediaServerKind.fromWire(json[MediaServerKind.jsonKey])) {
      MediaServerKind.jellyfin => JellyfinServerConfig.fromJson(json),
      MediaServerKind.plex => PlexServerConfig.fromJson(json),
      null => null,
    };
