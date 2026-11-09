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
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show musicServerTrackUid;
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart'
    show
        kYoutubeMusicServerId,
        youtubeMusicTrackPath,
        youtubeMusicVideoIdFromPath;

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart'
    show musicPluginTrackPath, musicPluginTrackUid, parseMusicPluginTrackPath;
import 'package:fushi/src/models/store_compliance.dart';

/// 远程曲目的来源种类（落进 `music_remote_tracks.kind`，wire 值冻结）。
enum MusicRemoteTrackKind {
  /// YouTube 内置音源（宿主恒为 `youtube`，条目 id = videoId）。
  youtube('youtube'),

  /// 在线音源插件（宿主 = 插件 id，条目 id = 插件曲目 id）。
  plugin('plugin');

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

/// 一首远程曲目的来源身份。
typedef MusicRemoteIdentity = ({
  MusicRemoteTrackKind kind,
  String sourceKey,
  String itemId,
});

/// 播放路径 → 远程身份；本地文件 / 服务器流 / 光盘等不是「只能串流的远程曲目」，回 null。
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

/// 远程身份 → 播放引擎里这首的 uid（与从搜索结果直接播时一致）。
String musicRemoteTrackUidOf(MusicRemoteIdentity id) => switch (id.kind) {
  MusicRemoteTrackKind.youtube => musicServerTrackUid(id.sourceKey, id.itemId),
  MusicRemoteTrackKind.plugin => musicPluginTrackUid(id.sourceKey, id.itemId),
};

/// 远程身份 → 播放路径占位。
String musicRemoteTrackPathOf(MusicRemoteIdentity id) => switch (id.kind) {
  MusicRemoteTrackKind.youtube => youtubeMusicTrackPath(id.itemId),
  MusicRemoteTrackKind.plugin => musicPluginTrackPath(id.sourceKey, id.itemId),
};

/// 这个播放项能不能作为远程曲目加入音乐库 / 本地歌单：路径是远程占位，且 uid 与身份推出来的
/// 一致（防止别的来源借用了同一种路径却用另一套 uid——那样落库后就对不上歌词 / 统计）。
bool musicItemIsRemoteTrack(MusicPlayItem item) {
  final MusicRemoteIdentity? id = musicRemoteIdentityOfPath(item.path);
  return id != null && musicRemoteTrackUidOf(id) == item.trackUid;
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
  );
}

/// 远程曲目行 → 身份；种类不认识（将来版本写的）回 null。
MusicRemoteIdentity? musicRemoteIdentityOfRow(MusicRemoteTrackRow row) {
  final MusicRemoteTrackKind? kind = MusicRemoteTrackKind.fromWire(row.kind);
  if (kind == null) return null;
  return (kind: kind, sourceKey: row.sourceKey, itemId: row.itemId);
}

/// 远程曲目行 → 播放项（与从搜索结果点开时同一个 uid、同一种占位路径）；种类不认识回 null。
MusicPlayItem? musicPlayItemOfRemote(MusicRemoteTrackRow row) {
  final MusicRemoteIdentity? id = musicRemoteIdentityOfRow(row);
  if (id == null) return null;
  return MusicPlayItem(
    trackUid: row.trackUid,
    path: musicRemoteTrackPathOf(id),
    title: row.title,
    artist: row.artist,
    album: row.album,
    durationMs: row.durationMs,
    coverPath: row.coverUrl,
  );
}
