/// 视频资料刮削、NFO 和持久化层之间共享的中立领域模型。
///
/// 这些类型不依赖数据库行或某个站点的响应结构。provider 负责把远端响应映射为
/// 本模型，数据库/NFO 层只消费确定的结构化字段；站点原始响应只允许放进
/// [VideoMetadataWork.rawPayload] 供诊断或将来重新映射。
library;

import 'package:collection/collection.dart';

/// 能作为作品主资料来源，或作为图片补充来源的站点。
enum VideoMetadataProviderKind { tmdb, douban, bangumi, anilist, fanart }

/// 作品的 Kodi/MoviePilot 媒体类型。
enum VideoMetadataMediaKind { movie, tv }

/// 人物在作品、季或分集中的职责。
enum VideoMetadataCreditKind {
  director,
  writer,
  actor,
  guest,
  voiceActor,
}

/// 可落为来源目录 sidecar 的图片种类。
enum VideoMetadataImageKind {
  cover,
  backdrop,
  logo,
  disc,
  banner,
  thumb,
  clearart,
  landscape,
}

/// 作品级视频附件种类。在线附件不进入 VideoBook；本地附件仍由 bookUid 指向原文件。
enum VideoMetadataExtraKind {
  trailer,
  teaser,
  clip,
  featurette,
  interview,
  behindTheScenes,
  deletedScene,
  short,
  scene,
  sample,
  extra,
}

/// 一个站点身份，例如 `tmdb=31911` 或 `imdb=tt1234567`。
class VideoMetadataId {
  const VideoMetadataId({
    required this.type,
    required this.value,
    this.isDefault = false,
  });

  final String type;
  final String value;
  final bool isDefault;

  VideoMetadataId copyWith({
    String? type,
    String? value,
    bool? isDefault,
  }) =>
      VideoMetadataId(
        type: type ?? this.type,
        value: value ?? this.value,
        isDefault: isDefault ?? this.isDefault,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataId &&
          type == other.type &&
          value == other.value &&
          isDefault == other.isDefault;

  @override
  int get hashCode => Object.hash(type, value, isDefault);
}

/// 远端人物的中立表示。
class VideoMetadataPerson {
  VideoMetadataPerson({
    this.id,
    required this.name,
    this.originalName,
    this.biography,
    this.birthday,
    this.deathday,
    this.gender,
    this.placeOfBirth,
    this.profileUrl,
    List<VideoMetadataId> ids = const <VideoMetadataId>[],
  }) : ids = List<VideoMetadataId>.unmodifiable(ids);

  final String? id;
  final String name;
  final String? originalName;
  final String? biography;
  final String? birthday;
  final String? deathday;
  final int? gender;
  final String? placeOfBirth;
  final String? profileUrl;
  final List<VideoMetadataId> ids;

  VideoMetadataPerson copyWith({
    String? id,
    String? name,
    String? originalName,
    String? biography,
    String? birthday,
    String? deathday,
    int? gender,
    String? placeOfBirth,
    String? profileUrl,
    List<VideoMetadataId>? ids,
  }) =>
      VideoMetadataPerson(
        id: id ?? this.id,
        name: name ?? this.name,
        originalName: originalName ?? this.originalName,
        biography: biography ?? this.biography,
        birthday: birthday ?? this.birthday,
        deathday: deathday ?? this.deathday,
        gender: gender ?? this.gender,
        placeOfBirth: placeOfBirth ?? this.placeOfBirth,
        profileUrl: profileUrl ?? this.profileUrl,
        ids: ids ?? this.ids,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataPerson &&
          id == other.id &&
          name == other.name &&
          originalName == other.originalName &&
          biography == other.biography &&
          birthday == other.birthday &&
          deathday == other.deathday &&
          gender == other.gender &&
          placeOfBirth == other.placeOfBirth &&
          profileUrl == other.profileUrl &&
          const ListEquality<VideoMetadataId>().equals(ids, other.ids);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        originalName,
        biography,
        birthday,
        deathday,
        gender,
        placeOfBirth,
        profileUrl,
        const ListEquality<VideoMetadataId>().hash(ids),
      );
}

/// 演员/声优所扮演的角色。
class VideoMetadataCharacter {
  VideoMetadataCharacter({
    this.id,
    required this.name,
    this.originalName,
    this.description,
    this.imageUrl,
    List<VideoMetadataId> ids = const <VideoMetadataId>[],
  }) : ids = List<VideoMetadataId>.unmodifiable(ids);

