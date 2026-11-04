/// Apple Music 电台（catalog station：艺人 / 歌曲电台、个人电台、Apple Music 1 等直播电台）的
/// 播放项路径与身份。
///
/// 电台没有公开的曲目列表（Apple 公开 API 不给，也不用私有接口），只能让 MusicKit 自己管电台
/// 队列、自己换歌；Fushi 的队列里电台只占一项，桥报「现在放到哪首」时由引擎就地换成那首
/// （见 app 侧 `MusicBackendNowPlayingChanged` / `MusicBackendCapabilities.externalQueue`）。
///
/// 路径：`fushi-apple-music://station/<stationId>?sf=<storefront>`。scheme 与整曲相同
/// （`isAppleMusicTrackPath` 也认它，路由照样落到 MusicKit 后端），host 是 `station`。带上
/// storefront 是为了让电台里每首歌的 `trackUid` 与从同一 storefront 的 catalog 点播同一首一致
/// （[appleMusicStationSongTrackUid]）。
library;

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show
        isAppleMusicTrackPath,
        kAppleMusicTrackScheme,
        normalizeAppleMusicStorefront;
import 'package:fushi_engine/media/music/server/music_server.dart'
    show musicServerTrackUid;

/// 电台路径的 host。
const String kAppleMusicStationHost = 'station';

/// 电台路径里 storefront 的 query 键。
const String kAppleMusicStationStorefrontParam = 'sf';

/// 一个 catalog 电台的播放地址。[storefront] 不给 / 不合法时落缺省 storefront
/// （与 `normalizeAppleMusicStorefront` 一致）。
Uri appleMusicStationUri(String id, {String? storefront}) => Uri(
  scheme: kAppleMusicTrackScheme,
  host: kAppleMusicStationHost,
  pathSegments: <String>[id],
  queryParameters: <String, String>{
    kAppleMusicStationStorefrontParam: normalizeAppleMusicStorefront(
      storefront,
    ),
  },
);

Uri? _stationUri(String path) {
  if (!isAppleMusicTrackPath(path)) return null;
  final Uri? u = Uri.tryParse(path);
  if (u == null ||
      u.host != kAppleMusicStationHost ||
      u.pathSegments.length != 1 ||
      u.pathSegments.single.isEmpty) {
    return null;
  }
  return u;
}

/// 播放项路径是不是 Apple Music 电台。
bool isAppleMusicStationPath(String path) => _stationUri(path) != null;

/// 从电台地址取电台 id；不是电台地址回 null。
String? appleMusicStationIdFromPath(String path) =>
    _stationUri(path)?.pathSegments.single;

/// 从电台地址取 storefront（已归一化；没带 / 不合法落缺省）；不是电台地址回 null。
String? appleMusicStationStorefrontFromPath(String path) {
  final Uri? u = _stationUri(path);
  if (u == null) return null;
  return normalizeAppleMusicStorefront(
    u.queryParameters[kAppleMusicStationStorefrontParam],
  );
}

/// catalog 来源的服务器身份（必须与 `AppleMusicCatalogClient.serverId` 同形：
/// `apple-music:<storefront>`）。
String appleMusicCatalogServerId(String storefront) =>
    'apple-music:${normalizeAppleMusicStorefront(storefront)}';

/// 电台本身在 Fushi 队列里的身份（还没报出在放哪首 / 直播电台没有单曲时用它）。
String appleMusicStationTrackUid(String stationId, String storefront) =>
    musicServerTrackUid(
      appleMusicCatalogServerId(storefront),
      'station/$stationId',
    );

/// 电台里放到的一首 catalog 歌曲的身份：与从同一 storefront 的 catalog 点播这首相同
/// （歌词 / 播放历史按 `trackUid` 认人）。
String appleMusicStationSongTrackUid(String storefront, String songId) =>
    musicServerTrackUid(appleMusicCatalogServerId(storefront), songId);
