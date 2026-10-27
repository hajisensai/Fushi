/// 人物聚合页的数据层（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md`
/// §5）：从三个模块各自的人物行建 [PersonGraph]，按可靠外部 id 认出同一个人，再把
/// TA 配音的动画角色、游戏角色、演唱的曲目（角色歌）汇成一页。
///
/// 原料（只读各模块已有数据，不为人物页新增元数据主源）：
/// - 视频：`video_metadata_people` + 人物的 provider identities（AniDB / MAL / TMDB）+
///   `video_metadata_credits`；
/// - 游戏：`game_voice_casts`（VNDB `va`，声优自带 AniDB / Wikidata / MusicBrainz
///   外部链接）——游戏详情页打开时按需取一次（[GameVoiceCastService]）；
/// - 音乐：`music_artists`（MBID）+ `music_track_credits`。演唱 / 角色歌署名
///   （`vocal_cv` / `character`）由音乐刮削写入，这里只读；音乐侧还没有这类署名时
///   区块显示空态。
/// - 桥：`person_identity_bridges`（Wikidata 桥接缓存 + 用户确认 / 否决）。
library;

import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/media/people/vndb_voice_cast.dart';
import 'package:fushi_engine/media/people/wikidata_person_bridge.dart';

/// Wikidata 桥接结果多久后重查。
const Duration kPersonWikidataBridgeTtl = Duration(days: 30);

/// 游戏配音表缓存多久后重取。
const Duration kGameVoiceCastTtl = Duration(days: 30);

/// 从数据库建人物图（一次全量读：几万行以内，人物页每次打开重建一次）。
Future<PersonGraph> loadPersonGraph(FushiDatabase db) async {
  final List<PersonRecord> records = <PersonRecord>[];

  // 视频人物 + 外部身份。
  final Map<String, Set<String>> videoIds = <String, Set<String>>{};
  for (final VideoPersonIdentity id in await db.allVideoPersonIdentities()) {
    final String? scheme = personSchemeOfVideoProvider(id.provider);
    if (scheme == null) continue;
    final String? node = personIdNode(scheme, id.externalId);
    if (node == null) continue;
    videoIds.putIfAbsent(id.personKey, () => <String>{}).add(node);
  }
  for (final VideoMetadataPersonRow p in await db.allVideoMetadataPeople()) {
    records.add(
      PersonRecord(
        domain: PersonRefDomain.video,
        key: p.personKey,
        name: p.name,
        originalName: p.originalName,
        idNodes: videoIds[p.personKey] ?? const <String>{},
      ),
    );
  }

  // 游戏声优（同一声优跨多部游戏只算一条记录，外部 id 取并集）。
  final Map<String, ({String name, String? original, Set<String> ids})> staff =
      <String, ({String name, String? original, Set<String> ids})>{};
  for (final GameVoiceCastRow row in await db.allGameVoiceCasts()) {
    for (final GameVoiceCredit c in decodeGameVoiceCast(row.castJson)) {
      final ({String name, String? original, Set<String> ids})? prev =
          staff[c.staffId];
      staff[c.staffId] = (
        name: prev?.name ?? c.staffName,
        original: prev?.original ?? c.staffOriginal,
        ids: <String>{...?prev?.ids, ...c.staffIdNodes},
      );
    }
  }
  staff.forEach((
    String id,
    ({String name, String? original, Set<String> ids}) s,
  ) {
    records.add(
      PersonRecord(
        domain: PersonRefDomain.game,
        key: id,
        name: s.name,
        originalName: s.original,
        idNodes: s.ids,
      ),
    );
  });

  // 音乐艺人（团体 / 角色名义的艺人行也在内：它们没有人物 MBID 就只会出现在建议里）。
  for (final MusicArtistRow a in await db.allMusicArtists()) {
    final String? mb = a.mbArtistId == null
        ? null
        : personIdNode(PersonIdScheme.musicbrainz, a.mbArtistId!);
    records.add(
      PersonRecord(
        domain: PersonRefDomain.music,
        key: a.artistUid,
        name: a.name,
        idNodes: <String>[?mb],
      ),
    );
  }

  final List<(String, String)> sameAs = <(String, String)>[];
  final List<(String, String)> rejected = <(String, String)>[];
  for (final PersonIdentityBridgeRow b in await db.allPersonIdentityBridges()) {
    switch (b.source) {
      case PersonIdentityBridgeSource.wikidata:
        if (b.subject != b.object && b.deletedAt == null) {
          sameAs.add((b.subject, b.object));
        }
      case PersonIdentityBridgeSource.manual:
        if (b.deletedAt == null) {
          sameAs.add((b.subject, b.object));
        } else {
          rejected.add((b.subject, b.object));
        }
    }
  }
  return PersonGraph.build(
    records: records,
    sameAs: sameAs,
    rejected: rejected,
  );
}

