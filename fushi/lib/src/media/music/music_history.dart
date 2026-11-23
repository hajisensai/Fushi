/// 音乐播放流（history，唯一含义：最近播放）的 app 侧读写：播放项 ↔ 事件快照、
/// 最近播放的曲目 / 来源（推荐页「最近播放」）。表与查询在 `fushi_core`
/// （`music_play_events`，v139 起带快照与来源）。
///
/// 媒体服务器（Jellyfin / Subsonic）曲目的播放流与封面地址带账号凭据（BUG-5267）：快照里
/// 只落身份占位（`fushi-music-server://…`，见 fushi_core `music_server_ref.dart`），重播 /
/// 显示时由当前配置的服务器客户端现算地址。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show
        MusicServerTrack,
        MusicServerTrackRef,
        musicServerAlbumUid,
        musicServerTrackUid;

import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show
        MusicServerBinding,
        MusicServerBindingLoader,
        musicServerBindingLoader,
        musicServerKindStorable;
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show
        MusicServerLocalCopy,
        musicServerLocalCopyLookup,
        musicServerLocalPlayItem,
        musicServerPlayItem;

/// 播放项 + 队列来源 → 落库快照（重播所需的字段都在里面）。
///
/// 服务器曲目落的是身份占位（服务器配置身份 + 服务器侧曲目 id / 专辑 id / 封面引用），
/// 不是 [MusicPlayItem.path] / [MusicPlayItem.coverPath] 那两个带凭据的地址；服务器专辑 /
/// 歌单来源的封面同理清洗。写入层（`startMusicPlayEvent`）还会再清洗一遍兜底。
MusicPlayEventSnapshot musicPlayEventSnapshotOf(
  MusicPlayItem item, {
  MusicPlaySource? source,
}) {
  final MusicServerTrackRef? ref = item.serverTrack;
  final MusicServerTrackRef? server =
      ref != null && musicServerKindStorable(ref.kind) ? ref : null;
  final String? coverRef = server?.coverRef;
  return MusicPlayEventSnapshot(
    path: server == null
        ? item.path
        : musicServerTrackRefPath(
            server.trackId,
            serverId: server.serverId,
            albumId: server.albumId,
          ),
    cueStartMs: item.startMs,
    cueEndMs: item.endMs,
    title: item.title,
    artist: item.artist,
    album: item.album,
    albumUid: item.albumUid,
    durationMs: item.durationMs,
    coverPath: server != null && coverRef != null && coverRef.isNotEmpty
        ? musicServerCoverRefPath(coverRef, serverId: server.serverId)
        : scrubMusicPersistedUrl(item.coverPath, serverId: server?.serverId),
    sourceKind: source?.kind.wire,
    sourceId: source?.id,
    sourceTitle: source?.title,
    sourceCover: source == null
        ? null
        : scrubMusicPersistedUrl(
            source.cover,
            serverId:
                server != null && source.id.startsWith('${server.serverId}/')
                ? server.serverId
                : musicServerIdOfPlaySource(source.kind.wire, source.id),
          ),
  );
}

/// 最近播放的一首。
@immutable
class MusicRecentTrack {
  const MusicRecentTrack({
    required this.item,
    required this.lastPlayedAt,
    required this.inLibrary,
    this.source,
  });

  /// 可直接交给 `MusicPlayerEngine.playQueue` 的播放项。
  final MusicPlayItem item;

  /// 最近一次开始播放的时刻（毫秒）。
  final int lastPlayedAt;

  /// 是否还在本地曲库（false = 在线插件 / 服务器曲目，或本地曲目已被删，靠快照重建）。
  final bool inLibrary;

  /// 最近一次播放时所在队列的来源；不知道为 null。
  final MusicPlaySource? source;
}

/// 最近播放的一个来源（专辑 / 歌单 …）。
@immutable
class MusicRecentPlaySource {
  const MusicRecentPlaySource({
    required this.source,
    required this.lastPlayedAt,
  });

  final MusicPlaySource source;
  final int lastPlayedAt;
}

MusicPlaySource? _sourceOfEvent(
  MusicPlayEventRow e,
  Map<String, MusicServerBinding> servers,
) {
  final String? kind = e.sourceKind;
  final String? id = e.sourceId;
  if (kind == null || id == null) return null;
  return MusicPlaySource(
    kind: MusicPlaySourceKind.fromWire(kind),
    id: id,
    title: e.sourceTitle,
    cover: _resolveCover(
      e.sourceCover,
      servers,
      sourceId: _isServerSourceKind(kind) ? id : null,
    ),
  );
}

