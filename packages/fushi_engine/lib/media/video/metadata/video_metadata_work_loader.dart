/// 从 Drift 表反向装载 [VideoMetadataWork]。
///
/// 这是 `VideoMetadataDatabaseStore.apply` 的逆操作：apply 把领域模型拆进
/// works / seasons / episodes / provider_identities / terms / credits+people+
/// characters / images / extras 九张表，这里逐表读回拼成一个作品。互联 host 用它
/// 把已刮好的资料整块搬上 wire（spec `2026-09-12-interconnect-scrape-metadata.md`
/// §1.2）。
///
/// 已知不可逆之处（apply 写了但读不回来、或模型有字段而 DB 没列）集中记在
/// [loadVideoMetadataWork] 的文档里，改 schema 前先看那份清单。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';

/// 把 [row] 及其全部子表装载成领域模型。
///
/// - `provider`：取 work 级主身份（`isPrimary`）的 provider；没有主身份取第一条
///   身份；一条身份都没有（例如扫描器写的 `local` 骨架作品）抛 [StateError]——
///   调用方先用 [lookupOfWork] 过滤，别拿它当探测手段。
/// - `kind`：`row.mediaType`；非法值抛 [StateError]。
///
/// 与 apply 的差异清单（读回来的东西和当初写进去的不一样）：
/// 1. `aliases` / `seasonCount` / `episodeCount`：`VideoMetadataWorks` 没这三列，
///    读回恒为空 / null（`episodeCount` 只进了旧投影 `collection_scrape_meta`）。
/// 2. `rawPayload`：进的是 `video_metadata_raw_snapshots`，这里不读（本来就不
///    上 wire）。
/// 3. `VideoMetadataId.isDefault`：apply 不存它，存的是「type == 主 provider」
///    算出来的 `isPrimary`；读回用 `isPrimary` 回填。id 的 type 被 apply 小写、
///    value 被 trim。
/// 4. terms：apply 按 `TitleNormalizer` 归一化去重，同一种类里归一化后相同的词
///    只剩第一条；`name` 保留原文。
/// 5. credits：apply 把 `roleName ?? character.name ?? ''` 写进 `roleName` 列，
///    所以原本 null 的 roleName 读回变成角色名；按 (person, kind, roleName) 去重。
///    `VideoMetadataPerson.id` / `VideoMetadataCharacter.id` 没列，读回 null；
///    `VideoMetadataCharacter.originalName` 没列，读回 null。人物 / 角色的 ids
///    是跨作品累积合并的（`_mergeEntityIdentities`），可能比当初这一部作品给
///    的多。
/// 6. images：`likes` / `seasonNumber` / `episodeNumber` 没列，读回 null；
///    `rating` ← `voteAverage`。DB 按 (kind, position) 排序，所以跨图种的原始
///    交错顺序丢失、同图种内顺序保留。被字段锁保住的旧图行会照读出来。
/// 7. extras：只有 `remoteUrl != null` 的在线附件进了库；本地附件
///    （`sourceKind == 'local'`，绑 host 自己的 bookUid）对客户端没意义，这里
///    不读。
/// 8. seasons / episodes：DB 的 `title` 可空，模型必填——读回 `?? ''`；
///    `VideoMetadataSeasons.endDate` 列模型没有，读不回。
/// 9. `lockedFields` / `updatedAt`：模型没有，由 wire entry 另行携带。
Future<VideoMetadataWork> loadVideoMetadataWork(
  FushiDatabase db,
  VideoMetadataWorkRow row,
) async {
  final VideoMetadataMediaKind? kind =
      VideoMetadataMediaKind.values.asNameMap()[row.mediaType];
  if (kind == null) {
    throw StateError('work ${row.id} 的 mediaType 非法: ${row.mediaType}');
  }
  final List<VideoMetadataProviderIdentityRow> identities =
      await db.getVideoMetadataProviderIdentities(workId: row.id);
  // getVideoMetadataProviderIdentities 已按 isPrimary DESC 排：主身份在最前。
  final VideoMetadataProviderIdentityRow? primary = identities.firstOrNull;
  final VideoMetadataProviderKind? provider = primary == null
      ? null
      : VideoMetadataProviderKind.values.asNameMap()[primary.provider];
  if (provider == null) {
    throw StateError(
      'work ${row.id} 没有可用的 provider 身份（${primary?.provider}）',
    );
  }
  final Map<String, List<String>> terms = await _termsByKind(db, row.id);
  return VideoMetadataWork(
    provider: provider,
    kind: kind,
    title: row.title,
    originalTitle: row.originalTitle,
    tagline: row.tagline,
    year: row.year,
    premiered: row.premiereDate,
    endDate: row.endDate,
    plot: row.overview,
    rating: row.rating,
    ratingVotes: row.ratingCount,
    runtimeMinutes: row.runtimeMinutes,
    contentRating: row.contentRating,
    status: row.status,
    originalLanguage: row.originalLanguage,
    homepage: row.homepage,
    episodeGroupId: row.episodeGroupId,
    genres: terms['genre'] ?? const <String>[],
    studios: terms['studio'] ?? const <String>[],
    countries: terms['country'] ?? const <String>[],
    keywords: terms['keyword'] ?? const <String>[],
    ids: identities.map(_idOf).toList(),
    credits: await _loadCredits(db, workId: row.id),
    images: _imagesOf(await db.getVideoMetadataImages(workId: row.id)),
    seasons: await _loadSeasons(db, row.id),
    extras: _extrasOf(await db.getVideoMetadataExtras(row.id)),
  );
}

