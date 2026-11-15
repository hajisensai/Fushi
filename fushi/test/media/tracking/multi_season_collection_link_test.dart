// T1 finding F1: one link for a video collection that holds more than one
// season was saved and then never sent anything, silently.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

final class _Site implements TrackingProvider {
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => RemoteAnimeIdType.anilist;

  @override
  String get displayName => 'Site';

  @override
  String get siteHost => '';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.anime},
        progressModes: <TrackingProgressMode>{TrackingProgressMode.episode},
      );

  @override
  bool get isConfigured => true;

  @override
  Future<TrackingProviderSession> openSession() async => _Session();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async => pushed.add(update);

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late _Site site;
  late MediaTrackingService service;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    repository = MediaTrackingRepository(db);
    site = _Site();
    service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test',
      extraProviders: <TrackingProvider>[site],
    );
  });

  tearDown(() async {
    service.dispose();
    prefs.dispose();
    await db.close();
  });

  /// A playlist of [titles] (file names); the first one marked watched.
  Future<int> seedCollection(String name, List<String> titles) async {
    for (int i = 0; i < titles.length; i++) {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: '$name-$i',
          title: titles[i],
          videoPath: 'C:/anime/${titles[i]}.mkv',
          completedAt: Value<DateTime?>(i == 0 ? DateTime(2026, 11) : null),
        ),
      );
    }
    final int id = await db.createMediaCollection(
      name,
      collectionType: 'playlist',
    );
    for (int i = 0; i < titles.length; i++) {
      await db.addToCollection(id, MediaKind.video, '$name-$i');
    }
    return id;
  }

  Future<int> seedTwoSeasons() => seedCollection('Ramparts', <String>[
    'The Ramparts of Ice S01E01',
    'The Ramparts of Ice S01E02',
    'The Ramparts of Ice S02E01',
  ]);

  Future<void> saveCollectionLink(int id) => repository.saveMapping(
    mediaType: TrackingMediaType.videoCollection,
    mediaKey: '$id',
    mediaTitle: 'collection $id',
    kind: TrackingKind.anime,
    subjectId: 186497,
    subjectName: 'Koori no Jouheki',
    progressMode: TrackingProgressMode.episode,
    progressOffset: 1,
    provider: site.id,
  );

  test('"Needs attention" says a multi-season collection cannot get one '
      'link; a one-season collection is a plain unlinked row', () async {
    final int two = await seedTwoSeasons();
    final int one = await seedCollection('Frieren', <String>[
      'Frieren S01E01',
      'Frieren S01E02',
    ]);
    final Map<String, MediaTrackingUnlinkedItem> rows =
        <String, MediaTrackingUnlinkedItem>{
          for (final MediaTrackingUnlinkedItem item
              in await repository.listUnlinkedHistory())
            item.mediaKey: item,
        };
    expect(rows['$two']?.multiSeason, isTrue);
    expect(rows['$one']?.multiSeason, isFalse);
  });

  test('saving one link for a multi-season collection is refused and '
      'nothing is stored', () async {
    final int id = await seedTwoSeasons();
    await expectLater(
      service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '$id',
        mediaTitle: 'Ramparts',
        kind: TrackingKind.anime,
        subjectId: 186497,
        subjectName: 'Koori no Jouheki',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 1,
        provider: site.id,
      ),
      throwsA(isA<MultiSeasonCollectionLinkError>()),
    );
    expect(await repository.listMappings(), isEmpty);
  });

  test('an existing multi-season collection link is listed under "Needs '
      'attention" as a link that never sends', () async {
    final int two = await seedTwoSeasons();
    final int one = await seedCollection('Frieren', <String>[
      'Frieren S01E01',
      'Frieren S01E02',
    ]);
    await saveCollectionLink(two);
    await saveCollectionLink(one);

    final MediaTrackingHomeSnapshot snapshot = await service.loadHomeSnapshot();
    final MediaTrackingMappingRow dead = snapshot.mappings.singleWhere(
      (MediaTrackingMappingRow row) => row.mediaKey == '$two',
    );
    expect(snapshot.inertMappingIds, <int>{dead.id});

    final List<TrackingAttentionEntry> inert = <TrackingAttentionEntry>[
      for (final TrackingAttentionEntry entry in TrackingPageData.of(
        snapshot,
      ).attention)
        if (entry.reason == TrackingAttentionReason.inert) entry,
    ];
    expect(inert, hasLength(1));
    expect(inert.single.mapping?.id, dead.id);
    expect(inert.single.siteId, site.id);
  });
}
