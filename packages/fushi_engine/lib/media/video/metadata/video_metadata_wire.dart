/// [VideoMetadataWork] / [VideoMetadataLookup] 的 JSON wire 编解码。
///
/// 供互联同步把 host 刮好的作品资料整块搬到客户端（spec
/// `docs/specs/2026-09-12-interconnect-scrape-metadata.md` §1.2）。
///
/// 约定：
/// - 枚举一律用 `.name` 上 wire；解码认不出的枚举值按「缺失」处理（可空字段置
///   null、列表元素丢弃），只有 [VideoMetadataWork.provider] / `kind` 这两个必需
///   字段缺失或非法时抛 [FormatException]。
/// - [VideoMetadataWork.rawPayload] 不上 wire：encode 忽略，decode 置 null。
/// - 解码对缺失 / 类型错误的字段容错，走 `video_metadata_json.dart` 的 helper。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';

// ─── 作品 ────────────────────────────────────────────────────────────

Map<String, Object?> encodeVideoMetadataWork(VideoMetadataWork work) =>
    <String, Object?>{
      'provider': work.provider.name,
      'kind': work.kind.name,
      'title': work.title,
      'originalTitle': work.originalTitle,
      'tagline': work.tagline,
      'aliases': work.aliases,
      'year': work.year,
      'premiered': work.premiered,
      'endDate': work.endDate,
      'plot': work.plot,
      'rating': work.rating,
      'ratingVotes': work.ratingVotes,
      'runtimeMinutes': work.runtimeMinutes,
      'contentRating': work.contentRating,
      'status': work.status,
      'originalLanguage': work.originalLanguage,
      'homepage': work.homepage,
      'episodeGroupId': work.episodeGroupId,
      'seasonCount': work.seasonCount,
      'episodeCount': work.episodeCount,
      'genres': work.genres,
      'studios': work.studios,
      'countries': work.countries,
      'keywords': work.keywords,
      'ids': work.ids.map(_encodeId).toList(),
      'credits': work.credits.map(_encodeCredit).toList(),
      'images': work.images.map(_encodeImage).toList(),
      'seasons': work.seasons.map(_encodeSeason).toList(),
      'extras': work.extras.map(_encodeExtra).toList(),
    };

/// 解码作品。`provider` / `kind` 缺失或不是合法枚举名时抛 [FormatException]。
VideoMetadataWork decodeVideoMetadataWork(Map<String, Object?> json) {
  final VideoMetadataProviderKind? provider =
      _providerKind(metadataString(json['provider']));
  if (provider == null) {
    throw FormatException(
      'VideoMetadataWork wire: provider 缺失或非法: ${json['provider']}',
    );
  }
  final VideoMetadataMediaKind? kind = VideoMetadataMediaKind.values
      .asNameMap()[metadataString(json['kind']) ?? ''];
  if (kind == null) {
    throw FormatException(
      'VideoMetadataWork wire: kind 缺失或非法: ${json['kind']}',
    );
  }
  return VideoMetadataWork(
    provider: provider,
    kind: kind,
    title: metadataString(json['title']) ?? '',
    originalTitle: metadataString(json['originalTitle']),
    tagline: metadataString(json['tagline']),
    aliases: _stringList(json['aliases']),
    year: metadataInt(json['year']),
    premiered: metadataString(json['premiered']),
    endDate: metadataString(json['endDate']),
    plot: metadataString(json['plot']),
    rating: metadataDouble(json['rating']),
    ratingVotes: metadataInt(json['ratingVotes']),
    runtimeMinutes: metadataInt(json['runtimeMinutes']),
    contentRating: metadataString(json['contentRating']),
    status: metadataString(json['status']),
    originalLanguage: metadataString(json['originalLanguage']),
    homepage: metadataString(json['homepage']),
    episodeGroupId: metadataString(json['episodeGroupId']),
    seasonCount: metadataInt(json['seasonCount']),
    episodeCount: metadataInt(json['episodeCount']),
    genres: _stringList(json['genres']),
    studios: _stringList(json['studios']),
    countries: _stringList(json['countries']),
    keywords: _stringList(json['keywords']),
    ids: _decodeIds(json['ids']),
    credits: _decodeCredits(json['credits']),
    images: _decodeImages(json['images']),
    seasons: _objects(json['seasons']).map(_decodeSeason).toList(),
    extras: _objects(json['extras']).map(_decodeExtra).nonNulls.toList(),
    rawPayload: null,
  );
}