/// 这个人里还没查过（或已过期）Wikidata 的外部 id 节点。
Future<Set<String>> personIdsNeedingWikidata(
  FushiDatabase db,
  PersonCluster cluster, {
  required DateTime now,
}) async {
  final Map<String, int> checkedAt = <String, int>{};
  for (final PersonIdentityBridgeRow b in await db.allPersonIdentityBridges()) {
    if (b.source == PersonIdentityBridgeSource.wikidata &&
        b.subject == b.object) {
      checkedAt[b.subject] = b.createdAt;
    }
  }
  final int cutoff = now
      .subtract(kPersonWikidataBridgeTtl)
      .millisecondsSinceEpoch;
  return <String>{
    for (final String id in cluster.idNodes)
      if ((checkedAt[id] ?? -1) < cutoff &&
          buildWikidataPersonQuery(<String>[id]) != null)
        id,
  };
}

/// 对这个人跑一轮 Wikidata 桥接并落库。返回是否得到了新的等价 id（调用方据此重建
/// 图）。网络失败抛 [WikidataPersonBridgeException]（不落「查过」标记）。
Future<bool> refreshPersonWikidataBridges(
  FushiDatabase db,
  PersonCluster cluster, {
  WikidataPersonBridge? bridge,
  DateTime Function() now = DateTime.now,
}) async {
  final Set<String> ids = await personIdsNeedingWikidata(
    db,
    cluster,
    now: now(),
  );
  if (ids.isEmpty) return false;
  final Map<String, Set<String>> eq =
      await (bridge ?? WikidataPersonBridge.shared).equivalentsOf(ids);
  await db.replaceWikidataPersonBridges(eq, at: now().millisecondsSinceEpoch);
  return eq.values.any(
    (Set<String> s) => s.any((String n) => !cluster.idNodes.contains(n)),
  );
}

// ── 「同一人」裁决 ─────────────────────────────────────────────────

/// 人物页「可能是同一人」的「是同一人 / 不是」（[same]）：两个人各取代表节点（首条
/// 本地记录），写一条 manual 桥（否决 = 墓碑，之后不再建议这一对）。人物页与控制
/// 通道都只调它。返回写下的那一对节点。
Future<(String, String)> decidePersonIdentity(
  FushiDatabase db,
  PersonCluster self,
  PersonCluster other, {
  required bool same,
  DateTime Function() now = DateTime.now,
}) async {
  final (String, String) pair = (
    self.records.first.node,
    other.records.first.node,
  );
  await db.setManualPersonBridge(
    pair.$1,
    pair.$2,
    same: same,
    at: now().millisecondsSinceEpoch,
  );
  return pair;
}

/// 人物页「取消合并」：把一对手动合并（[PersonPageData.manualPairs] 的一项）改成
/// 否决墓碑。
Future<void> unmergePersonPair(
  FushiDatabase db,
  (String, String) pair, {
  DateTime Function() now = DateTime.now,
}) => db.setManualPersonBridge(
  pair.$1,
  pair.$2,
  same: false,
  at: now().millisecondsSinceEpoch,
);

// ── 人物页明细 ─────────────────────────────────────────────────────

/// 一个可点开的作品端点 + 卡片上的图（本地路径 / URL 二选一，可都空）。
class PersonWorkLink {
  const PersonWorkLink({required this.entry, this.imagePath, this.imageUrl});

  final MediaLinkEntry entry;
  final String? imagePath;
  final String? imageUrl;
}

/// 动画 / 视频里的一个角色或职位。
class PersonVideoRole {
  const PersonVideoRole({
    required this.work,
    required this.isVoice,
    this.characterName,
    this.roleLabel,
  });

  final PersonWorkLink work;
  final bool isVoice;

  /// 配音的角色名（[isVoice] 时）。
  final String? characterName;

  /// 非配音 credit 的职位 / creditKind。
  final String? roleLabel;
}

/// 游戏里的一个角色。
class PersonGameRole {
  const PersonGameRole({
    required this.work,
    required this.characterName,
    this.characterOriginal,
    this.note,
  });