/// 按 workId 取主身份对应的 lookup。语义与
/// `VideoMetadataDatabaseStore.confirmedLookup` 一致：没有主身份、provider 非法
/// 或为 `fanart`、mediaType 非法都返回 null。
Future<VideoMetadataLookup?> lookupOfWork(FushiDatabase db, int workId) async {
  final VideoMetadataWorkRow? row = await db.getVideoMetadataWorkById(workId);
  if (row == null) return null;
  final List<VideoMetadataProviderIdentityRow> identities =
      await db.getVideoMetadataProviderIdentities(workId: workId);
  final VideoMetadataProviderIdentityRow? identity = identities
      .where((VideoMetadataProviderIdentityRow value) => value.isPrimary)
      .firstOrNull;
  if (identity == null) return null;
  final VideoMetadataProviderKind? provider =
      VideoMetadataProviderKind.values.asNameMap()[identity.provider];
  final VideoMetadataMediaKind? kind =
      VideoMetadataMediaKind.values.asNameMap()[row.mediaType];
  if (provider == null ||
      provider == VideoMetadataProviderKind.fanart ||
      kind == null) {
    return null;
  }
  return VideoMetadataLookup(
    provider: provider,
    externalId: identity.externalId,
    mediaKind: kind,
    episodeGroupId: row.episodeGroupId,
  );
}

// ─── 子表 ────────────────────────────────────────────────────────────

Future<Map<String, List<String>>> _termsByKind(
  FushiDatabase db,
  int workId,
) async {
  final Map<String, List<String>> out = <String, List<String>>{};
  for (final VideoMetadataTermRow term
      in await db.getVideoMetadataTermsForWork(workId)) {
    out.putIfAbsent(term.kind, () => <String>[]).add(term.name);
  }
  return out;
}

Future<List<VideoMetadataSeason>> _loadSeasons(
  FushiDatabase db,
  int workId,
) async {
  final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[];
  for (final VideoMetadataSeasonRow season
      in await db.getVideoMetadataSeasons(workId)) {
    seasons.add(VideoMetadataSeason(
      seasonNumber: season.seasonNumber,
      title: season.title ?? '',
      plot: season.overview,
      airDate: season.premiereDate,
      year: season.year,
      episodeCount: season.episodeCount,
      rating: season.rating,
      ids: (await db.getVideoMetadataProviderIdentities(seasonId: season.id))
          .map(_idOf)
          .toList(),
      images: _imagesOf(await db.getVideoMetadataImages(seasonId: season.id)),
      episodes: await _loadEpisodes(db, season),
    ));
  }
  return seasons;
}

Future<List<VideoMetadataEpisode>> _loadEpisodes(
  FushiDatabase db,
  VideoMetadataSeasonRow season,
) async {
  final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[];
  for (final VideoMetadataEpisodeRow episode
      in await db.getVideoMetadataEpisodes(season.id)) {
    episodes.add(VideoMetadataEpisode(
      seasonNumber: season.seasonNumber,
      episodeNumber: episode.episodeNumber,
      title: episode.title ?? '',
      plot: episode.overview,
      airDate: episode.airDate,
      year: episode.year,
      absoluteNumber: episode.absoluteNumber,
      rating: episode.rating,
      ratingVotes: episode.ratingCount,
      runtimeMinutes: episode.runtimeMinutes,
      ids: (await db.getVideoMetadataProviderIdentities(episodeId: episode.id))
          .map(_idOf)
          .toList(),
      credits: await _loadCredits(db, episodeId: episode.id),
      images: _imagesOf(await db.getVideoMetadataImages(episodeId: episode.id)),
    ));
  }
  return episodes;
}

