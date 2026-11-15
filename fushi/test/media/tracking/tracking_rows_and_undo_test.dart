import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:test/test.dart';

/// T1 F15 (row titles and kinds), F21 (grouping) and F16 (undo of a hand
/// link) below the widgets.
void main() {
  group('video nature from scraped metadata', () {
    test('anime databases say anime', () {
      for (final String source in <String>['anidb', 'mal', 'anilist']) {
        expect(
          trackingVideoNatureOf(source: source),
          TrackingVideoNature.anime,
        );
      }
    });

    test('TMDB: animation genre or anime keyword = anime, other genres = '
        'live action, no tags = unknown', () {
      expect(
        trackingVideoNatureOf(
          source: 'tmdb',
          tagsJson: '[{"name":"Drama"},{"name":"アニメーション"}]',
        ),
        TrackingVideoNature.anime,
      );
      expect(
        trackingVideoNatureOf(source: 'tmdb', tagsJson: '[{"name":"anime"}]'),
        TrackingVideoNature.anime,
      );
      expect(
        trackingVideoNatureOf(
          source: 'tmdb',
          tagsJson: '[{"name":"Drama"},{"name":"Romance"}]',
        ),
        TrackingVideoNature.liveAction,
      );
      expect(
        trackingVideoNatureOf(source: 'tmdb'),
        TrackingVideoNature.unknown,
      );
      expect(
        trackingVideoNatureOf(source: 'manualUrl', tagsJson: '[{"name":"x"}]'),
        TrackingVideoNature.unknown,
      );
    });

    test('row kinds: live action wins, anime by metadata or link, else '
        'video', () {
      expect(
        trackingRowKindOf(
          TrackingKind.anime,
          nature: TrackingVideoNature.liveAction,
          linked: true,
        ),
        TrackingRowKind.liveAction,
      );
      expect(
        trackingRowKindOf(TrackingKind.anime, linked: true),
        TrackingRowKind.anime,
      );
      expect(trackingRowKindOf(TrackingKind.anime), TrackingRowKind.video);
      expect(
        trackingRowKindOf(
          TrackingKind.anime,
          nature: TrackingVideoNature.anime,
        ),
        TrackingRowKind.anime,
      );
      expect(trackingRowKindOf(TrackingKind.manga), TrackingRowKind.manga);
    });
  });

  test('row title: the work name first, the raw name only when it differs', () {
    const TrackingItemFacts work = TrackingItemFacts(
      workTitles: <String>['Koori no Jouheki'],
    );
    expect(
      trackingRowTitle('[Grp] Koori no Jouheki - 03 [1080p].mkv', work),
      'Koori no Jouheki',
    );
    expect(trackingRowRawName('Koori no Jouheki', 'koori no jouheki'), isNull);
    expect(trackingRowRawName('Koori 03.mkv', 'Koori'), 'Koori 03.mkv');
  });

  group('with a database', () {
    late FushiDatabase db;
    late MediaTrackingRepository repository;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repository = MediaTrackingRepository(db);
    });
    tearDown(() => db.close());

    Future<int> link(String key, int subject, {String title = 'T'}) =>
        repository.saveMapping(
          mediaType: TrackingMediaType.video,
          mediaKey: key,
          mediaTitle: title,
          kind: TrackingKind.anime,
          subjectId: subject,
          subjectName: 'Entry $subject',
          progressMode: TrackingProgressMode.episode,
          progressOffset: 1,
          provider: 'a',
        );

    test('a scraped TMDB drama is live action; its collection names the '
        'work', () async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'v1',
          title: 'How.Dare.You.S01E01.1080p',
          videoPath: '/v/1.mkv',
        ),
      );
      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: 'v1',
          source: 'tmdb',
          subjectId: '1',
          title: 'How Dare You!!',
          tagsJson: const Value<String?>('[{"name":"Drama"}]'),
          scrapedAt: DateTime(2026),
        ),
      );
      final TrackingItemFacts facts = (await loadTrackingRowFacts(
        db,
      )).of(TrackingMediaType.video.value, 'v1');
      expect(facts.nature, TrackingVideoNature.liveAction);
      expect(facts.scraped, isTrue);
      expect(facts.workTitles, <String>['How Dare You!!']);
    });

    test(
      'links to one entry are grouped; a series link is the parent',
      () async {
        await link('v1', 5);
        await link('v2', 5);
        await repository.saveMapping(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: '9',
          mediaTitle: 'Series',
          kind: TrackingKind.anime,
          subjectId: 5,
          subjectName: 'Entry 5',
          progressMode: TrackingProgressMode.episode,
          progressOffset: 1,
          provider: 'a',
        );
        await link('v3', 6);
        final List<TrackingLinkGroup> groups =
            groupTrackingLinks(<TrackingLinkedEntry>[
              for (final MediaTrackingMappingRow row
                  in await repository.listMappings())
                TrackingLinkedEntry(mapping: row, title: row.mediaTitle),
            ]);
        expect(groups, hasLength(2));
        final TrackingLinkGroup five = groups.firstWhere(
          (TrackingLinkGroup g) => g.subjectId == 5,
        );
        expect(five.members, hasLength(3));
        expect(five.parent?.mapping.mediaKey, '9');
        expect(
          groups.firstWhere((TrackingLinkGroup g) => g.subjectId == 6).isSingle,
          isTrue,
        );
      },
    );

    test('undo of a new link: the link and what it queued are gone', () async {
      final TrackingLinkState before = await repository.captureLinkState('a');
      await link('v1', 5);
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        localProgress: 3,
        completed: false,
        provider: 'a',
      );
      final TrackingLinkState after = await repository.captureLinkState('a');
      expect(after.outbox, hasLength(1));
      await repository.restoreLinkState(before: before, after: after);
      expect(await repository.listMappings(), isEmpty);
      expect(await repository.allPending(provider: 'a'), isEmpty);
    });

    test('undo of a changed link: the old link and its queued update come '
        'back exactly; other links are left alone', () async {
      await link('v1', 5);
      await link('v9', 8);
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        localProgress: 2,
        completed: false,
        provider: 'a',
      );
      final TrackingLinkState before = await repository.captureLinkState('a');
      await link('v1', 6);
      final TrackingLinkState after = await repository.captureLinkState('a');
      // Something else changes after the link: undo must not touch it.
      await link('v9', 10);
      await repository.restoreLinkState(before: before, after: after);
      final Map<String, MediaTrackingMappingRow> now =
          <String, MediaTrackingMappingRow>{
            for (final MediaTrackingMappingRow row
                in await repository.listMappings())
              row.mediaKey: row,
          };
      final MediaTrackingMappingRow oldV1 = before.mappings.values.firstWhere(
        (MediaTrackingMappingRow r) => r.mediaKey == 'v1',
      );
      expect(now['v1'], oldV1);
      expect(now['v9']!.subjectId, 10);
      final TrackingLinkState restored = await repository.captureLinkState('a');
      expect(restored.outbox[oldV1.id], before.outbox[oldV1.id]);
    });
  });
}