  final PersonWorkLink work;
  final String characterName;
  final String? characterOriginal;
  final String? note;
}

/// 一首署名里有 TA 的曲目。
class PersonSong {
  const PersonSong({
    required this.work,
    required this.roles,
    this.characterNames = const <String>[],
  });

  final PersonWorkLink work;

  /// TA 在这首歌里的署名角色（`vocal_cv` / `artist` / …）。
  final List<String> roles;

  /// 同一曲目上的角色名义（角色歌）。
  final List<String> characterNames;

  bool get isCharacterSong =>
      roles.contains('vocal_cv') || characterNames.isNotEmpty;
}

/// 人物页一次加载的全部内容。
class PersonPageData {
  const PersonPageData({
    required this.cluster,
    required this.videoRoles,
    required this.videoStaff,
    required this.gameRoles,
    required this.songs,
    required this.suggestions,
    required this.manualPairs,
    this.photoPath,
    this.photoUrl,
  });

  final PersonCluster cluster;
  final List<PersonVideoRole> videoRoles;
  final List<PersonVideoRole> videoStaff;
  final List<PersonGameRole> gameRoles;
  final List<PersonSong> songs;
  final List<PersonSuggestion> suggestions;

  /// 两端都在本人里的手动合并（可「取消合并」）。
  final List<(String, String)> manualPairs;
  final String? photoPath;
  final String? photoUrl;

  bool get isEmpty =>
      videoRoles.isEmpty &&
      videoStaff.isEmpty &&
      gameRoles.isEmpty &&
      songs.isEmpty;
}

/// 读出 [seedNode]（`ref:…`）所在的人的整页内容；图里没有这个节点返回 null。
Future<PersonPageData?> loadPersonPage(
  FushiDatabase db,
  String seedNode, {
  PersonGraph? graph,
}) async {
  final PersonGraph g = graph ?? await loadPersonGraph(db);
  final PersonCluster? cluster = g.clusterOf(seedNode);
  if (cluster == null) return null;

  final Set<String> personKeys = <String>{
    for (final PersonRecord r in cluster.inDomain(PersonRefDomain.video)) r.key,
  };
  final ({List<PersonVideoRole> voice, List<PersonVideoRole> staff}) video =
      await _videoRoles(db, personKeys);

  String? photoPath;
  String? photoUrl;
  for (final VideoMetadataPersonRow p in await db.videoPeopleByKeys(
    personKeys,
  )) {
    photoPath ??= p.profilePath;
    photoUrl ??= p.profileUrl;
  }

  final Set<String> staffIds = <String>{
    for (final PersonRecord r in cluster.inDomain(PersonRefDomain.game)) r.key,
  };
  final List<PersonGameRole> games = await _gameRoles(db, staffIds);

  final Set<String> artistUids = <String>{
    for (final PersonRecord r in cluster.inDomain(PersonRefDomain.music)) r.key,
  };
  final List<PersonSong> songs = await _songs(db, artistUids);

  final Set<String> nodes = <String>{
    for (final PersonRecord r in cluster.records) r.node,
    ...cluster.idNodes,
  };
  final List<(String, String)> manualPairs = <(String, String)>[
    for (final PersonIdentityBridgeRow b in await db.allPersonIdentityBridges())
      if (b.source == PersonIdentityBridgeSource.manual &&
          b.deletedAt == null &&
          nodes.contains(b.subject) &&
          nodes.contains(b.object))
        (b.subject, b.object),
  ];

  return PersonPageData(
    cluster: cluster,
    videoRoles: video.voice,
    videoStaff: video.staff,
    gameRoles: games,
    songs: songs,
    suggestions: g.suggestionsFor(cluster),
    manualPairs: manualPairs,
    photoPath: photoPath,
    photoUrl: photoUrl,
  );
}

