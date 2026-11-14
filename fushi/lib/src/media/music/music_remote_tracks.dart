/// 远程曲目（反馈 0tRY-D2JgG）：只能串流、不进扫描曲库的曲目——YouTube 内置音源与在线音源
/// 插件——被「加入音乐库」或加进本地歌单后的身份、落库换算与播放项还原（纯 Dart，可单测）。
///
/// 表语义见 `music_tables.dart` 的 `MusicRemoteTracks`。要点：
/// - **同一个 uid**：远程曲目的 `trackUid` 就是播放引擎里这首的 uid（YouTube =
///   [musicServerTrackUid]`('youtube', videoId)`、插件 = [musicPluginTrackUid]）。从搜索结果
///   直接播、从曲库 / 歌单播是同一首，歌词缓存 / 断点 / 最近播放 / 统计不用映射；
/// - **路径现推**：播放路径不落库，按（种类, 宿主, 条目 id）还原成 `fushi-music-youtube://` /
///   `fushi-music-plugin://` 占位，真正的流仍在起播时才取（直链会过期）；
/// - **合规门**：这两类来源在 iOS 上都不存在（[StoreRestrictedCapability.onlineMusicSource]），
///   所以远程曲目的入口与显示同问这一个判据（[musicRemoteTracksAvailable]）。行本身照常随备份
///   同步、不删，换回别的平台还在。
/// - **服务器曲目**（v149，反馈 se3Fw8HmOX）：Jellyfin / Subsonic 曲目也能加入音乐库与本地
///   歌单。行里只有服务器配置身份 + 服务器侧条目 id + 展示用元数据（封面只存服务器侧引用），
///   **不存任何带凭据的地址**；起播 / 取封面时由当前配置的服务器客户端现算
///   （[MusicServerBinding]，经 [musicServerBindingLoader] 装配）。uid 与从服务器页直接播时
///   一致（[musicServerTrackUid]）。这台设备没配这台服务器时条目显示为不可用、不进队列。
///   服务器曲目不受上面的合规门约束（媒体服务器在 iOS 上照常可用，[musicRemoteKindAvailable]）。
///   Apple Music 不在此列（授权 / 合规另议）。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show
        MusicServerBrowser,
        MusicServerKind,
        MusicServerTrack,
        musicServerTrackUid;
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart'
    show
        kYoutubeMusicServerId,
        youtubeMusicTrackPath,
        youtubeMusicVideoIdFromPath;

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart'
    show
        musicPluginAlbumUid,
        musicPluginTrackPath,
        musicPluginTrackUid,
        parseMusicPluginTrackPath;
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show musicServerPlayItem;
import 'package:fushi/src/models/store_compliance.dart';

/// 远程曲目的来源种类（落进 `music_remote_tracks.kind`，wire 值冻结）。
enum MusicRemoteTrackKind {
  /// YouTube 内置音源（宿主恒为 `youtube`，条目 id = videoId）。
  youtube('youtube'),

  /// 在线音源插件（宿主 = 插件 id，条目 id = 插件曲目 id）。
  plugin('plugin'),

  /// 媒体服务器曲目（Jellyfin / Subsonic，v149；宿主 = 服务器配置身份
  /// [MusicServerBrowser.serverId]，条目 id = 服务器侧曲目 id）。
  server('server');

  const MusicRemoteTrackKind(this.wire);

  final String wire;