  final String? id;
  final String name;
  final String? originalName;
  final String? description;
  final String? imageUrl;
  final List<VideoMetadataId> ids;

  VideoMetadataCharacter copyWith({
    String? id,
    String? name,
    String? originalName,
    String? description,
    String? imageUrl,
    List<VideoMetadataId>? ids,
  }) =>
      VideoMetadataCharacter(
        id: id ?? this.id,
        name: name ?? this.name,
        originalName: originalName ?? this.originalName,
        description: description ?? this.description,
        imageUrl: imageUrl ?? this.imageUrl,
        ids: ids ?? this.ids,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataCharacter &&
          id == other.id &&
          name == other.name &&
          originalName == other.originalName &&
          description == other.description &&
          imageUrl == other.imageUrl &&
          const ListEquality<VideoMetadataId>().equals(ids, other.ids);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        originalName,
        description,
        imageUrl,
        const ListEquality<VideoMetadataId>().hash(ids),
      );
}

/// 一条作品/季/分集职员关系。
class VideoMetadataCredit {
  const VideoMetadataCredit({
    required this.kind,
    required this.person,
    this.character,
    this.language,
    this.roleName,
    this.department,
    this.job,
    this.providerCreditId,
    this.order = 0,
  });

  final VideoMetadataCreditKind kind;
  final VideoMetadataPerson person;
  final VideoMetadataCharacter? character;
  final String? language;
  final String? roleName;
  final String? department;
  final String? job;
  final String? providerCreditId;
  final int order;

  VideoMetadataCredit copyWith({
    VideoMetadataCreditKind? kind,
    VideoMetadataPerson? person,
    VideoMetadataCharacter? character,
    String? language,
    String? roleName,
    String? department,
    String? job,
    String? providerCreditId,
    int? order,
  }) =>
      VideoMetadataCredit(
        kind: kind ?? this.kind,
        person: person ?? this.person,
        character: character ?? this.character,
        language: language ?? this.language,
        roleName: roleName ?? this.roleName,
        department: department ?? this.department,
        job: job ?? this.job,
        providerCreditId: providerCreditId ?? this.providerCreditId,
        order: order ?? this.order,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataCredit &&
          kind == other.kind &&
          person == other.person &&
          character == other.character &&
          language == other.language &&
          roleName == other.roleName &&
          department == other.department &&
          job == other.job &&
          providerCreditId == other.providerCreditId &&
          order == other.order;

  @override
  int get hashCode => Object.hash(
        kind,
        person,
        character,
        language,
        roleName,
        department,
        job,
        providerCreditId,
        order,
      );
}

/// 一张候选图片。图片选择器可依据语言、热度及 TMDB 票数稳定排序。
class VideoMetadataImage {
  const VideoMetadataImage({
    required this.kind,
    required this.url,
    required this.provider,
    this.language,
    this.likes,
    this.voteAverage,
    this.voteCount,
    this.seasonNumber,
    this.episodeNumber,
  });

  final VideoMetadataImageKind kind;
  final String url;
  final VideoMetadataProviderKind provider;
  final String? language;
  final int? likes;
  final double? voteAverage;
  final int? voteCount;
  final int? seasonNumber;
  final int? episodeNumber;