Future<({List<PersonVideoRole> voice, List<PersonVideoRole> staff})>
_videoRoles(FushiDatabase db, Set<String> personKeys) async {
  final List<VideoMetadataCreditRow> credits = await db.videoCreditsForPeople(
    personKeys,
  );
  if (credits.isEmpty) {
    return (voice: const <PersonVideoRole>[], staff: const <PersonVideoRole>[]);
  }
  final Map<int, int> seasonWork = await db.videoWorkIdsForSeasons(<int>{
    for (final VideoMetadataCreditRow c in credits) ?c.seasonId,
  });
  final Map<int, int> episodeWork = await db.videoWorkIdsForEpisodes(<int>{
    for (final VideoMetadataCreditRow c in credits) ?c.episodeId,
  });
  int? workOf(VideoMetadataCreditRow c) =>
      c.workId ??
      (c.seasonId == null ? null : seasonWork[c.seasonId]) ??
      (c.episodeId == null ? null : episodeWork[c.episodeId]);
  final Map<int, VideoMetadataWorkRow> works = <int, VideoMetadataWorkRow>{
    for (final VideoMetadataWorkRow w in await db.videoWorksByIds(<int>{
      for (final VideoMetadataCreditRow c in credits) ?workOf(c),
    }))
      w.id: w,
  };
  final Map<String, VideoMetadataCharacterRow> characters =
      <String, VideoMetadataCharacterRow>{
        for (final VideoMetadataCharacterRow ch
            in await db.videoCharactersByKeys(<String>{
              for (final VideoMetadataCreditRow c in credits) ?c.characterKey,
            }))
          ch.characterKey: ch,
      };
  final Map<int, MediaLinkEntry> entries = <int, MediaLinkEntry>{};
  for (final VideoMetadataWorkRow w in works.values) {
    final MediaLinkEndpoint? endpoint = w.collectionId != null
        ? (
            kind: MediaLinkKind.videoCollection,
            key: collectionTagEntryKey(w.collectionId!),
          )
        : (w.bookUid == null
              ? null
              : (kind: MediaLinkKind.videoEpisode, key: w.bookUid!));
    if (endpoint == null) continue;
    final MediaLinkEntry e = await resolveMediaLinkEntry(db, endpoint);
    entries[w.id] = MediaLinkEntry(
      endpoint: e.endpoint,
      // 合集已删时键是本机 id，标题退回刮削作品名。
      title: e.inLibrary ? e.title : w.title,
      inLibrary: e.inLibrary,
      coverPath: e.coverPath,
    );
  }
  final List<PersonVideoRole> voice = <PersonVideoRole>[];
  final List<PersonVideoRole> staff = <PersonVideoRole>[];
  final Set<String> seen = <String>{};
  for (final VideoMetadataCreditRow c in credits) {
    final int? workId = workOf(c);
    final MediaLinkEntry? entry = workId == null ? null : entries[workId];
    if (entry == null) continue;
    final bool isVoice = c.creditKind == 'voice_actor';
    final VideoMetadataCharacterRow? ch = c.characterKey == null
        ? null
        : characters[c.characterKey];
    final String? characterName = isVoice
        ? (ch?.originalName ?? ch?.name ?? _nonEmpty(c.roleName))
        : null;
    final String? roleLabel = isVoice
        ? null
        : (_nonEmpty(c.job) ?? _nonEmpty(c.roleName) ?? c.creditKind);
    final String dedupe =
        '$workId|$isVoice|${c.characterKey ?? characterName ?? roleLabel}';
    if (!seen.add(dedupe)) continue;
    final PersonVideoRole role = PersonVideoRole(
      work: PersonWorkLink(
        entry: entry,
        // 配音卡优先角色图，其余用作品封面（卡片组件按路径 / URL 回退）。
        imagePath: (isVoice ? ch?.imagePath : null) ?? entry.coverPath,
        imageUrl: isVoice ? ch?.imageUrl : null,
      ),
      isVoice: isVoice,
      characterName: characterName,
      roleLabel: roleLabel,
    );
    (isVoice ? voice : staff).add(role);
  }
  return (voice: voice, staff: staff);
}

Future<List<PersonGameRole>> _gameRoles(
  FushiDatabase db,
  Set<String> staffIds,
) async {
  if (staffIds.isEmpty) return const <PersonGameRole>[];
  final List<PersonGameRole> out = <PersonGameRole>[];
  for (final GameVoiceCastRow row in await db.allGameVoiceCasts()) {
    final List<GameVoiceCredit> mine = <GameVoiceCredit>[
      for (final GameVoiceCredit c in decodeGameVoiceCast(row.castJson))
        if (staffIds.contains(c.staffId)) c,
    ];
    if (mine.isEmpty) continue;
    final MediaLinkEntry entry = await resolveMediaLinkEntry(db, (
      kind: MediaLinkKind.game,
      key: row.gameId,
    ));
    // 游戏已删（孤儿缓存行）不列：点了没去处。
    if (!entry.inLibrary) continue;
    for (final GameVoiceCredit c in mine) {
      out.add(
        PersonGameRole(
          work: PersonWorkLink(
            entry: entry,
            imagePath: c.characterImageUrl == null ? entry.coverPath : null,
            imageUrl: c.characterImageUrl,
          ),
          characterName: c.characterOriginal ?? c.characterName,
          characterOriginal: c.characterOriginal == null
              ? null
              : c.characterName,
          note: c.note,
        ),
      );
    }
  }
  return out;
}