  /// wire 值 → 种类；不认识的（将来版本写的）回 null，调用方跳过这一行。
  static MusicRemoteTrackKind? fromWire(String wire) {
    for (final MusicRemoteTrackKind k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// 远程曲目在目标平台上是否存在（测试显式注入平台用）。
bool musicRemoteTracksAvailableOn({required bool isIOS}) =>
    StoreRestrictedCapability.onlineMusicSource.availableOn(isIOS: isIOS);

/// 真实平台上的 [musicRemoteTracksAvailableOn]：「加入音乐库 / 本地歌单」入口、曲库与歌单里
/// 远程曲目的显示都只问它。
bool get musicRemoteTracksAvailable =>
    StoreRestrictedCapability.onlineMusicSource.isAvailable;

/// 这一种远程曲目在当前平台上能不能入库 / 显示：YouTube 与插件只问合规门 [online]
/// （[musicRemoteTracksAvailable]）；服务器曲目不受它约束（媒体服务器在各平台都可用）。
bool musicRemoteKindAvailable(
  MusicRemoteTrackKind kind, {
  required bool online,
}) => switch (kind) {
  MusicRemoteTrackKind.server => true,
  MusicRemoteTrackKind.youtube || MusicRemoteTrackKind.plugin => online,
};

/// 能作为远程曲目入库的服务器种类：Jellyfin / Subsonic。Apple Music 不收（授权 / 合规另议），
/// YouTube 内置音源走自己的 `youtube` 种类（占位路径，不经服务器客户端）。
bool musicServerKindStorable(MusicServerKind kind) => switch (kind) {
  MusicServerKind.jellyfin || MusicServerKind.subsonic => true,
  MusicServerKind.appleMusic || MusicServerKind.youtube => false,
};

/// 一台当前配置着的服务器：起播 / 取封面时由它现算带凭据的地址（地址只在内存里，不落库）。
class MusicServerBinding {
  const MusicServerBinding(this.browser, {this.maxBitrateKbps});

  final MusicServerBrowser browser;

  /// 设置里的码率上限（null = 原样直出），与从服务器页直接播一致。
  final int? maxBitrateKbps;
}

/// 读当前配置的 Jellyfin / Subsonic 服务器（[MusicServerBrowser.serverId] → 绑定）。
typedef MusicServerBindingLoader =
    Future<Map<String, MusicServerBinding>> Function();

/// 进程级装配点：`AppModel` 建音乐会话时装上。未装配（测试 / 无头入口）时服务器曲目按
/// 不可用显示（这台设备上没有可用的服务器配置）。
MusicServerBindingLoader? musicServerBindingLoader;

/// 一首远程曲目的来源身份。
typedef MusicRemoteIdentity = ({
  MusicRemoteTrackKind kind,
  String sourceKey,
  String itemId,
});

/// 播放路径 → 远程身份；本地文件 / 服务器流 / 光盘等不是「只能串流的远程曲目」，回 null。
/// （服务器曲目的路径是带凭据的流地址，身份从服务器客户端 + 曲目取：
/// [musicServerRemoteTrackCompanion]。）
MusicRemoteIdentity? musicRemoteIdentityOfPath(String path) {
  final String? videoId = youtubeMusicVideoIdFromPath(path);
  if (videoId != null) {
    return (
      kind: MusicRemoteTrackKind.youtube,
      sourceKey: kYoutubeMusicServerId,
      itemId: videoId,
    );
  }
  final ({String pluginId, String trackId})? plugin = parseMusicPluginTrackPath(
    path,
  );
  if (plugin != null) {
    return (
      kind: MusicRemoteTrackKind.plugin,
      sourceKey: plugin.pluginId,
      itemId: plugin.trackId,
    );
  }
  return null;
}

/// 远程身份 → 播放引擎里这首的 uid（与从搜索结果 / 服务器页直接播时一致）。
String musicRemoteTrackUidOf(MusicRemoteIdentity id) => switch (id.kind) {
  MusicRemoteTrackKind.youtube ||
  MusicRemoteTrackKind.server => musicServerTrackUid(id.sourceKey, id.itemId),
  MusicRemoteTrackKind.plugin => musicPluginTrackUid(id.sourceKey, id.itemId),
};

/// 远程身份 → 播放路径占位；服务器曲目没有占位（地址带凭据，起播时由客户端现算），回 null。
String? musicRemoteTrackPathOf(MusicRemoteIdentity id) => switch (id.kind) {
  MusicRemoteTrackKind.youtube => youtubeMusicTrackPath(id.itemId),
  MusicRemoteTrackKind.plugin => musicPluginTrackPath(id.sourceKey, id.itemId),
  MusicRemoteTrackKind.server => null,
};

/// 这个播放项能不能作为远程曲目加入音乐库 / 本地歌单：路径是远程占位，且 uid 与身份推出来的
/// 一致（防止别的来源借用了同一种路径却用另一套 uid——那样落库后就对不上歌词 / 统计）。
bool musicItemIsRemoteTrack(MusicPlayItem item) {
  final MusicRemoteIdentity? id = musicRemoteIdentityOfPath(item.path);
  return id != null && musicRemoteTrackUidOf(id) == item.trackUid;
}

/// 艺人引用 → `artist_refs` 列的 JSON；没有引用回 null。
String? musicRemoteArtistRefsJson(List<MusicPlayArtistRef> refs) {
  if (refs.isEmpty) return null;
  return jsonEncode(<Map<String, String>>[
    for (final MusicPlayArtistRef a in refs)
      <String, String>{'name': a.name, if (a.id != null) 'id': a.id!},
  ]);
}

/// `artist_refs` 列 → 艺人引用；空 / 坏数据（别的版本写的）回空表。
List<MusicPlayArtistRef> musicRemoteArtistRefsOf(String? json) {
  if (json == null || json.isEmpty) return const <MusicPlayArtistRef>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const <MusicPlayArtistRef>[];
  }
  if (decoded is! List<Object?>) return const <MusicPlayArtistRef>[];
  return <MusicPlayArtistRef>[
    for (final Object? e in decoded)
      if (e is Map<String, Object?> && e['name'] is String)
        MusicPlayArtistRef(
          name: e['name']! as String,
          id: e['id'] is String && (e['id']! as String).isNotEmpty
              ? e['id']! as String
              : null,
        ),
  ];
}

/// 播放项 → 远程曲目行（不含入库时刻 / 时间戳，由 DB 层填）；不是远程曲目回 null。
MusicRemoteTracksCompanion? musicRemoteTrackCompanionOf(MusicPlayItem item) {
  final MusicRemoteIdentity? id = musicRemoteIdentityOfPath(item.path);
  if (id == null || musicRemoteTrackUidOf(id) != item.trackUid) return null;
  final String? cover = item.coverPath;
  final bool httpCover =
      cover != null &&
      (cover.startsWith('https://') || cover.startsWith('http://'));
  return MusicRemoteTracksCompanion(
    trackUid: Value<String>(item.trackUid),
    kind: Value<String>(id.kind.wire),
    sourceKey: Value<String>(id.sourceKey),
    itemId: Value<String>(id.itemId),
    title: Value<String>(item.title),
    artist: Value<String?>(item.artist),
    album: Value<String?>(item.album),
    durationMs: Value<int?>(item.durationMs),
    coverUrl: Value<String?>(httpCover ? cover : null),
    // 插件曲目的「去艺人 / 去专辑」跳转靠这两项（#3046 遗留）。
    albumId: Value<String?>(item.sourceAlbumId),
    artistRefs: Value<String?>(musicRemoteArtistRefsJson(item.artistRefs)),
  );
}

/// 服务器曲目（Jellyfin / Subsonic）→ 远程曲目行：只有服务器配置身份、服务器侧条目 id 与
/// 展示用元数据，封面只存服务器侧引用——不碰 [MusicServerBrowser.streamFor] /
/// [MusicServerBrowser.coverUri]（那两个地址带凭据）。不能入库的种类回 null。
MusicRemoteTracksCompanion? musicServerRemoteTrackCompanion(
  MusicServerBrowser browser,
  MusicServerTrack track, {
  String? albumTitle,
}) {
  if (!musicServerKindStorable(browser.kind)) return null;
  return MusicRemoteTracksCompanion(
    trackUid: Value<String>(musicServerTrackUid(browser.serverId, track.id)),
    kind: Value<String>(MusicRemoteTrackKind.server.wire),
    sourceKey: Value<String>(browser.serverId),
    itemId: Value<String>(track.id),
    title: Value<String>(track.title),
    artist: Value<String?>(track.artist),
    album: Value<String?>(albumTitle ?? track.album),
    durationMs: Value<int?>(track.durationMs),
    coverUrl: const Value<String?>(null),
    coverRef: Value<String?>(track.coverRef),
    albumId: Value<String?>(track.albumId),
    artistRefs: const Value<String?>(null),
  );
}

/// 已落库的远程曲目行 → 写回用的行（入库状态与时间戳不带：由 DB 层按动作填）。从曲库 /
/// 歌单里的条目再「加入音乐库 / 加入歌单」时用，不必先还原成播放项。
MusicRemoteTracksCompanion musicRemoteTrackCompanionOfRow(
  MusicRemoteTrackRow row,
) => MusicRemoteTracksCompanion(
  trackUid: Value<String>(row.trackUid),
  kind: Value<String>(row.kind),
  sourceKey: Value<String>(row.sourceKey),
  itemId: Value<String>(row.itemId),
  title: Value<String>(row.title),
  artist: Value<String?>(row.artist),
  album: Value<String?>(row.album),
  durationMs: Value<int?>(row.durationMs),
  coverUrl: Value<String?>(row.coverUrl),
  coverRef: Value<String?>(row.coverRef),
  albumId: Value<String?>(row.albumId),
  artistRefs: Value<String?>(row.artistRefs),
);

/// 远程曲目行 → 身份；种类不认识（将来版本写的）回 null。
MusicRemoteIdentity? musicRemoteIdentityOfRow(MusicRemoteTrackRow row) {
  final MusicRemoteTrackKind? kind = MusicRemoteTrackKind.fromWire(row.kind);
  if (kind == null) return null;
  return (kind: kind, sourceKey: row.sourceKey, itemId: row.itemId);
}

/// [server] 是不是这一行服务器曲目所在的那台服务器。
bool _boundTo(MusicRemoteTrackRow row, MusicServerBinding? server) =>
    server != null && server.browser.serverId == row.sourceKey;

/// 远程曲目行 → 播放项（与从搜索结果 / 服务器页点开时同一个 uid）。种类不认识回 null；
/// 服务器曲目在 [server] 缺席（这台设备没配这台服务器）或对不上时回 null（不可用）。
///
/// 服务器曲目的流地址与封面地址此时由 [server] 的客户端按当前配置现算（带凭据，只在内存
/// 里）；YouTube / 插件是占位路径，起播时才取流。
MusicPlayItem? musicPlayItemOfRemote(
  MusicRemoteTrackRow row, {
  MusicServerBinding? server,
}) {
  final MusicRemoteIdentity? id = musicRemoteIdentityOfRow(row);
  if (id == null) return null;
  final String? albumId = row.albumId;
  switch (id.kind) {
    case MusicRemoteTrackKind.server:
      if (server == null || !_boundTo(row, server)) return null;
      return musicServerPlayItem(
        server.browser,
        MusicServerTrack(
          id: id.itemId,
          title: row.title,
          artist: row.artist,
          album: row.album,
          albumId: albumId,
          durationMs: row.durationMs,
          coverRef: row.coverRef,
        ),
        maxBitrateKbps: server.maxBitrateKbps,
      );
    case MusicRemoteTrackKind.youtube:
    case MusicRemoteTrackKind.plugin:
      final bool plugin = id.kind == MusicRemoteTrackKind.plugin;
      return MusicPlayItem(
        trackUid: row.trackUid,
        path: musicRemoteTrackPathOf(id)!,
        title: row.title,
        artist: row.artist,
        album: row.album,
        albumUid: plugin && albumId != null
            ? musicPluginAlbumUid(id.sourceKey, albumId)
            : null,
        durationMs: row.durationMs,
        coverPath: row.coverUrl,
        artistRefs: musicRemoteArtistRefsOf(row.artistRefs),
        sourceAlbumId: albumId,
      );
  }
}

/// 远程曲目行的封面地址：YouTube / 插件是落库的 http(s) 缩略图；服务器曲目由 [server] 的
/// 客户端按服务器侧引用现算（没配这台服务器时没有封面）。
String? musicRemoteCoverUrlOf(
  MusicRemoteTrackRow row, {
  MusicServerBinding? server,
}) => switch (MusicRemoteTrackKind.fromWire(row.kind)) {
  MusicRemoteTrackKind.server =>
    _boundTo(row, server)
        ? server!.browser.coverUri(row.coverRef)?.toString()
        : null,
  _ => row.coverUrl,
};