/// 落库的封面 → 可显示的地址：服务器封面占位由对应服务器的客户端现算（这台设备没配那台
/// 服务器就没有封面）；其余（本地路径 / 公开 http 地址）原样。占位里没写服务器身份（v172
/// 清洗的存量行）时，按播放来源 id（`<服务器身份>/<条目 id>`）的前缀在当前配置里认——服务器
/// 身份本身可能含 `/`（Jellyfin），所以拿配置去比前缀，不从 id 里切。
String? _resolveCover(
  String? stored,
  Map<String, MusicServerBinding> servers, {
  String? sourceId,
}) {
  final MusicServerRef? ref = parseMusicServerRef(stored);
  if (ref == null) return stored;
  if (ref.kind != MusicServerRefKind.cover) return null;
  MusicServerBinding? binding = ref.serverId == null
      ? null
      : servers[ref.serverId];
  if (binding == null && sourceId != null) {
    for (final MapEntry<String, MusicServerBinding> e in servers.entries) {
      if (sourceId.startsWith('${e.key}/')) {
        binding = e.value;
        break;
      }
    }
  }
  return binding?.browser.coverUri(ref.id)?.toString();
}

/// 服务器曲目占位 → 这台设备上配置着的那台服务器：先按占位里的服务器身份，缺（v172 迁移
/// 清洗的存量行只认得出曲目 id）就在所有配置里找；两种都要求
/// `musicServerTrackUid(serverId, 曲目 id) == trackUid`——配错服务器对不上，不会串台。
MusicServerBinding? _bindingOfServerTrack(
  MusicServerRef ref,
  String trackUid,
  Map<String, MusicServerBinding> servers,
) {
  bool matches(String serverId) =>
      musicServerTrackUid(serverId, ref.id) == trackUid;
  final String? serverId = ref.serverId;
  if (serverId != null) {
    final MusicServerBinding? b = servers[serverId];
    return b != null && matches(serverId) ? b : null;
  }
  for (final MapEntry<String, MusicServerBinding> e in servers.entries) {
    if (matches(e.key)) return e.value;
  }
  return null;
}

/// 一条最近播放 → 播放项：曲库里还在的以曲库行为准（封面缺了用快照补），
/// 否则用事件快照重建；两边都没有（不会出现，查询已过滤）返回 null。
///
/// 服务器曲目（快照是身份占位）经 [servers] 里对应的服务器现算播放流与封面；这台设备没配
/// 那台服务器（配置删了 / 记录从别的设备合并来）时，有离线副本（[musicServerLocalCopyLookup]）
/// 就放本机文件，没有才回 null（不可用，不进列表）。
MusicPlayItem? musicPlayItemOfRecent(
  MusicRecentPlay play, {
  Map<String, MusicServerBinding> servers =
      const <String, MusicServerBinding>{},
}) {
  final MusicTrackRow? track = play.track;
  final MusicPlayEventRow e = play.event;
  if (track != null) {
    return musicPlayItemOf(
      track,
      album: play.album,
      coverPath: play.album?.coverPath ?? _resolveCover(e.coverPath, servers),
    );
  }
  final String? path = e.path;
  if (path == null) return null;
  final MusicServerRef? ref = parseMusicServerRef(path);
  if (ref != null) {
    if (ref.kind != MusicServerRefKind.track) return null;
    final MusicServerBinding? binding = _bindingOfServerTrack(
      ref,
      e.trackUid,
      servers,
    );
    final MusicServerRef? cover = parseMusicServerRef(e.coverPath);
    if (binding == null) {
      // 配置删了 / 没配那台服务器：下好的离线副本照样能放（与曲库里的这首同一条路）。
      final MusicServerLocalCopy? local = musicServerLocalCopyLookup?.call(
        e.trackUid,
      );
      if (local == null) return null;
      final String? albumId = ref.albumId;
      return musicServerLocalPlayItem(
        e.trackUid,
        local,
        MusicServerTrack(
          id: local.trackId,
          title: e.title ?? '',
          artist: e.artist,
          album: e.album,
          albumId: albumId,
          durationMs: e.durationMs,
          coverRef: cover?.kind == MusicServerRefKind.cover ? cover!.id : null,
        ),
        albumUid: albumId == null
            ? null
            : musicServerAlbumUid(local.serverId, albumId),
      );
    }
    final MusicPlayItem item = musicServerPlayItem(
      binding.browser,
      MusicServerTrack(
        id: ref.id,
        title: e.title ?? '',
        artist: e.artist,
        album: e.album,
        albumId: ref.albumId,
        durationMs: e.durationMs,
        coverRef: cover?.kind == MusicServerRefKind.cover ? cover!.id : null,
      ),
      maxBitrateKbps: binding.maxBitrateKbps,
    );
    return item;
  }
  return MusicPlayItem(
    trackUid: e.trackUid,
    path: path,
    title: e.title ?? '',
    startMs: e.cueStartMs,
    endMs: e.cueEndMs,
    artist: e.artist,
    album: e.album,
    albumUid: e.albumUid,
    durationMs: e.durationMs,
    coverPath: _resolveCover(e.coverPath, servers),
  );
}