Future<List<PersonSong>> _songs(
  FushiDatabase db,
  Set<String> artistUids,
) async {
  final List<MusicTrackCreditRow> mine = await db.musicCreditsForArtists(
    artistUids,
  );
  if (mine.isEmpty) return const <PersonSong>[];
  final Map<String, List<String>> rolesByTrack = <String, List<String>>{};
  for (final MusicTrackCreditRow c in mine) {
    rolesByTrack.putIfAbsent(c.trackUid, () => <String>[]).add(c.role);
  }
  final Map<String, List<String>> characterNames = <String, List<String>>{};
  for (final MusicCreditWithArtist c in await db.musicCreditsForTracks(
    rolesByTrack.keys.toSet(),
  )) {
    if (c.credit.role != 'character') continue;
    characterNames
        .putIfAbsent(c.credit.trackUid, () => <String>[])
        .add(c.credit.creditName);
  }
  final List<PersonSong> out = <PersonSong>[];
  for (final MapEntry<String, List<String>> e in rolesByTrack.entries) {
    final MediaLinkEntry entry = await resolveMediaLinkEntry(db, (
      kind: MediaLinkKind.musicTrack,
      key: e.key,
    ));
    if (!entry.inLibrary) continue;
    out.add(
      PersonSong(
        work: PersonWorkLink(entry: entry, imagePath: entry.coverPath),
        roles: e.value,
        characterNames: characterNames[e.key] ?? const <String>[],
      ),
    );
  }
  // 角色歌在前，其余按标题。
  out.sort((PersonSong a, PersonSong b) {
    if (a.isCharacterSong != b.isCharacterSong) {
      return a.isCharacterSong ? -1 : 1;
    }
    return a.work.entry.title.compareTo(b.work.entry.title);
  });
  return out;
}

String? _nonEmpty(String? s) {
  final String? t = s?.trim();
  return t == null || t.isEmpty ? null : t;
}

// ── 游戏配音表 ─────────────────────────────────────────────────────

/// 游戏详情页的配音表：读缓存；缺失 / 过期 / 换绑了 VN 时向 VNDB 取一次并落库。
class GameVoiceCastService {
  GameVoiceCastService(this._db, {VndbVoiceCastClient? client})
    : _client = client ?? VndbVoiceCastClient.shared;

  final FushiDatabase _db;
  final VndbVoiceCastClient _client;

  Future<List<GameVoiceCredit>> cached(String gameId) async {
    final GameVoiceCastRow? row = await _db.getGameVoiceCast(gameId);
    return row == null
        ? const <GameVoiceCredit>[]
        : decodeGameVoiceCast(row.castJson);
  }

  /// 缓存需要（重）取时取一次。返回是否写了新缓存。网络 / 解析失败只记诊断日志、
  /// 不写缓存（下次打开再试），不抛给 UI。
  Future<bool> refreshIfStale(
    String gameId,
    String vndbId, {
    DateTime Function() now = DateTime.now,
  }) async {
    final String id = vndbId.trim().toLowerCase();
    final GameVoiceCastRow? row = await _db.getGameVoiceCast(gameId);
    final int cutoff = now().subtract(kGameVoiceCastTtl).millisecondsSinceEpoch;
    if (row != null && row.vndbId == id && row.fetchedAt >= cutoff) {
      return false;
    }
    final List<GameVoiceCredit>? cast;
    try {
      cast = await _client.fetch(id);
    } on VndbVoiceCastException catch (e) {
      ErrorLogService.instance.logDiagnostic('GameVoiceCast.fetch', '$id: $e');
      return false;
    }
    await _db.upsertGameVoiceCast(
      GameVoiceCastsCompanion.insert(
        gameId: gameId,
        vndbId: id,
        castJson: encodeGameVoiceCast(cast ?? const <GameVoiceCredit>[]),
        fetchedAt: now().millisecondsSinceEpoch,
      ),
    );
    return true;
  }
}
