import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase database;
  late VideoMetadataCreditRepository repository;

  setUp(() {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = VideoMetadataCreditRepository(database);
  });

  tearDown(() => database.close());

  test('按 collectionId 聚合作品、人物、角色与多站点身份', () async {
    final int collectionId = await database.createMediaCollection('Show');
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    await _insertPeopleAndCharacters(database);
    await database.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:tmdb',
          provider: 'tmdb',
          externalId: '100',
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
      ],
    );
    await database.replaceVideoMetadataProviderIdentities(
      personKey: 'person:voice',
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'person:voice:bangumi',
          provider: 'bangumi',
          externalId: '200',
          externalUrl: const Value<String?>('https://bgm.tv/person/200'),
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'person:voice:tmdb',
          provider: 'tmdb',
          externalId: '201',
          updatedAt: 1,
        ),
      ],
    );
    await database.replaceVideoMetadataProviderIdentities(
      characterKey: 'character:hero',
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'character:hero:bangumi',
          provider: 'bangumi',
          externalId: '300',
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
      ],
    );
    await database.replaceVideoMetadataCredits(
      workId: workId,
      credits: <VideoMetadataCreditsCompanion>[
        VideoMetadataCreditsCompanion.insert(
          personKey: 'person:director',
          creditKind: 'director',
          sortOrder: const Value<int>(0),
        ),
        VideoMetadataCreditsCompanion.insert(
          personKey: 'person:actor',
          characterKey: const Value<String?>('character:hero'),
          creditKind: 'actor',
          roleName: const Value<String>('Hero'),
          sortOrder: const Value<int>(1),
        ),
        VideoMetadataCreditsCompanion.insert(
          personKey: 'person:voice',
          characterKey: const Value<String?>('character:hero'),
          creditKind: 'voice_actor',
          roleName: const Value<String>('Hero'),
          language: const Value<String?>('ja'),
          sortOrder: const Value<int>(2),
        ),
      ],
    );

    final VideoMetadataWorkCredits result =
        (await repository.forCollection(collectionId))!;

    expect(result.workId, workId);
    expect(result.identities.single.provider, 'tmdb');
    expect(
      result.credits.map((VideoMetadataCreditSummary row) => row.creditKind),
      <String>['director', 'actor', 'voice_actor'],
    );
    final VideoMetadataCreditSummary voice = result.credits.last;
    expect(voice.person.name, 'Voice Actor');
    expect(voice.person.originalName, '声優');
    expect(voice.person.identities, hasLength(2));
    expect(voice.person.identities.first.provider, 'bangumi');
    expect(voice.character?.name, 'Hero');
    expect(voice.character?.identities.single.externalId, '300');
    expect(voice.displayName, 'Voice Actor · Hero');
    expect(voice.language, 'ja');
    expect(
      () => result.credits.add(voice),
      throwsUnsupportedError,
      reason: '详情页投影不得被展示层反向修改',
    );
  });

  test('按 bookUid 查询独立作品，无 v69 work 时返回 null', () async {
    await database.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('movie-1'),
        title: Value<String>('Movie'),
        videoPath: Value<String>('D:/Movies/Movie.mkv'),
      ),
    );
    await database.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
      VideoMetadataPeopleCompanion.insert(
        personKey: 'person:director',
        name: 'Director',
        updatedAt: 1,
      ),
    ]);
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('movie-1'),
        mediaType: 'movie',
        title: 'Movie',
        updatedAt: 1,
      ),
    );
    await database.replaceVideoMetadataCredits(
      workId: workId,
      credits: <VideoMetadataCreditsCompanion>[
        VideoMetadataCreditsCompanion.insert(
          personKey: 'person:director',
          creditKind: 'director',
        ),
      ],
    );

    final VideoMetadataWorkCredits result =
        (await repository.forBook('movie-1'))!;
    expect(result.credits.single.person.name, 'Director');
    expect(await repository.forBook('missing'), isNull);
    expect(await repository.forCollection(9999), isNull);
  });
}

Future<void> _insertPeopleAndCharacters(FushiDatabase database) async {
  await database.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
    VideoMetadataPeopleCompanion.insert(
      personKey: 'person:director',
      name: 'Director',
      updatedAt: 1,
    ),
    VideoMetadataPeopleCompanion.insert(
      personKey: 'person:actor',
      name: 'Actor',
      updatedAt: 1,
    ),
    VideoMetadataPeopleCompanion.insert(
      personKey: 'person:voice',
      name: 'Voice Actor',
      originalName: const Value<String?>('声優'),
      profileUrl: const Value<String?>('https://image.example/voice.jpg'),
      updatedAt: 1,
    ),
  ]);
  await database
      .upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
    VideoMetadataCharactersCompanion.insert(
      characterKey: 'character:hero',
      name: 'Hero',
      imageUrl: const Value<String?>('https://image.example/hero.jpg'),
      updatedAt: 1,
    ),
  ]);
}