/// 读一个 owner（work 或 episode）的职员表，顺带把人物 / 角色及其身份读齐。
/// 人物 / 角色行被级联删掉（理论上不会——credits 引用它们）的条目跳过。
Future<List<VideoMetadataCredit>> _loadCredits(
  FushiDatabase db, {
  int? workId,
  int? episodeId,
}) async {
  final List<VideoMetadataCredit> credits = <VideoMetadataCredit>[];
  final Map<String, VideoMetadataPerson> people =
      <String, VideoMetadataPerson>{};
  final Map<String, VideoMetadataCharacter> characters =
      <String, VideoMetadataCharacter>{};
  for (final VideoMetadataCreditRow credit in await db.getVideoMetadataCredits(
    workId: workId,
    episodeId: episodeId,
  )) {
    final VideoMetadataCreditKind? kind = _creditKindOf(credit.creditKind);
    if (kind == null) continue;
    VideoMetadataPerson? person = people[credit.personKey];
    if (person == null) {
      person = await _loadPerson(db, credit.personKey);
      if (person == null) continue;
      people[credit.personKey] = person;
    }
    VideoMetadataCharacter? character;
    if (credit.characterKey case final String characterKey) {
      character =
          characters[characterKey] ?? await _loadCharacter(db, characterKey);
      if (character != null) characters[characterKey] = character;
    }
    credits.add(VideoMetadataCredit(
      kind: kind,
      person: person,
      character: character,
      language: credit.language,
      roleName: credit.roleName.isEmpty ? null : credit.roleName,
      department: credit.department,
      job: credit.job,
      providerCreditId: credit.providerCreditId,
      order: credit.sortOrder,
    ));
  }
  return credits;
}

Future<VideoMetadataPerson?> _loadPerson(
  FushiDatabase db,
  String personKey,
) async {
  final VideoMetadataPersonRow? row =
      await db.getVideoMetadataPerson(personKey);
  if (row == null) return null;
  return VideoMetadataPerson(
    name: row.name,
    originalName: row.originalName,
    biography: row.biography,
    birthday: row.birthday,
    deathday: row.deathday,
    gender: row.gender,
    placeOfBirth: row.placeOfBirth,
    profileUrl: row.profileUrl,
    ids: (await db.getVideoMetadataProviderIdentities(personKey: personKey))
        .map(_idOf)
        .toList(),
  );
}

Future<VideoMetadataCharacter?> _loadCharacter(
  FushiDatabase db,
  String characterKey,
) async {
  final VideoMetadataCharacterRow? row =
      await db.getVideoMetadataCharacter(characterKey);
  if (row == null) return null;
  return VideoMetadataCharacter(
    name: row.name,
    description: row.description,
    imageUrl: row.imageUrl,
    ids: (await db.getVideoMetadataProviderIdentities(
      characterKey: characterKey,
    ))
        .map(_idOf)
        .toList(),
  );
}

// ─── 行 → 模型 ───────────────────────────────────────────────────────

VideoMetadataId _idOf(VideoMetadataProviderIdentityRow row) => VideoMetadataId(
      type: row.provider,
      value: row.externalId,
      isDefault: row.isPrimary,
    );

/// provider / kind 列值不在枚举内的图行跳过（历史 provider 只读兼容）。
List<VideoMetadataImage> _imagesOf(List<VideoMetadataImageRow> rows) =>
    <VideoMetadataImage>[
      for (final VideoMetadataImageRow row in rows)
        if ((
          VideoMetadataImageKind.values.asNameMap()[row.kind],
          VideoMetadataProviderKind.values.asNameMap()[row.provider],
        )
            case (
              final VideoMetadataImageKind kind,
              final VideoMetadataProviderKind provider,
            ))
          VideoMetadataImage(
            kind: kind,
            url: row.remoteUrl,
            provider: provider,
            language: row.language,
            voteAverage: row.rating,
            voteCount: row.voteCount,
          ),
    ];

/// 只读在线附件；kind 列值不在枚举内的行跳过。
List<VideoMetadataExtra> _extrasOf(List<VideoMetadataExtraRow> rows) =>
    <VideoMetadataExtra>[
      for (final VideoMetadataExtraRow row in rows)
        if (row.sourceKind == 'online')
          if (_extraKindOf(row.kind) case final VideoMetadataExtraKind kind)
            VideoMetadataExtra(
              kind: kind,
              title: row.title,
              provider: row.provider == null
                  ? null
                  : VideoMetadataProviderKind.values.asNameMap()[row.provider!],
              providerVideoId: row.providerVideoId,
              site: row.site,
              remoteUrl: row.remoteUrl,
              thumbnailUrl: row.thumbnailUrl,
              durationMs: row.durationMs,
              official: row.official,
              language: row.language,
              publishedAt: row.publishedAt,
              order: row.sortOrder,
            ),
    ];

/// `_creditKind` 的逆：`voice_actor` → [VideoMetadataCreditKind.voiceActor]，
/// 其余按枚举名。
VideoMetadataCreditKind? _creditKindOf(String value) => switch (value) {
      'voice_actor' => VideoMetadataCreditKind.voiceActor,
      _ => VideoMetadataCreditKind.values.asNameMap()[value],
    };

/// `_extraKind` 的逆：snake_case 的两个值映回枚举，其余按枚举名。
VideoMetadataExtraKind? _extraKindOf(String value) => switch (value) {
      'behind_the_scenes' => VideoMetadataExtraKind.behindTheScenes,
      'deleted_scene' => VideoMetadataExtraKind.deletedScene,
      _ => VideoMetadataExtraKind.values.asNameMap()[value],
    };
