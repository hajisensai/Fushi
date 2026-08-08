/// v69 规范视频资料的 Drift 映射与旧详情页兼容投影。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_source_work_planner.dart';
import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

class PersistedVideoMetadata {
  const PersistedVideoMetadata({
    required this.workId,
    required this.seasonIds,
    required this.episodeIds,
    required this.episodesByBookUid,
  });

  final int workId;
  final Map<int, int> seasonIds;
  final Map<(int, int), int> episodeIds;
  final Map<String, VideoMetadataEpisode> episodesByBookUid;
}

class VideoMetadataDatabaseStore {
  const VideoMetadataDatabaseStore(this.database);

  final HibikiDatabase database;

  Future<VideoMetadataLookup?> confirmedLookup(
    VideoSourceScrapeWork localWork,
  ) async {
    final VideoMetadataWorkRow? row = localWork.collection == null
        ? await database
            .getVideoMetadataWorkByBook(localWork.members.single.bookUid)
        : await database
            .getVideoMetadataWorkByCollection(localWork.collection!.id);
    if (row == null) return null;
    final List<VideoMetadataProviderIdentityRow> identities =
        await database.getVideoMetadataProviderIdentities(workId: row.id);
    if (identities.isEmpty) return null;
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

  Future<PersistedVideoMetadata> apply(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata, {
    bool seasonEpisodesAuthoritative = true,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    late int workId;
    final Map<int, int> seasonIds = <int, int>{};
    final Map<(int, int), int> episodeIds = <(int, int), int>{};
    final Map<String, VideoMetadataEpisode> episodesByBookUid =
        <String, VideoMetadataEpisode>{};

    await database.transaction(() async {
      if (localWork.collection case final MediaCollectionRow collection) {
        await _removeBookOwnedWorksForCollection(collection.id);
      }
      workId = await database.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(localWork.collection?.id),
          bookUid: Value<String?>(localWork.collection == null
              ? localWork.members.single.bookUid
              : null),
          mediaType: metadata.kind.name,
          title: metadata.title,
          originalTitle: Value<String?>(metadata.originalTitle),
          overview: Value<String?>(metadata.plot),
          tagline: Value<String?>(metadata.tagline),
          premiereDate: Value<String?>(metadata.premiered),
          endDate: Value<String?>(metadata.endDate),
          year: Value<int?>(metadata.year),
          rating: Value<double?>(metadata.rating),
          ratingCount: Value<int?>(metadata.ratingVotes),
          runtimeMinutes: Value<int?>(metadata.runtimeMinutes),
          contentRating: Value<String?>(metadata.contentRating),
          status: Value<String?>(metadata.status),
          originalLanguage: Value<String?>(metadata.originalLanguage),
          homepage: Value<String?>(metadata.homepage),
          episodeGroupId: Value<String?>(metadata.episodeGroupId),
          updatedAt: now,
        ),
      );

      await _replaceIdentities(
        workId: workId,
        ids: metadata.ids,
        primaryProvider: metadata.provider,
        now: now,
      );
      await _replaceRawSnapshot(workId, metadata, now);
      await _replaceTerms(workId, metadata);
      await _replaceCredits(
          workId: workId, credits: metadata.credits, now: now);
      await _replaceImages(workId: workId, images: metadata.images, now: now);

      final Map<int, VideoMetadataSeasonRow> existingSeasons =
          <int, VideoMetadataSeasonRow>{
        for (final VideoMetadataSeasonRow row
            in await database.getVideoMetadataSeasons(workId))
          row.seasonNumber: row,
      };
      final List<VideoMetadataSeasonsCompanion> seasonRows =
          <VideoMetadataSeasonsCompanion>[
        for (final VideoMetadataSeason season in metadata.seasons)
          VideoMetadataSeasonsCompanion.insert(
            workId: workId,
            seasonNumber: season.seasonNumber,
            title: Value<String?>(season.title),
            overview: Value<String?>(
              season.plot ??
                  (!seasonEpisodesAuthoritative
                      ? existingSeasons[season.seasonNumber]?.overview
                      : null),
            ),
            premiereDate: Value<String?>(
              season.airDate ??
                  (!seasonEpisodesAuthoritative
                      ? existingSeasons[season.seasonNumber]?.premiereDate
                      : null),
            ),
            year: Value<int?>(
              season.year ??
                  (!seasonEpisodesAuthoritative
                      ? existingSeasons[season.seasonNumber]?.year
                      : null),
            ),
            episodeCount: Value<int?>(
              season.episodeCount ??
                  (!seasonEpisodesAuthoritative
                      ? existingSeasons[season.seasonNumber]?.episodeCount
                      : null),
            ),
            rating: Value<double?>(
              season.rating ??
                  (!seasonEpisodesAuthoritative
                      ? existingSeasons[season.seasonNumber]?.rating
                      : null),
            ),
            updatedAt: now,
          ),
      ];
      if (seasonEpisodesAuthoritative) {
        await database.replaceVideoMetadataSeasons(workId, seasonRows);
      } else {
        for (final VideoMetadataSeasonsCompanion season in seasonRows) {
          await database.upsertVideoMetadataSeason(season);
        }
      }
      for (final VideoMetadataSeasonRow row
          in await database.getVideoMetadataSeasons(workId)) {
        seasonIds[row.seasonNumber] = row.id;
      }

      final Map<(int, int), VideoBookRow> localEpisodeBooks =
          _localEpisodeBooks(localWork.members);
      await _clearReassignedEpisodeBooks(
        localEpisodeBooks: localEpisodeBooks,
        seasons: metadata.seasons,
      );
      for (final VideoMetadataSeason season in metadata.seasons) {
        final int? seasonId = seasonIds[season.seasonNumber];
        if (seasonId == null) continue;
        if (seasonEpisodesAuthoritative || season.ids.isNotEmpty) {
          await _replaceIdentities(
            seasonId: seasonId,
            ids: season.ids,
            primaryProvider: metadata.provider,
            now: now,
          );
        }
        if (seasonEpisodesAuthoritative || season.images.isNotEmpty) {
          await _replaceImages(
            seasonId: seasonId,
            images: season.images,
            now: now,
          );
        }
        final Map<int, VideoMetadataEpisodeRow> existingEpisodes =
            <int, VideoMetadataEpisodeRow>{
          for (final VideoMetadataEpisodeRow row
              in await database.getVideoMetadataEpisodes(seasonId))
            row.episodeNumber: row,
        };
        final List<VideoMetadataEpisodesCompanion> episodeRows =
            <VideoMetadataEpisodesCompanion>[
          for (final VideoMetadataEpisode episode in season.episodes)
            VideoMetadataEpisodesCompanion.insert(
              seasonId: seasonId,
              bookUid: Value<String?>(
                localEpisodeBooks[(
                      episode.seasonNumber,
                      episode.episodeNumber,
                    )]
                        ?.bookUid ??
                    existingEpisodes[episode.episodeNumber]?.bookUid,
              ),
              episodeNumber: episode.episodeNumber,
              absoluteNumber: Value<int?>(
                episode.absoluteNumber ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]
                            ?.absoluteNumber
                        : null),
              ),
              title: Value<String?>(episode.title),
              overview: Value<String?>(
                episode.plot ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]?.overview
                        : null),
              ),
              airDate: Value<String?>(
                episode.airDate ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]?.airDate
                        : null),
              ),
              year: Value<int?>(
                episode.year ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]?.year
                        : null),
              ),
              rating: Value<double?>(
                episode.rating ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]?.rating
                        : null),
              ),
              ratingCount: Value<int?>(
                episode.ratingVotes ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]?.ratingCount
                        : null),
              ),
              runtimeMinutes: Value<int?>(
                episode.runtimeMinutes ??
                    (!seasonEpisodesAuthoritative
                        ? existingEpisodes[episode.episodeNumber]
                            ?.runtimeMinutes
                        : null),
              ),
              updatedAt: now,
            ),
        ];
        if (seasonEpisodesAuthoritative) {
          await database.replaceVideoMetadataEpisodes(seasonId, episodeRows);
        } else {
          for (final VideoMetadataEpisodesCompanion episode in episodeRows) {
            await database.upsertVideoMetadataEpisode(episode);
          }
        }
        for (final VideoMetadataEpisodeRow row
            in await database.getVideoMetadataEpisodes(seasonId)) {
          episodeIds[(season.seasonNumber, row.episodeNumber)] = row.id;
        }
        for (final VideoMetadataEpisode episode in season.episodes) {
          final int? episodeId =
              episodeIds[(season.seasonNumber, episode.episodeNumber)];
          if (episodeId == null) continue;
          if (seasonEpisodesAuthoritative || episode.ids.isNotEmpty) {
            await _replaceIdentities(
              episodeId: episodeId,
              ids: episode.ids,
              primaryProvider: metadata.provider,
              now: now,
            );
          }
          if (seasonEpisodesAuthoritative || episode.credits.isNotEmpty) {
            await _replaceCredits(
              episodeId: episodeId,
              credits: episode.credits,
              now: now,
            );
          }
          if (seasonEpisodesAuthoritative || episode.images.isNotEmpty) {
            await _replaceImages(
              episodeId: episodeId,
              images: episode.images,
              now: now,
            );
          }
          final VideoBookRow? book =
              localEpisodeBooks[(episode.seasonNumber, episode.episodeNumber)];
          if (book != null) episodesByBookUid[book.bookUid] = episode;
        }
      }
      await _writeLegacyProjection(localWork, metadata, episodesByBookUid);
    });

    return PersistedVideoMetadata(
      workId: workId,
      seasonIds: Map<int, int>.unmodifiable(seasonIds),
      episodeIds: Map<(int, int), int>.unmodifiable(episodeIds),
      episodesByBookUid:
          Map<String, VideoMetadataEpisode>.unmodifiable(episodesByBookUid),
    );
  }

  Future<void> _removeBookOwnedWorksForCollection(int collectionId) async {
    final Set<String> memberBookUids =
        (await database.getCollectionItems(collectionId))
            .where((MediaCollectionItemRow row) => row.mediaType == 'video')
            .map((MediaCollectionItemRow row) => row.entryKey)
            .toSet();
    if (memberBookUids.isEmpty) return;
    await (database.delete(database.videoMetadataWorks)
          ..where((table) => table.bookUid.isIn(memberBookUids)))
        .go();
  }

  Future<void> _clearReassignedEpisodeBooks({
    required Map<(int, int), VideoBookRow> localEpisodeBooks,
    required Iterable<VideoMetadataSeason> seasons,
  }) async {
    final Set<String> reassignedBookUids = <String>{
      for (final VideoMetadataSeason season in seasons)
        for (final VideoMetadataEpisode episode in season.episodes)
          if (localEpisodeBooks[(
            episode.seasonNumber,
            episode.episodeNumber,
          )]
              case final VideoBookRow book)
            book.bookUid,
    };
    if (reassignedBookUids.isEmpty) return;
    await (database.update(database.videoMetadataEpisodes)
          ..where((table) => table.bookUid.isIn(reassignedBookUids)))
        .write(const VideoMetadataEpisodesCompanion(
      bookUid: Value<String?>(null),
    ));
  }

  Future<void> updateCanonicalImagePaths({
    required PersistedVideoMetadata persisted,
    required VideoMetadataWork metadata,
    required Map<String, String> localPathByRemoteUrl,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _replaceImages(
      workId: persisted.workId,
      images: metadata.images,
      now: now,
      localPathByRemoteUrl: localPathByRemoteUrl,
    );
    for (final VideoMetadataSeason season in metadata.seasons) {
      final int? seasonId = persisted.seasonIds[season.seasonNumber];
      if (seasonId == null) continue;
      await _replaceImages(
        seasonId: seasonId,
        images: season.images,
        now: now,
        localPathByRemoteUrl: localPathByRemoteUrl,
      );
      for (final VideoMetadataEpisode episode in season.episodes) {
        final int? episodeId =
            persisted.episodeIds[(episode.seasonNumber, episode.episodeNumber)];
        if (episodeId == null) continue;
        await _replaceImages(
          episodeId: episodeId,
          images: episode.images,
          now: now,
          localPathByRemoteUrl: localPathByRemoteUrl,
        );
      }
    }
  }

  Future<void> _replaceIdentities({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataId> ids,
    required VideoMetadataProviderKind primaryProvider,
    required int now,
  }) async {
    final String owner = workId != null
        ? 'work:$workId'
        : seasonId != null
            ? 'season:$seasonId'
            : 'episode:$episodeId';
    await database.replaceVideoMetadataProviderIdentities(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        for (final VideoMetadataId id in _uniqueIds(ids))
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: '$owner:${id.type.toLowerCase()}',
            workId: Value<int?>(workId),
            seasonId: Value<int?>(seasonId),
            episodeId: Value<int?>(episodeId),
            provider: id.type.toLowerCase(),
            externalId: id.value,
            isPrimary: Value<bool>(
              id.type.trim().toLowerCase() == primaryProvider.name,
            ),
            updatedAt: now,
          ),
      ],
    );
  }

  Future<void> _replaceRawSnapshot(
    int workId,
    VideoMetadataWork metadata,
    int now,
  ) async {
    final Map<String, Object?>? payload = metadata.rawPayload;
    if (payload == null) return;
    final List<VideoMetadataProviderIdentityRow> identities =
        await database.getVideoMetadataProviderIdentities(workId: workId);
    final VideoMetadataProviderIdentityRow? primary = identities
        .where((VideoMetadataProviderIdentityRow row) =>
            row.provider == metadata.provider.name)
        .firstOrNull;
    if (primary == null) return;
    await database.replaceVideoMetadataRawSnapshots(
      primary.identityKey,
      <VideoMetadataRawSnapshotsCompanion>[
        VideoMetadataRawSnapshotsCompanion.insert(
          identityKey: primary.identityKey,
          snapshotKind: 'details',
          rawJson: jsonEncode(payload),
          fetchedAt: now,
        ),
      ],
    );
  }

  Future<void> _replaceTerms(int workId, VideoMetadataWork metadata) async {
    final List<(String, String)> values = <(String, String)>[
      for (final String value in metadata.genres) ('genre', value),
      for (final String value in metadata.studios) ('studio', value),
      for (final String value in metadata.countries) ('country', value),
      for (final String value in metadata.keywords) ('keyword', value),
    ];
    final List<VideoMetadataTermsCompanion> terms =
        <VideoMetadataTermsCompanion>[];
    final List<VideoMetadataWorkTermsCompanion> mappings =
        <VideoMetadataWorkTermsCompanion>[];
    final Set<String> seen = <String>{};
    for (final (String kind, String name) in values) {
      final String normalized = TitleNormalizer.normalize(name);
      if (normalized.isEmpty || !seen.add('$kind:$normalized')) continue;
      final String key = '$kind:${_digest(normalized)}';
      terms.add(VideoMetadataTermsCompanion.insert(
        termKey: key,
        kind: kind,
        name: name,
        normalizedName: normalized,
      ));
      mappings.add(VideoMetadataWorkTermsCompanion.insert(
        workId: workId,
        termKey: key,
        sortOrder: Value<int>(mappings.length),
      ));
    }
    await database.replaceVideoMetadataTermsForWork(
      workId: workId,
      terms: terms,
      mappings: mappings,
    );
  }

  Future<void> _replaceCredits({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataCredit> credits,
    required int now,
  }) async {
    final List<VideoMetadataPeopleCompanion> people =
        <VideoMetadataPeopleCompanion>[];
    final List<VideoMetadataCharactersCompanion> characters =
        <VideoMetadataCharactersCompanion>[];
    final List<VideoMetadataCreditsCompanion> rows =
        <VideoMetadataCreditsCompanion>[];
    final Set<String> seenCredits = <String>{};
    for (final VideoMetadataCredit credit in credits) {
      final String personKey = _personKey(credit.person);
      final String creditKey = <String>[
        personKey,
        credit.kind.name,
        credit.roleName ?? credit.character?.name ?? '',
      ].join('\u0000');
      if (!seenCredits.add(creditKey)) continue;
      people.add(VideoMetadataPeopleCompanion.insert(
        personKey: personKey,
        name: credit.person.name,
        originalName: Value<String?>(credit.person.originalName),
        biography: Value<String?>(credit.person.biography),
        birthday: Value<String?>(credit.person.birthday),
        deathday: Value<String?>(credit.person.deathday),
        gender: Value<int?>(credit.person.gender),
        placeOfBirth: Value<String?>(credit.person.placeOfBirth),
        profileUrl: Value<String?>(credit.person.profileUrl),
        updatedAt: now,
      ));
      String? characterKey;
      if (credit.character case final VideoMetadataCharacter character) {
        characterKey = _characterKey(character);
        characters.add(VideoMetadataCharactersCompanion.insert(
          characterKey: characterKey,
          name: character.name,
          description: Value<String?>(character.description),
          imageUrl: Value<String?>(character.imageUrl),
          updatedAt: now,
        ));
      }
      rows.add(VideoMetadataCreditsCompanion.insert(
        workId: Value<int?>(workId),
        seasonId: Value<int?>(seasonId),
        episodeId: Value<int?>(episodeId),
        personKey: personKey,
        characterKey: Value<String?>(characterKey),
        creditKind: _creditKind(credit.kind),
        roleName:
            Value<String>(credit.roleName ?? credit.character?.name ?? ''),
        department: Value<String?>(credit.department),
        job: Value<String?>(credit.job),
        language: Value<String?>(credit.language),
        providerCreditId: Value<String?>(credit.providerCreditId),
        sortOrder: Value<int>(credit.order),
      ));
    }
    await database.upsertVideoMetadataPeople(people);
    await database.upsertVideoMetadataCharacters(characters);
    await database.replaceVideoMetadataCredits(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      credits: rows,
    );
    for (final VideoMetadataCredit credit in credits) {
      await _mergeEntityIdentities(
        personKey: _personKey(credit.person),
        ids: credit.person.ids,
        now: now,
      );
      if (credit.character case final VideoMetadataCharacter character) {
        await _mergeEntityIdentities(
          characterKey: _characterKey(character),
          ids: character.ids,
          now: now,
        );
      }
    }
  }

  Future<void> _mergeEntityIdentities({
    String? personKey,
    String? characterKey,
    required List<VideoMetadataId> ids,
    required int now,
  }) async {
    if (ids.isEmpty) return;
    final List<VideoMetadataProviderIdentityRow> existing =
        await database.getVideoMetadataProviderIdentities(
      personKey: personKey,
      characterKey: characterKey,
    );
    final Map<String, VideoMetadataId> merged = <String, VideoMetadataId>{
      for (final VideoMetadataProviderIdentityRow row in existing)
        row.provider: VideoMetadataId(
          type: row.provider,
          value: row.externalId,
          isDefault: row.isPrimary,
        ),
      for (final VideoMetadataId id in ids) id.type.toLowerCase(): id,
    };
    final String owner =
        personKey == null ? 'character:$characterKey' : 'person:$personKey';
    await database.replaceVideoMetadataProviderIdentities(
      personKey: personKey,
      characterKey: characterKey,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        for (final VideoMetadataId id in merged.values)
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: '$owner:${id.type.toLowerCase()}',
            personKey: Value<String?>(personKey),
            characterKey: Value<String?>(characterKey),
            provider: id.type.toLowerCase(),
            externalId: id.value,
            isPrimary: Value<bool>(id.isDefault),
            updatedAt: now,
          ),
      ],
    );
  }

  Future<void> _replaceImages({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataImage> images,
    required int now,
    Map<String, String> localPathByRemoteUrl = const <String, String>{},
  }) async {
    final List<VideoMetadataImageRow> existing =
        await database.getVideoMetadataImages(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
    );
    final Map<(String, String, String), String> existingLocalPaths =
        <(String, String, String), String>{
      for (final VideoMetadataImageRow row in existing)
        if (row.localPath case final String localPath when localPath.isNotEmpty)
          (row.provider, row.kind, row.remoteUrl): localPath,
    };
    final Map<VideoMetadataImageKind, int> positions =
        <VideoMetadataImageKind, int>{};
    final List<VideoMetadataImagesCompanion> rows =
        <VideoMetadataImagesCompanion>[];
    for (final VideoMetadataImage image in images) {
      final int position = positions.update(
        image.kind,
        (int value) => value + 1,
        ifAbsent: () => 0,
      );
      rows.add(VideoMetadataImagesCompanion.insert(
        workId: Value<int?>(workId),
        seasonId: Value<int?>(seasonId),
        episodeId: Value<int?>(episodeId),
        provider: image.provider.name,
        kind: image.kind.name,
        position: Value<int>(position),
        language: Value<String?>(image.language),
        remoteUrl: image.url,
        localPath: Value<String?>(
          localPathByRemoteUrl[image.url] ??
              existingLocalPaths[(
                image.provider.name,
                image.kind.name,
                image.url,
              )],
        ),
        rating: Value<double?>(image.voteAverage),
        voteCount: Value<int?>(image.voteCount),
        updatedAt: now,
      ));
    }
    await database.replaceVideoMetadataImages(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      images: rows,
    );
  }

  Future<void> _writeLegacyProjection(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata,
    Map<String, VideoMetadataEpisode> episodeByBook,
  ) async {
    final String subjectId = _primaryId(metadata)?.value ?? metadata.title;
    final String source = metadata.provider.name;
    final String? tags = metadata.genres.isEmpty && metadata.keywords.isEmpty
        ? null
        : jsonEncode(<Map<String, Object?>>[
            for (final String value in <String>{
              ...metadata.genres,
              ...metadata.keywords,
            })
              <String, Object?>{'name': value},
          ]);
    final String? infobox = _legacyInfobox(metadata);
    final DateTime scrapedAt = DateTime.now();
    if (localWork.collection case final MediaCollectionRow collection) {
      await database.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(collection.id),
          source: source,
          subjectId: subjectId,
          title: metadata.title,
          originalTitle: Value<String?>(metadata.originalTitle),
          summary: Value<String?>(metadata.plot),
          airDate: Value<String?>(metadata.premiered),
          rating: Value<double?>(metadata.rating),
          ratingCount: Value<int?>(metadata.ratingVotes),
          episodeCount: Value<int?>(metadata.episodeCount),
          tagsJson: Value<String?>(tags),
          infoboxJson: Value<String?>(infobox),
          backdropPath: const Value<String?>(null),
          detailUrl: Value<String?>(_detailUrl(metadata)),
          scrapedAt: scrapedAt,
        ),
      );
      for (final VideoBookRow book in localWork.members) {
        final VideoMetadataEpisode? episode = episodeByBook[book.bookUid];
        if (episode == null) continue;
        await database.upsertVideoScrapeMeta(
          VideoScrapeMetaCompanion.insert(
            bookUid: book.bookUid,
            source: source,
            subjectId: _primaryIdFrom(
                  episode.ids,
                  preferred: metadata.provider.name,
                )?.value ??
                subjectId,
            title: episode.title,
            summary: Value<String?>(episode.plot),
            airDate: Value<String?>(episode.airDate),
            rating: Value<double?>(episode.rating),
            episodeNumber: Value<int?>(episode.episodeNumber),
            detailUrl: Value<String?>(_detailUrl(metadata)),
            scrapedAt: scrapedAt,
          ),
        );
      }
    } else {
      await database.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: localWork.members.single.bookUid,
          source: source,
          subjectId: subjectId,
          title: metadata.title,
          originalTitle: Value<String?>(metadata.originalTitle),
          summary: Value<String?>(metadata.plot),
          airDate: Value<String?>(metadata.premiered),
          rating: Value<double?>(metadata.rating),
          ratingCount: Value<int?>(metadata.ratingVotes),
          episodeCount: Value<int?>(metadata.episodeCount),
          tagsJson: Value<String?>(tags),
          infoboxJson: Value<String?>(infobox),
          detailUrl: Value<String?>(_detailUrl(metadata)),
          scrapedAt: scrapedAt,
        ),
      );
    }
  }

  static Map<(int, int), VideoBookRow> _localEpisodeBooks(
    Iterable<VideoBookRow> books,
  ) {
    final Map<(int, int), VideoBookRow> result = <(int, int), VideoBookRow>{};
    for (final VideoBookRow book in books) {
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(book.videoPath));
      final int? episode = parsed.episode;
      if (episode == null) continue;
      result.putIfAbsent((parsed.season ?? 1, episode), () => book);
    }
    return result;
  }

  static List<VideoMetadataId> _uniqueIds(Iterable<VideoMetadataId> ids) {
    final Map<String, VideoMetadataId> result = <String, VideoMetadataId>{};
    for (final VideoMetadataId id in ids) {
      final String type = id.type.trim().toLowerCase();
      final String value = id.value.trim();
      if (type.isNotEmpty && value.isNotEmpty) {
        result[type] = id.copyWith(type: type, value: value);
      }
    }
    return result.values.toList();
  }

  static String _creditKind(VideoMetadataCreditKind kind) => switch (kind) {
        VideoMetadataCreditKind.voiceActor => 'voice_actor',
        _ => kind.name,
      };

  static String _personKey(VideoMetadataPerson person) {
    final VideoMetadataId? id = _primaryIdFrom(person.ids);
    return id == null
        ? 'person:name:${_digest(TitleNormalizer.normalize(person.name))}'
        : 'person:${id.type.toLowerCase()}:${id.value}';
  }

  static String _characterKey(VideoMetadataCharacter character) {
    final VideoMetadataId? id = _primaryIdFrom(character.ids);
    return id == null
        ? 'character:name:${_digest(TitleNormalizer.normalize(character.name))}'
        : 'character:${id.type.toLowerCase()}:${id.value}';
  }

  static VideoMetadataId? _primaryId(VideoMetadataWork work) =>
      _primaryIdFrom(work.ids, preferred: work.provider.name);

  static VideoMetadataId? _primaryIdFrom(
    Iterable<VideoMetadataId> ids, {
    String? preferred,
  }) {
    final List<VideoMetadataId> values = ids.toList();
    if (preferred != null) {
      final String normalizedPreferred = preferred.trim().toLowerCase();
      for (final VideoMetadataId id in values) {
        if (id.type.trim().toLowerCase() == normalizedPreferred) return id;
      }
    }
    for (final VideoMetadataId id in values) {
      if (id.isDefault) return id;
    }
    return values.firstOrNull;
  }

  static String? _detailUrl(VideoMetadataWork work) {
    final VideoMetadataId? id = _primaryId(work);
    if (id == null) return null;
    return switch (work.provider) {
      VideoMetadataProviderKind.tmdb =>
        'https://www.themoviedb.org/${work.kind.name}/${id.value}',
      VideoMetadataProviderKind.bangumi => 'https://bgm.tv/subject/${id.value}',
      VideoMetadataProviderKind.anilist =>
        'https://anilist.co/anime/${id.value}',
      VideoMetadataProviderKind.douban =>
        'https://movie.douban.com/subject/${id.value}/',
      VideoMetadataProviderKind.fanart => null,
    };
  }

  static String? _legacyInfobox(VideoMetadataWork work) {
    final List<Map<String, String>> values = <Map<String, String>>[
      if (work.studios.isNotEmpty)
        <String, String>{'key': 'Studio', 'value': work.studios.join(' / ')},
      if (work.countries.isNotEmpty)
        <String, String>{'key': 'Country', 'value': work.countries.join(' / ')},
      if (work.runtimeMinutes != null)
        <String, String>{
          'key': 'Runtime',
          'value': '${work.runtimeMinutes} min',
        },
      if (work.contentRating != null)
        <String, String>{'key': 'Certification', 'value': work.contentRating!},
    ];
    return values.isEmpty ? null : jsonEncode(values);
  }

  static String _digest(String value) =>
      sha1.convert(utf8.encode(value)).toString();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