  VideoMetadataImage copyWith({
    VideoMetadataImageKind? kind,
    String? url,
    VideoMetadataProviderKind? provider,
    String? language,
    int? likes,
    double? voteAverage,
    int? voteCount,
    int? seasonNumber,
    int? episodeNumber,
  }) =>
      VideoMetadataImage(
        kind: kind ?? this.kind,
        url: url ?? this.url,
        provider: provider ?? this.provider,
        language: language ?? this.language,
        likes: likes ?? this.likes,
        voteAverage: voteAverage ?? this.voteAverage,
        voteCount: voteCount ?? this.voteCount,
        seasonNumber: seasonNumber ?? this.seasonNumber,
        episodeNumber: episodeNumber ?? this.episodeNumber,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataImage &&
          kind == other.kind &&
          url == other.url &&
          provider == other.provider &&
          language == other.language &&
          likes == other.likes &&
          voteAverage == other.voteAverage &&
          voteCount == other.voteCount &&
          seasonNumber == other.seasonNumber &&
          episodeNumber == other.episodeNumber;

  @override
  int get hashCode => Object.hash(
        kind,
        url,
        provider,
        language,
        likes,
        voteAverage,
        voteCount,
        seasonNumber,
        episodeNumber,
      );
}

class VideoMetadataExtra {
  const VideoMetadataExtra({
    required this.kind,
    required this.title,
    this.provider,
    this.providerVideoId,
    this.site,
    this.remoteUrl,
    this.thumbnailUrl,
    this.durationMs,
    this.official = false,
    this.language,
    this.publishedAt,
    this.order = 0,
  });

  final VideoMetadataExtraKind kind;
  final String title;
  final VideoMetadataProviderKind? provider;
  final String? providerVideoId;
  final String? site;
  final String? remoteUrl;
  final String? thumbnailUrl;
  final int? durationMs;
  final bool official;
  final String? language;
  final String? publishedAt;
  final int order;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataExtra &&
          kind == other.kind &&
          title == other.title &&
          provider == other.provider &&
          providerVideoId == other.providerVideoId &&
          site == other.site &&
          remoteUrl == other.remoteUrl &&
          thumbnailUrl == other.thumbnailUrl &&
          durationMs == other.durationMs &&
          official == other.official &&
          language == other.language &&
          publishedAt == other.publishedAt &&
          order == other.order;

  @override
  int get hashCode => Object.hash(
        kind,
        title,
        provider,
        providerVideoId,
        site,
        remoteUrl,
        thumbnailUrl,
        durationMs,
        official,
        language,
        publishedAt,
        order,
      );
}

/// 一集的结构化资料。
class VideoMetadataEpisode {
  VideoMetadataEpisode({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.plot,
    this.airDate,
    this.year,
    this.absoluteNumber,
    this.rating,
    this.ratingVotes,
    this.runtimeMinutes,
    List<VideoMetadataId> ids = const <VideoMetadataId>[],
    List<VideoMetadataCredit> credits = const <VideoMetadataCredit>[],
    List<VideoMetadataImage> images = const <VideoMetadataImage>[],
  })  : ids = List<VideoMetadataId>.unmodifiable(ids),
        credits = List<VideoMetadataCredit>.unmodifiable(credits),
        images = List<VideoMetadataImage>.unmodifiable(images);

  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String? plot;
  final String? airDate;
  final int? year;
  final int? absoluteNumber;
  final double? rating;
  final int? ratingVotes;
  final int? runtimeMinutes;
  final List<VideoMetadataId> ids;
  final List<VideoMetadataCredit> credits;
  final List<VideoMetadataImage> images;