// ─── lookup ──────────────────────────────────────────────────────────

Map<String, Object?> encodeVideoMetadataLookup(VideoMetadataLookup lookup) =>
    <String, Object?>{
      'provider': lookup.provider.name,
      'externalId': lookup.externalId,
      'mediaKind': lookup.mediaKind.name,
      'episodeGroupId': lookup.episodeGroupId,
    };

/// 不是对象、或 provider / externalId / mediaKind 任一缺失非法时返回 null。
VideoMetadataLookup? decodeVideoMetadataLookup(Object? json) {
  final Map<String, Object?>? map = metadataObject(json);
  if (map == null) return null;
  final VideoMetadataProviderKind? provider =
      _providerKind(metadataString(map['provider']));
  final String? externalId = metadataString(map['externalId']);
  final VideoMetadataMediaKind? mediaKind = VideoMetadataMediaKind.values
      .asNameMap()[metadataString(map['mediaKind']) ?? ''];
  if (provider == null || externalId == null || mediaKind == null) {
    return null;
  }
  return VideoMetadataLookup(
    provider: provider,
    externalId: externalId,
    mediaKind: mediaKind,
    episodeGroupId: metadataString(map['episodeGroupId']),
  );
}

// ─── 季 / 集 ─────────────────────────────────────────────────────────

Map<String, Object?> _encodeSeason(VideoMetadataSeason season) =>
    <String, Object?>{
      'seasonNumber': season.seasonNumber,
      'title': season.title,
      'plot': season.plot,
      'airDate': season.airDate,
      'year': season.year,
      'episodeCount': season.episodeCount,
      'rating': season.rating,
      'ids': season.ids.map(_encodeId).toList(),
      'images': season.images.map(_encodeImage).toList(),
      'episodes': season.episodes.map(_encodeEpisode).toList(),
    };

VideoMetadataSeason _decodeSeason(Map<String, Object?> json) =>
    VideoMetadataSeason(
      seasonNumber: metadataInt(json['seasonNumber']) ?? 0,
      title: metadataString(json['title']) ?? '',
      plot: metadataString(json['plot']),
      airDate: metadataString(json['airDate']),
      year: metadataInt(json['year']),
      episodeCount: metadataInt(json['episodeCount']),
      rating: metadataDouble(json['rating']),
      ids: _decodeIds(json['ids']),
      images: _decodeImages(json['images']),
      episodes: _objects(json['episodes']).map(_decodeEpisode).toList(),
    );

Map<String, Object?> _encodeEpisode(VideoMetadataEpisode episode) =>
    <String, Object?>{
      'seasonNumber': episode.seasonNumber,
      'episodeNumber': episode.episodeNumber,
      'title': episode.title,
      'plot': episode.plot,
      'airDate': episode.airDate,
      'year': episode.year,
      'absoluteNumber': episode.absoluteNumber,
      'rating': episode.rating,
      'ratingVotes': episode.ratingVotes,
      'runtimeMinutes': episode.runtimeMinutes,
      'ids': episode.ids.map(_encodeId).toList(),
      'credits': episode.credits.map(_encodeCredit).toList(),
      'images': episode.images.map(_encodeImage).toList(),
    };

VideoMetadataEpisode _decodeEpisode(Map<String, Object?> json) =>
    VideoMetadataEpisode(
      seasonNumber: metadataInt(json['seasonNumber']) ?? 0,
      episodeNumber: metadataInt(json['episodeNumber']) ?? 0,
      title: metadataString(json['title']) ?? '',
      plot: metadataString(json['plot']),
      airDate: metadataString(json['airDate']),
      year: metadataInt(json['year']),
      absoluteNumber: metadataInt(json['absoluteNumber']),
      rating: metadataDouble(json['rating']),
      ratingVotes: metadataInt(json['ratingVotes']),
      runtimeMinutes: metadataInt(json['runtimeMinutes']),
      ids: _decodeIds(json['ids']),
      credits: _decodeCredits(json['credits']),
      images: _decodeImages(json['images']),
    );

