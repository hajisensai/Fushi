import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/tracking_auto_link_notice.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:material_ui/material_ui.dart';

/// T1 F9, user decision B: a link tracking makes by itself is told once,
/// in one non-blocking notice; several at once collapse into a count.
final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

final class _Site implements TrackingProvider, TrackingAnimeLinker {
  @override
  String get id => RemoteAnimeIdType.anilist;

  @override
  String get displayName => 'AniList';

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
  ) async {}

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<TrackingLinkedSubject?> animeById(int subjectId) async =>
      TrackingLinkedSubject(subjectId: subjectId, name: 'Entry $subjectId');

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async => null;
}

RemoteAnimeEpisode _episode(String item, int anilist) => RemoteAnimeEpisode(
  mediaKey: 'jellyfin|srv|u|$item',
  title: 'Show $item',
  episodeNumber: 1,
  seasonNumber: 1,
  seasonIds: <String, String>{'anilist': '$anilist'},
  seriesId: 'series-$item',
  seriesTitle: 'Show $item',
);

MediaTrackingMappingRow _mapping(String key, String title, String entry) =>
    MediaTrackingMappingRow(
      id: key.hashCode,
      provider: 'anilist',
      mediaType: 'book',
      mediaKey: key,
      mediaTitle: title,
      kind: 'manga',
      subjectId: 1,
      subjectName: entry,
      progressMode: 'volume',
      progressOffset: 1,
      createdAt: 0,
      updatedAt: 0,
      sentCompleted: false,
    );

void main() {
  test('the service tells each automatic link once, not hand links', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final MediaTrackingRepository repository = MediaTrackingRepository(db);
    final MediaTrackingService service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test',
      extraProviders: <TrackingProvider>[_Site()],
    );
    final List<TrackingAutoLink> told = <TrackingAutoLink>[];
    final StreamSubscription<TrackingAutoLink> sub = service.autoLinks.listen(
      told.add,
    );
    addTearDown(() async {
      await sub.cancel();
      service.dispose();
      prefs.dispose();
      await db.close();
    });

    await service.recordRemoteVideoCompleted(_episode('a', 11));
    await service.recordRemoteVideoCompleted(_episode('a', 11));
    await service.saveManualMappingAndSync(
      mediaType: TrackingMediaType.remoteVideo,
      mediaKey: 'jellyfin|srv|u|b',
      mediaTitle: 'Hand linked',
      kind: TrackingKind.anime,
      subjectId: 22,
      subjectName: 'Entry 22',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
      provider: 'anilist',
    );
    await pumpEventQueue();

    expect(told, hasLength(1));
    expect(told.single.mapping.mediaTitle, 'Show a');
    expect(told.single.mapping.subjectName, 'Entry 11');
    expect(told.single.siteName, 'AniList');
  });

  testWidgets('links made while a notice is up join it: one notice with a '
      'count, and its button opens the Tracking page', (
    WidgetTester tester,
  ) async {
    final GlobalKey<ScaffoldMessengerState> messenger =
        GlobalKey<ScaffoldMessengerState>();
    final StreamController<TrackingAutoLink> links =
        StreamController<TrackingAutoLink>();
    int reviews = 0;
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messenger,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final TrackingAutoLinkNotices notices = TrackingAutoLinkNotices(
      links: links.stream,
      messenger: messenger,
      onReview: () => reviews++,
    );
    addTearDown(() async {
      notices.dispose();
      await links.close();
    });

    links.add(
      TrackingAutoLink(
        mapping: _mapping('k1', 'Ajin 02', 'Ajin: Demi-Human'),
        siteName: 'MangaBaka',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    expect(
      find.text(
        'Linked “Ajin 02” automatically: Ajin: Demi-Human on MangaBaka',
      ),
      findsOneWidget,
    );

    for (final String key in <String>['k2', 'k3']) {
      links.add(
        TrackingAutoLink(
          mapping: _mapping(key, 'Book $key', 'Entry $key'),
          siteName: 'AniList',
        ),
      );
    }
    await tester.pump();
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Linked 3 titles automatically'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(reviews, 1);
  });
}