  VideoMetadataEpisode copyWith({
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? plot,
    String? airDate,
    int? year,
    int? absoluteNumber,
    double? rating,
    int? ratingVotes,
    int? runtimeMinutes,
    List<VideoMetadataId>? ids,
    List<VideoMetadataCredit>? credits,
    List<VideoMetadataImage>? images,
  }) =>
      VideoMetadataEpisode(
        seasonNumber: seasonNumber ?? this.seasonNumber,
        episodeNumber: episodeNumber ?? this.episodeNumber,
        title: title ?? this.title,
        plot: plot ?? this.plot,
        airDate: airDate ?? this.airDate,
        year: year ?? this.year,
        absoluteNumber: absoluteNumber ?? this.absoluteNumber,
        rating: rating ?? this.rating,
        ratingVotes: ratingVotes ?? this.ratingVotes,
        runtimeMinutes: runtimeMinutes ?? this.runtimeMinutes,
        ids: ids ?? this.ids,
        credits: credits ?? this.credits,
        images: images ?? this.images,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataEpisode &&
          seasonNumber == other.seasonNumber &&
          episodeNumber == other.episodeNumber &&
          title == other.title &&
          plot == other.plot &&
          airDate == other.airDate &&
          year == other.year &&
          absoluteNumber == other.absoluteNumber &&
          rating == other.rating &&
          ratingVotes == other.ratingVotes &&
          runtimeMinutes == other.runtimeMinutes &&
          const ListEquality<VideoMetadataId>().equals(ids, other.ids) &&
          const ListEquality<VideoMetadataCredit>()
              .equals(credits, other.credits) &&
          const ListEquality<VideoMetadataImage>().equals(images, other.images);

  @override
  int get hashCode => Object.hash(
        seasonNumber,
        episodeNumber,
        title,
        plot,
        airDate,
        year,
        absoluteNumber,
        rating,
        ratingVotes,
        runtimeMinutes,
        const ListEquality<VideoMetadataId>().hash(ids),
        const ListEquality<VideoMetadataCredit>().hash(credits),
        const ListEquality<VideoMetadataImage>().hash(images),
      );
}

/// 一季的结构化资料。
class VideoMetadataSeason {
  VideoMetadataSeason({
    required this.seasonNumber,
    required this.title,
    this.plot,
    this.airDate,
    this.year,
    this.episodeCount,
    this.rating,
    List<VideoMetadataId> ids = const <VideoMetadataId>[],
    List<VideoMetadataImage> images = const <VideoMetadataImage>[],
    List<VideoMetadataEpisode> episodes = const <VideoMetadataEpisode>[],
  })  : ids = List<VideoMetadataId>.unmodifiable(ids),
        images = List<VideoMetadataImage>.unmodifiable(images),
        episodes = List<VideoMetadataEpisode>.unmodifiable(episodes);

  final int seasonNumber;
  final String title;
  final String? plot;
  final String? airDate;
  final int? year;
  final int? episodeCount;
  final double? rating;
  final List<VideoMetadataId> ids;
  final List<VideoMetadataImage> images;
  final List<VideoMetadataEpisode> episodes;

  VideoMetadataSeason copyWith({
    int? seasonNumber,
    String? title,
    String? plot,
    String? airDate,
    int? year,
    int? episodeCount,
    double? rating,
    List<VideoMetadataId>? ids,
    List<VideoMetadataImage>? images,
    List<VideoMetadataEpisode>? episodes,
  }) =>
      VideoMetadataSeason(
        seasonNumber: seasonNumber ?? this.seasonNumber,
        title: title ?? this.title,
        plot: plot ?? this.plot,
        airDate: airDate ?? this.airDate,
        year: year ?? this.year,
        episodeCount: episodeCount ?? this.episodeCount,
        rating: rating ?? this.rating,
        ids: ids ?? this.ids,
        images: images ?? this.images,
        episodes: episodes ?? this.episodes,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataSeason &&
          seasonNumber == other.seasonNumber &&
          title == other.title &&
          plot == other.plot &&
          airDate == other.airDate &&
          year == other.year &&
          episodeCount == other.episodeCount &&
          rating == other.rating &&
          const ListEquality<VideoMetadataId>().equals(ids, other.ids) &&
          const ListEquality<VideoMetadataImage>()
              .equals(images, other.images) &&
          const ListEquality<VideoMetadataEpisode>()
              .equals(episodes, other.episodes);

  @override
  int get hashCode => Object.hash(
        seasonNumber,
        title,
        plot,
        airDate,
        year,
        episodeCount,
        rating,
        const ListEquality<VideoMetadataId>().hash(ids),
        const ListEquality<VideoMetadataImage>().hash(images),
        const ListEquality<VideoMetadataEpisode>().hash(episodes),
      );
}

/// 一部电影或电视剧作品的完整中立资料。
class VideoMetadataWork {
  VideoMetadataWork({
    required this.provider,
    required this.kind,
    required this.title,
    this.originalTitle,
    this.tagline,
    List<String> aliases = const <String>[],
    this.year,
    this.premiered,
    this.endDate,
    this.plot,
    this.rating,
    this.ratingVotes,
    this.runtimeMinutes,
    this.contentRating,
    this.status,
    this.originalLanguage,
    this.homepage,
    this.episodeGroupId,
    this.seasonCount,
    this.episodeCount,
    List<String> genres = const <String>[],
    List<String> studios = const <String>[],
    List<String> countries = const <String>[],
    List<String> keywords = const <String>[],
    List<VideoMetadataId> ids = const <VideoMetadataId>[],
    List<VideoMetadataCredit> credits = const <VideoMetadataCredit>[],
    List<VideoMetadataImage> images = const <VideoMetadataImage>[],
    List<VideoMetadataSeason> seasons = const <VideoMetadataSeason>[],
    List<VideoMetadataExtra> extras = const <VideoMetadataExtra>[],
    Map<String, Object?>? rawPayload,
  })  : aliases = List<String>.unmodifiable(aliases),
        genres = List<String>.unmodifiable(genres),
        studios = List<String>.unmodifiable(studios),
        countries = List<String>.unmodifiable(countries),
        keywords = List<String>.unmodifiable(keywords),
        ids = List<VideoMetadataId>.unmodifiable(ids),
        credits = List<VideoMetadataCredit>.unmodifiable(credits),
        images = List<VideoMetadataImage>.unmodifiable(images),
        seasons = List<VideoMetadataSeason>.unmodifiable(seasons),
        extras = List<VideoMetadataExtra>.unmodifiable(extras),
        rawPayload = _freezeMap(rawPayload);

