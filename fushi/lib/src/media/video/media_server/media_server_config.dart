import 'package:http/http.dart' as http;

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';

/// 媒体服务器的**协议家族**（配置 JSON 的 `kind` 字段）。
///
/// 取值按「用哪一套客户端协议」分，不按服务器品牌分：Jellyfin / Emby / 飞牛影视
/// 走同一套 MediaBrowser 端点，由 `JellyfinVideoClient` 一份实现在运行期兼容
/// （认证头双发、`/Shows/*` 失败回退通用树，见 jellyfin_video_client.dart），从来
/// 没有、也不需要按品牌分支——所以它们共用 [jellyfin]。Plex 是完全不同的协议
/// （`X-Plex-Token` / MediaContainer / plex.tv 账号），单独一类。
enum MediaServerKind {
  /// Jellyfin 家族（Jellyfin / Emby / 飞牛影视等 MediaBrowser 兼容层）。
  jellyfin('jellyfin'),
  plex('plex');

  const MediaServerKind(this.wireName);

  /// 持久化值（配置 JSON 的 `kind`），冻结不改。
  final String wireName;

  /// 配置 JSON 里的字段名。
  static const String jsonKey = 'kind';

  /// 解析持久化值：**缺字段 = [jellyfin]**（引入本字段之前的存量配置全是它，
  /// 按旧行为读取）；认不出的值返回 null，调用方跳过该项（新版本写入的未来类型
  /// 在旧版本上不能被误当成 Jellyfin 去请求）。
  static MediaServerKind? fromWire(Object? raw) {
    if (raw == null) return MediaServerKind.jellyfin;
    for (final MediaServerKind kind in MediaServerKind.values) {
      if (kind.wireName == raw) return kind;
    }
    return null;
  }
}

/// 一台已登录媒体服务器的持久化配置（`SyncRepository.getMediaServers` 的元素，
/// 落 `sync_jellyfin_servers` 列表键——键名冻结，Plex 也在同一个数组里，以
/// [kind] 区分）。
///
/// 页面 / 入口只经这里拿浏览器（[buildBrowser]，按能力 `is MediaServerBrowser`
/// 消费），不按类型分支；按 JSON 反解成具体配置的唯一分发点是
/// `media_server_registry.dart` 的 [decodeMediaServerConfig]。
abstract interface class MediaServerConfig {
  MediaServerKind get kind;

  /// 与 [MediaServerBrowser.serverId] / 远端清单缓存槽同口径的身份：同 id =
  /// 同一台服务器 + 同一个账号。upsert / remove / 缓存失效都按它。
  String get sourceId;

  /// 账号名（服务器卡片副标题）。
  String get accountName;

  /// 全部访问地址（首选在首位）；少于两条时服务器卡片不出「切换线路」。
  List<String> get routeUrls;

  /// 当前请求走的地址（[routeUrls] 之一）。
  String get effectiveServerUrl;

  /// 切到 [url] 之后的配置（[url] 不在 [routeUrls] 里时回落首选地址）。
  MediaServerConfig withActiveRoute(String url);

  /// 持久化 JSON。非缺省类型必须写 [MediaServerKind.jsonKey]；[MediaServerKind.jellyfin]
  /// 不写（缺字段即它，与存量产出逐字相同）。
  Map<String, Object?> toJson();

  /// 按当前线路建浏览器（每次取数新建，不缓存实例）。
  MediaServerBrowser buildBrowser({http.Client? httpClient});
}
