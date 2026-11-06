/// 音乐播放流（history，唯一含义：最近播放）的 app 侧读写：播放项 ↔ 事件快照、
/// 最近播放的曲目 / 来源（推荐页「最近播放」）。表与查询在 `fushi_core`
/// （`music_play_events`，v139 起带快照与来源）。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

/// 播放项 + 队列来源 → 落库快照（重播所需的字段都在里面）。
MusicPlayEventSnapshot musicPlayEventSnapshotOf(
  MusicPlayItem item, {
  MusicPlaySource? source,
}) => MusicPlayEventSnapshot(
  path: item.path,
  cueStartMs: item.startMs,
  cueEndMs: item.endMs,
  title: item.title,
  artist: item.artist,
  album: item.album,
  albumUid: item.albumUid,
  durationMs: item.durationMs,
  coverPath: item.coverPath,
  sourceKind: source?.kind.wire,
  sourceId: source?.id,
  sourceTitle: source?.title,
  sourceCover: source?.cover,
);

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

MusicPlaySource? _sourceOfEvent(MusicPlayEventRow e) {
  final String? kind = e.sourceKind;
  final String? id = e.sourceId;
  if (kind == null || id == null) return null;
  return MusicPlaySource(
    kind: MusicPlaySourceKind.fromWire(kind),
    id: id,
    title: e.sourceTitle,
    cover: e.sourceCover,
  );
}

/// 一条最近播放 → 播放项：曲库里还在的以曲库行为准（封面缺了用快照补），
/// 否则用事件快照重建；两边都没有（不会出现，查询已过滤）返回 null。
MusicPlayItem? musicPlayItemOfRecent(MusicRecentPlay play) {
  final MusicTrackRow? track = play.track;
  final MusicPlayEventRow e = play.event;
  if (track != null) {
    return musicPlayItemOf(
      track,
      album: play.album,
      coverPath: play.album?.coverPath ?? e.coverPath,
    );
  }
  final String? path = e.path;
  if (path == null) return null;
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
    coverPath: e.coverPath,
  );
}

/// 最近播放的曲目（按曲目去重，新的在前）。
Future<List<MusicRecentTrack>> loadRecentMusicTracks(
  FushiDatabase db, {
  int limit = 20,
}) async {
  final List<MusicRecentPlay> plays = await db.listRecentMusicPlays(
    limit: limit,
  );
  return <MusicRecentTrack>[
    for (final MusicRecentPlay p in plays)
      if (musicPlayItemOfRecent(p) case final MusicPlayItem item)
        MusicRecentTrack(
          item: item,
          lastPlayedAt: p.lastPlayedAt,
          inLibrary: p.track != null,
          source: _sourceOfEvent(p.event),
        ),
  ];
}

/// 最近播放的来源（按 (种类, id) 去重，新的在前）；[kinds] 非空时只要这些种类。
Future<List<MusicRecentPlaySource>> loadRecentMusicSources(
  FushiDatabase db, {
  int limit = 20,
  Set<MusicPlaySourceKind>? kinds,
}) async {
  final List<MusicRecentSource> rows = await db.listRecentMusicSources(
    limit: limit,
    kinds: kinds == null
        ? null
        : <String>{for (final MusicPlaySourceKind k in kinds) k.wire},
  );
  return <MusicRecentPlaySource>[
    for (final MusicRecentSource r in rows)
      MusicRecentPlaySource(
        source: MusicPlaySource(
          kind: MusicPlaySourceKind.fromWire(r.kind),
          id: r.id,
          title: r.title,
          cover: r.cover,
        ),
        lastPlayedAt: r.lastPlayedAt,
      ),
  ];
}