  final VideoMetadataProviderKind provider;
  final VideoMetadataMediaKind kind;
  final String title;
  final String? originalTitle;
  final String? tagline;
  final List<String> aliases;
  final int? year;
  final String? premiered;
  final String? endDate;
  final String? plot;
  final double? rating;
  final int? ratingVotes;
  final int? runtimeMinutes;
  final String? contentRating;
  final String? status;
  final String? originalLanguage;
  final String? homepage;
  final String? episodeGroupId;
  final int? seasonCount;
  final int? episodeCount;
  final List<String> genres;
  final List<String> studios;
  final List<String> countries;
  final List<String> keywords;
  final List<VideoMetadataId> ids;
  final List<VideoMetadataCredit> credits;
  final List<VideoMetadataImage> images;
  final List<VideoMetadataSeason> seasons;
  final List<VideoMetadataExtra> extras;
  final Map<String, Object?>? rawPayload;

  VideoMetadataWork copyWith({
    VideoMetadataProviderKind? provider,
    VideoMetadataMediaKind? kind,
    String? title,
    String? originalTitle,
    String? tagline,
    List<String>? aliases,
    int? year,
    String? premiered,
    String? endDate,
    String? plot,
    double? rating,
    int? ratingVotes,
    int? runtimeMinutes,
    String? contentRating,
    String? status,
    String? originalLanguage,
    String? homepage,
    String? episodeGroupId,
    int? seasonCount,
    int? episodeCount,
    List<String>? genres,
    List<String>? studios,
    List<String>? countries,
    List<String>? keywords,
    List<VideoMetadataId>? ids,
    List<VideoMetadataCredit>? credits,
    List<VideoMetadataImage>? images,
    List<VideoMetadataSeason>? seasons,
    List<VideoMetadataExtra>? extras,
    Map<String, Object?>? rawPayload,
  }) =>
      VideoMetadataWork(
        provider: provider ?? this.provider,
        kind: kind ?? this.kind,
        title: title ?? this.title,
        originalTitle: originalTitle ?? this.originalTitle,
        tagline: tagline ?? this.tagline,
        aliases: aliases ?? this.aliases,
        year: year ?? this.year,
        premiered: premiered ?? this.premiered,
        endDate: endDate ?? this.endDate,
        plot: plot ?? this.plot,
        rating: rating ?? this.rating,
        ratingVotes: ratingVotes ?? this.ratingVotes,
        runtimeMinutes: runtimeMinutes ?? this.runtimeMinutes,
        contentRating: contentRating ?? this.contentRating,
        status: status ?? this.status,
        originalLanguage: originalLanguage ?? this.originalLanguage,
        homepage: homepage ?? this.homepage,
        episodeGroupId: episodeGroupId ?? this.episodeGroupId,
        seasonCount: seasonCount ?? this.seasonCount,
        episodeCount: episodeCount ?? this.episodeCount,
        genres: genres ?? this.genres,
        studios: studios ?? this.studios,
        countries: countries ?? this.countries,
        keywords: keywords ?? this.keywords,
        ids: ids ?? this.ids,
        credits: credits ?? this.credits,
        images: images ?? this.images,
        seasons: seasons ?? this.seasons,
        extras: extras ?? this.extras,
        rawPayload: rawPayload ?? this.rawPayload,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoMetadataWork &&
          provider == other.provider &&
          kind == other.kind &&
          title == other.title &&
          originalTitle == other.originalTitle &&
          tagline == other.tagline &&
          const ListEquality<String>().equals(aliases, other.aliases) &&
          year == other.year &&
          premiered == other.premiered &&
          endDate == other.endDate &&
          plot == other.plot &&
          rating == other.rating &&
          ratingVotes == other.ratingVotes &&
          runtimeMinutes == other.runtimeMinutes &&
          contentRating == other.contentRating &&
          status == other.status &&
          originalLanguage == other.originalLanguage &&
          homepage == other.homepage &&
          episodeGroupId == other.episodeGroupId &&
          seasonCount == other.seasonCount &&
          episodeCount == other.episodeCount &&
          const ListEquality<String>().equals(genres, other.genres) &&
          const ListEquality<String>().equals(studios, other.studios) &&
          const ListEquality<String>().equals(countries, other.countries) &&
          const ListEquality<String>().equals(keywords, other.keywords) &&
          const ListEquality<VideoMetadataId>().equals(ids, other.ids) &&
          const ListEquality<VideoMetadataCredit>()
              .equals(credits, other.credits) &&
          const ListEquality<VideoMetadataImage>()
              .equals(images, other.images) &&
          const ListEquality<VideoMetadataSeason>()
              .equals(seasons, other.seasons) &&
          const ListEquality<VideoMetadataExtra>()
              .equals(extras, other.extras) &&
          const DeepCollectionEquality().equals(rawPayload, other.rawPayload);

  @override
  int get hashCode => Object.hashAll(<Object?>[
        provider,
        kind,
        title,
        originalTitle,
        tagline,
        const ListEquality<String>().hash(aliases),
        year,
        premiered,
        endDate,
        plot,
        rating,
        ratingVotes,
        runtimeMinutes,
        contentRating,
        status,
        originalLanguage,
        homepage,
        episodeGroupId,
        seasonCount,
        episodeCount,
        const ListEquality<String>().hash(genres),
        const ListEquality<String>().hash(studios),
        const ListEquality<String>().hash(countries),
        const ListEquality<String>().hash(keywords),
        const ListEquality<VideoMetadataId>().hash(ids),
        const ListEquality<VideoMetadataCredit>().hash(credits),
        const ListEquality<VideoMetadataImage>().hash(images),
        const ListEquality<VideoMetadataSeason>().hash(seasons),
        const ListEquality<VideoMetadataExtra>().hash(extras),
        const DeepCollectionEquality().hash(rawPayload),
      ]);
}

Map<String, Object?>? _freezeMap(Map<String, Object?>? value) {
  if (value == null) {
    return null;
  }
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    for (final MapEntry<String, Object?> entry in value.entries)
      entry.key: _freezeJson(entry.value),
  });
}

Object? _freezeJson(Object? value) => switch (value) {
      Map<String, Object?> map => _freezeMap(map),
      List<Object?> list => List<Object?>.unmodifiable(list.map(_freezeJson)),
      _ => value,
    };