bool _isServerSourceKind(String kind) =>
    kind == MusicPlaySourceKind.serverAlbum.wire ||
    kind == MusicPlaySourceKind.serverPlaylist.wire;

bool _isServerRef(String? stored) => parseMusicServerRef(stored) != null;

/// 有服务器占位时读一次当前的服务器配置（[servers] 缺省 [musicServerBindingLoader]，未装配 =
/// 服务器曲目全部不可用）；没有就不读。
Future<Map<String, MusicServerBinding>> _bindingsIfNeeded(
  bool needed,
  MusicServerBindingLoader? servers,
) async {
  final MusicServerBindingLoader? loader = needed
      ? servers ?? musicServerBindingLoader
      : null;
  return loader == null ? const <String, MusicServerBinding>{} : loader();
}

/// 最近播放的曲目（按曲目去重，新的在前）。服务器曲目经 [servers]（缺省进程级
/// [musicServerBindingLoader]）找回当前配置的服务器，没配的不列出。
Future<List<MusicRecentTrack>> loadRecentMusicTracks(
  FushiDatabase db, {
  int limit = 20,
  MusicServerBindingLoader? servers,
}) async {
  final List<MusicRecentPlay> plays = await db.listRecentMusicPlays(
    limit: limit,
  );
  final Map<String, MusicServerBinding> bound = await _bindingsIfNeeded(
    plays.any(
      (MusicRecentPlay p) =>
          _isServerRef(p.event.path) ||
          _isServerRef(p.event.coverPath) ||
          _isServerRef(p.event.sourceCover),
    ),
    servers,
  );
  return <MusicRecentTrack>[
    for (final MusicRecentPlay p in plays)
      if (musicPlayItemOfRecent(p, servers: bound)
          case final MusicPlayItem item)
        MusicRecentTrack(
          item: item,
          lastPlayedAt: p.lastPlayedAt,
          inLibrary: p.track != null,
          source: _sourceOfEvent(p.event, bound),
        ),
  ];
}

/// 最近播放的来源（按 (种类, id) 去重，新的在前）；[kinds] 非空时只要这些种类。服务器
/// 专辑 / 歌单的封面经 [servers] 现算。
Future<List<MusicRecentPlaySource>> loadRecentMusicSources(
  FushiDatabase db, {
  int limit = 20,
  Set<MusicPlaySourceKind>? kinds,
  MusicServerBindingLoader? servers,
}) async {
  final List<MusicRecentSource> rows = await db.listRecentMusicSources(
    limit: limit,
    kinds: kinds == null
        ? null
        : <String>{for (final MusicPlaySourceKind k in kinds) k.wire},
  );
  final Map<String, MusicServerBinding> bound = await _bindingsIfNeeded(
    rows.any((MusicRecentSource r) => _isServerRef(r.cover)),
    servers,
  );
  return <MusicRecentPlaySource>[
    for (final MusicRecentSource r in rows)
      MusicRecentPlaySource(
        source: MusicPlaySource(
          kind: MusicPlaySourceKind.fromWire(r.kind),
          id: r.id,
          title: r.title,
          cover: _resolveCover(
            r.cover,
            bound,
            sourceId: _isServerSourceKind(r.kind) ? r.id : null,
          ),
        ),
        lastPlayedAt: r.lastPlayedAt,
      ),
  ];
}