// ─── 身份 ────────────────────────────────────────────────────────────

Map<String, Object?> _encodeId(VideoMetadataId id) => <String, Object?>{
      'type': id.type,
      'value': id.value,
      'isDefault': id.isDefault,
    };

/// type / value 任一缺失的条目丢弃。
VideoMetadataId? _decodeId(Map<String, Object?> json) {
  final String? type = metadataString(json['type']);
  final String? value = metadataString(json['value']);
  if (type == null || value == null) return null;
  return VideoMetadataId(
    type: type,
    value: value,
    isDefault: metadataBool(json['isDefault']) ?? false,
  );
}

List<VideoMetadataId> _decodeIds(Object? json) =>
    _objects(json).map(_decodeId).nonNulls.toList();

// ─── 职员 / 人物 / 角色 ──────────────────────────────────────────────

Map<String, Object?> _encodeCredit(VideoMetadataCredit credit) =>
    <String, Object?>{
      'kind': credit.kind.name,
      'person': _encodePerson(credit.person),
      'character':
          credit.character == null ? null : _encodeCharacter(credit.character!),
      'language': credit.language,
      'roleName': credit.roleName,
      'department': credit.department,
      'job': credit.job,
      'providerCreditId': credit.providerCreditId,
      'order': credit.order,
    };

/// kind 非法或 person 缺失（人名都没有）的条目丢弃。
VideoMetadataCredit? _decodeCredit(Map<String, Object?> json) {
  final VideoMetadataCreditKind? kind = VideoMetadataCreditKind.values
      .asNameMap()[metadataString(json['kind']) ?? ''];
  final Map<String, Object?>? personJson = metadataObject(json['person']);
  if (kind == null || personJson == null) return null;
  final VideoMetadataPerson? person = _decodePerson(personJson);
  if (person == null) return null;
  final Map<String, Object?>? characterJson = metadataObject(json['character']);
  return VideoMetadataCredit(
    kind: kind,
    person: person,
    character: characterJson == null ? null : _decodeCharacter(characterJson),
    language: metadataString(json['language']),
    roleName: metadataString(json['roleName']),
    department: metadataString(json['department']),
    job: metadataString(json['job']),
    providerCreditId: metadataString(json['providerCreditId']),
    order: metadataInt(json['order']) ?? 0,
  );
}

List<VideoMetadataCredit> _decodeCredits(Object? json) =>
    _objects(json).map(_decodeCredit).nonNulls.toList();

Map<String, Object?> _encodePerson(VideoMetadataPerson person) =>
    <String, Object?>{
      'id': person.id,
      'name': person.name,
      'originalName': person.originalName,
      'biography': person.biography,
      'birthday': person.birthday,
      'deathday': person.deathday,
      'gender': person.gender,
      'placeOfBirth': person.placeOfBirth,
      'profileUrl': person.profileUrl,
      'ids': person.ids.map(_encodeId).toList(),
    };

VideoMetadataPerson? _decodePerson(Map<String, Object?> json) {
  final String? name = metadataString(json['name']);
  if (name == null) return null;
  return VideoMetadataPerson(
    id: metadataString(json['id']),
    name: name,
    originalName: metadataString(json['originalName']),
    biography: metadataString(json['biography']),
    birthday: metadataString(json['birthday']),
    deathday: metadataString(json['deathday']),
    gender: metadataInt(json['gender']),
    placeOfBirth: metadataString(json['placeOfBirth']),
    profileUrl: metadataString(json['profileUrl']),
    ids: _decodeIds(json['ids']),
  );
}

Map<String, Object?> _encodeCharacter(VideoMetadataCharacter character) =>
    <String, Object?>{
      'id': character.id,
      'name': character.name,
      'originalName': character.originalName,
      'description': character.description,
      'imageUrl': character.imageUrl,
      'ids': character.ids.map(_encodeId).toList(),
    };

