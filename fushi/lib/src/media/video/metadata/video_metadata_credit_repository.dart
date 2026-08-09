/// v77 视频作品人物关系的只读查询投影。
library;

import 'package:fushi_core/fushi_core.dart';

class VideoMetadataIdentitySummary {
  const VideoMetadataIdentitySummary({
    required this.provider,
    required this.externalId,
    required this.isPrimary,
    this.externalUrl,
  });

  final String provider;
  final String externalId;
  final String? externalUrl;
  final bool isPrimary;
}

class VideoMetadataPersonSummary {
  VideoMetadataPersonSummary({
    required this.personKey,
    required this.name,
    required List<VideoMetadataIdentitySummary> identities,
    this.originalName,
    this.biography,
    this.profileUrl,
    this.profilePath,
  }) : identities = List<VideoMetadataIdentitySummary>.unmodifiable(
          identities,
        );

  final String personKey;
  final String name;
  final String? originalName;
  final String? biography;
  final String? profileUrl;
  final String? profilePath;
  final List<VideoMetadataIdentitySummary> identities;
}

class VideoMetadataCharacterSummary {
  VideoMetadataCharacterSummary({
    required this.characterKey,
    required this.name,
    required List<VideoMetadataIdentitySummary> identities,
    this.description,
    this.imageUrl,
    this.imagePath,
  }) : identities = List<VideoMetadataIdentitySummary>.unmodifiable(
          identities,
        );

  final String characterKey;
  final String name;
  final String? description;
  final String? imageUrl;
  final String? imagePath;
  final List<VideoMetadataIdentitySummary> identities;
}

class VideoMetadataCreditSummary {
  const VideoMetadataCreditSummary({
    required this.creditKind,
    required this.person,
    required this.roleName,
    required this.sortOrder,
    this.character,
    this.department,
    this.job,
    this.language,
  });

  final String creditKind;
  final VideoMetadataPersonSummary person;
  final VideoMetadataCharacterSummary? character;
  final String roleName;
  final String? department;
  final String? job;
  final String? language;
  final int sortOrder;

  String get displayName {
    final String role = character?.name.trim().isNotEmpty == true
        ? character!.name.trim()
        : roleName.trim();
    return role.isEmpty ? person.name : '${person.name} · $role';
  }
}

class VideoMetadataWorkCredits {
  VideoMetadataWorkCredits({
    required this.workId,
    required List<VideoMetadataIdentitySummary> identities,
    required List<VideoMetadataCreditSummary> credits,
  })  : identities = List<VideoMetadataIdentitySummary>.unmodifiable(
          identities,
        ),
        credits = List<VideoMetadataCreditSummary>.unmodifiable(credits);

  final int workId;
  final List<VideoMetadataIdentitySummary> identities;
  final List<VideoMetadataCreditSummary> credits;
}

class VideoMetadataCreditRepository {
  const VideoMetadataCreditRepository(this._database);

  final FushiDatabase _database;

  Future<VideoMetadataWorkCredits?> forCollection(int collectionId) async {
    final VideoMetadataWorkRow? work =
        await _database.getVideoMetadataWorkByCollection(collectionId);
    return work == null ? null : _readWork(work.id);
  }

  Future<VideoMetadataWorkCredits?> forBook(String bookUid) async {
    final VideoMetadataWorkRow? work =
        await _database.getVideoMetadataWorkByBook(bookUid);
    return work == null ? null : _readWork(work.id);
  }

  Future<VideoMetadataWorkCredits> _readWork(int workId) async {
    final List<VideoMetadataCreditRow> rows =
        await _database.getVideoMetadataCredits(workId: workId);
    final Set<String> personKeys = <String>{
      for (final VideoMetadataCreditRow row in rows) row.personKey,
    };
    final Set<String> characterKeys = <String>{
      for (final VideoMetadataCreditRow row in rows)
        if (row.characterKey != null) row.characterKey!,
    };
    final List<VideoMetadataPersonSummary?> people = await Future.wait(
      personKeys.map(_readPerson),
    );
    final List<VideoMetadataCharacterSummary?> characters = await Future.wait(
      characterKeys.map(_readCharacter),
    );
    final Map<String, VideoMetadataPersonSummary> peopleByKey =
        <String, VideoMetadataPersonSummary>{
      for (final VideoMetadataPersonSummary? person in people)
        if (person != null) person.personKey: person,
    };
    final Map<String, VideoMetadataCharacterSummary> charactersByKey =
        <String, VideoMetadataCharacterSummary>{
      for (final VideoMetadataCharacterSummary? character in characters)
        if (character != null) character.characterKey: character,
    };
    return VideoMetadataWorkCredits(
      workId: workId,
      identities: _identities(
        await _database.getVideoMetadataProviderIdentities(workId: workId),
      ),
      credits: <VideoMetadataCreditSummary>[
        for (final VideoMetadataCreditRow row in rows)
          if (peopleByKey[row.personKey]
              case final VideoMetadataPersonSummary person)
            VideoMetadataCreditSummary(
              creditKind: row.creditKind,
              person: person,
              character: row.characterKey == null
                  ? null
                  : charactersByKey[row.characterKey],
              roleName: row.roleName,
              department: row.department,
              job: row.job,
              language: row.language,
              sortOrder: row.sortOrder,
            ),
      ],
    );
  }

  Future<VideoMetadataPersonSummary?> _readPerson(String personKey) async {
    final VideoMetadataPersonRow? row =
        await _database.getVideoMetadataPerson(personKey);
    if (row == null) return null;
    return VideoMetadataPersonSummary(
      personKey: row.personKey,
      name: row.name,
      originalName: row.originalName,
      biography: row.biography,
      profileUrl: row.profileUrl,
      profilePath: row.profilePath,
      identities: _identities(
        await _database.getVideoMetadataProviderIdentities(
          personKey: personKey,
        ),
      ),
    );
  }

  Future<VideoMetadataCharacterSummary?> _readCharacter(
    String characterKey,
  ) async {
    final VideoMetadataCharacterRow? row =
        await _database.getVideoMetadataCharacter(characterKey);
    if (row == null) return null;
    return VideoMetadataCharacterSummary(
      characterKey: row.characterKey,
      name: row.name,
      description: row.description,
      imageUrl: row.imageUrl,
      imagePath: row.imagePath,
      identities: _identities(
        await _database.getVideoMetadataProviderIdentities(
          characterKey: characterKey,
        ),
      ),
    );
  }

  static List<VideoMetadataIdentitySummary> _identities(
    Iterable<VideoMetadataProviderIdentityRow> rows,
  ) =>
      <VideoMetadataIdentitySummary>[
        for (final VideoMetadataProviderIdentityRow row in rows)
          VideoMetadataIdentitySummary(
            provider: row.provider,
            externalId: row.externalId,
            externalUrl: row.externalUrl,
            isPrimary: row.isPrimary,
          ),
      ];
}