VideoMetadataCharacter? _decodeCharacter(Map<String, Object?> json) {
  final String? name = metadataString(json['name']);
  if (name == null) return null;
  return VideoMetadataCharacter(
    id: metadataString(json['id']),
    name: name,
    originalName: metadataString(json['originalName']),
    description: metadataString(json['description']),
    imageUrl: metadataString(json['imageUrl']),
    ids: _decodeIds(json['ids']),
  );
}

// ─── 图片 ────────────────────────────────────────────────────────────

Map<String, Object?> _encodeImage(VideoMetadataImage image) =>
    <String, Object?>{
      'kind': image.kind.name,
      'url': image.url,
      'provider': image.provider.name,
      'language': image.language,
      'likes': image.likes,
      'voteAverage': image.voteAverage,
      'voteCount': image.voteCount,
      'seasonNumber': image.seasonNumber,
      'episodeNumber': image.episodeNumber,
    };

/// kind / provider 非法或 url 缺失的条目丢弃。
VideoMetadataImage? _decodeImage(Map<String, Object?> json) {
  final VideoMetadataImageKind? kind = VideoMetadataImageKind.values
      .asNameMap()[metadataString(json['kind']) ?? ''];
  final VideoMetadataProviderKind? provider =
      _providerKind(metadataString(json['provider']));
  final String? url = metadataString(json['url']);
  if (kind == null || provider == null || url == null) return null;
  return VideoMetadataImage(
    kind: kind,
    url: url,
    provider: provider,
    language: metadataString(json['language']),
    likes: metadataInt(json['likes']),
    voteAverage: metadataDouble(json['voteAverage']),
    voteCount: metadataInt(json['voteCount']),
    seasonNumber: metadataInt(json['seasonNumber']),
    episodeNumber: metadataInt(json['episodeNumber']),
  );
}

List<VideoMetadataImage> _decodeImages(Object? json) =>
    _objects(json).map(_decodeImage).nonNulls.toList();

// ─── 附件 ────────────────────────────────────────────────────────────

Map<String, Object?> _encodeExtra(VideoMetadataExtra extra) =>
    <String, Object?>{
      'kind': extra.kind.name,
      'title': extra.title,
      'provider': extra.provider?.name,
      'providerVideoId': extra.providerVideoId,
      'site': extra.site,
      'remoteUrl': extra.remoteUrl,
      'thumbnailUrl': extra.thumbnailUrl,
      'durationMs': extra.durationMs,
      'official': extra.official,
      'language': extra.language,
      'publishedAt': extra.publishedAt,
      'order': extra.order,
    };

/// kind 非法的条目丢弃；title 缺失按空串。
VideoMetadataExtra? _decodeExtra(Map<String, Object?> json) {
  final VideoMetadataExtraKind? kind = VideoMetadataExtraKind.values
      .asNameMap()[metadataString(json['kind']) ?? ''];
  if (kind == null) return null;
  return VideoMetadataExtra(
    kind: kind,
    title: metadataString(json['title']) ?? '',
    provider: _providerKind(metadataString(json['provider'])),
    providerVideoId: metadataString(json['providerVideoId']),
    site: metadataString(json['site']),
    remoteUrl: metadataString(json['remoteUrl']),
    thumbnailUrl: metadataString(json['thumbnailUrl']),
    durationMs: metadataInt(json['durationMs']),
    official: metadataBool(json['official']) ?? false,
    language: metadataString(json['language']),
    publishedAt: metadataString(json['publishedAt']),
    order: metadataInt(json['order']) ?? 0,
  );
}

// ─── 基础 helper ─────────────────────────────────────────────────────

VideoMetadataProviderKind? _providerKind(String? name) =>
    VideoMetadataProviderKind.values.asNameMap()[name ?? ''];

/// 只保留对象元素；非对象元素（null / 标量）丢弃。
Iterable<Map<String, Object?>> _objects(Object? json) =>
    metadataList(json).map(metadataObject).nonNulls;

/// 只保留非空字符串元素（去首尾空白）。
List<String> _stringList(Object? json) =>
    metadataList(json).map(metadataString).nonNulls.toList();
