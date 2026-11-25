// The home Tracking widget's "Last synced" view: when it applies and which
// update leads, and that every cell size from 1×1 to 6×2 lays out without
// overflow in the three home looks (section card, collage block, Apple) and
// shows what that size promises.

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/home_tracking_feed.dart';
import 'package:fushi/src/pages/implementations/home_tracking_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaTrackingActivityRow,
        MediaTrackingMappingRow,
        MediaTrackingOutboxRow;
import 'package:fushi_engine/media/tracking/media_tracking_recent_sends.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

int _id = 0;

final DateTime _now = DateTime(2026, 11, 24, 18);
int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

MediaTrackingProviderStatus site(
  String id, {
  bool unauthorized = false,
  int pending = 0,
  int failed = 0,
}) => MediaTrackingProviderStatus(
  providerId: id,
  enabled: true,
  configured: true,
  accountName: '',
  lastSyncAt: _ago(const Duration(minutes: 52)),
  lastSucceeded: 0,
  lastFailed: failed,
  unauthorized: unauthorized,
  pending: pending,
  failures: <MediaTrackingFailure>[
    for (int i = 0; i < failed; i++)
      MediaTrackingFailure(
        mappingId: i,
        mediaTitle: 't',
        subjectId: 1,
        subjectName: 's',
        attemptCount: 1,
        nextAttemptAt: 0,
        error: 'HTTP 503',
      ),
  ],
);

MediaTrackingActivityRow sent(
  String provider,
  String key,
  int progress, {
  required Duration ago,
}) => MediaTrackingActivityRow(
  id: ++_id,
  provider: provider,
  mediaType: TrackingMediaType.videoCollection.value,
  mediaKey: key,
  mediaTitle: 'Title $key',
  kind: TrackingKind.anime.value,
  progressMode: TrackingProgressMode.episode.value,
  progress: progress,
  completed: false,
  ok: true,
  createdAt: _ago(ago),
);

PendingTrackingUpdate queued(String key, {String? error}) =>
    PendingTrackingUpdate(
      outbox: MediaTrackingOutboxRow(
        id: ++_id,
        mappingId: _id,
        progress: 7,
        completed: false,
        attemptCount: error == null ? 0 : 2,
        nextAttemptAt: 0,
        lastError: error,
        updatedAt: _ago(const Duration(minutes: 3)),
      ),
      mapping: MediaTrackingMappingRow(
        id: _id,
        provider: 'mal',
        mediaType: TrackingMediaType.videoCollection.value,
        mediaKey: key,
        mediaTitle: 'Title $key',
        kind: TrackingKind.anime.value,
        subjectId: 1,
        subjectName: 's',
        progressMode: TrackingProgressMode.episode.value,
        progressOffset: 1,
        createdAt: 0,
        updatedAt: 0,
        sentCompleted: false,
      ),
    );

MediaTrackingUnlinkedItem unlinked(String key) => MediaTrackingUnlinkedItem(
  mediaType: TrackingMediaType.video,
  mediaKey: key,
  mediaTitle: 'old',
  kind: TrackingKind.anime,
  lastActivityAt: 0,
);

MediaTrackingHomeSnapshot snapshot({
  List<MediaTrackingProviderStatus>? sites,
  List<MediaTrackingActivityRow> activity = const <MediaTrackingActivityRow>[],
  List<PendingTrackingUpdate> outbox = const <PendingTrackingUpdate>[],
  List<MediaTrackingUnlinkedItem> notLinked =
      const <MediaTrackingUnlinkedItem>[],
}) => MediaTrackingHomeSnapshot(
  sites: sites ?? <MediaTrackingProviderStatus>[site('anilist'), site('mal')],
  siteNames: const <String, String>{'anilist': 'AniList', 'mal': 'MyAnimeList'},
  mappings: const <MediaTrackingMappingRow>[],
  unlinked: notLinked,
  activity: activity,
  queued: outbox,
);

HomeTrackingFeed? feedOf(MediaTrackingHomeSnapshot s) =>
    HomeTrackingFeed.of(s, HomeTrackingSummary.of(s), _now);

/// Newest first: Frieren ep 12 to both sites 52 min ago, then four more
/// titles today.
List<MediaTrackingActivityRow> busyDay() => <MediaTrackingActivityRow>[
  sent('anilist', 'frieren', 12, ago: const Duration(minutes: 52)),
  sent('mal', 'frieren', 12, ago: const Duration(minutes: 52)),
  sent('anilist', 'apothecary', 40, ago: const Duration(hours: 3)),
  sent('anilist', 'spice', 4, ago: const Duration(hours: 5)),
  sent('mal', 'dungeon', 6, ago: const Duration(hours: 8)),
  sent('anilist', 'blue', 63, ago: const Duration(hours: 9)),
];

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('HomeTrackingFeed.of', () {
    test('the newest accepted send leads; the others are earlier', () {
      final HomeTrackingFeed feed = feedOf(snapshot(activity: busyDay()))!;
      expect(feed.state, HomeTrackingFeedState.synced);
      expect(feed.hero.mediaKey, 'frieren');
      expect(feed.sitesOf(feed.hero), 'AniList · MyAnimeList');
      expect(
        feed.earlier.map((MediaTrackingRecentSend s) => s.mediaKey),
        <String>['apothecary', 'spice', 'dungeon', 'blue'],
      );
      expect(feed.sentToday, 5);
      expect(
        homeTrackingFeedMoreToday(feed),
        t.home_tracking_feed_more_today(n: 4),
      );
      expect(feed.week.updates, 5);
    });

    test('titles to link or a rejected sign-in keep the problems layout', () {
      expect(
        feedOf(
          snapshot(
            activity: busyDay(),
            notLinked: <MediaTrackingUnlinkedItem>[unlinked('v')],
          ),
        ),
        isNull,
      );
      expect(
        feedOf(
          snapshot(
            activity: busyDay(),
            sites: <MediaTrackingProviderStatus>[
              site('anilist', unauthorized: true),
            ],
          ),
        ),
        isNull,
      );
    });

    test('a failing update leads in the failed state', () {
      final HomeTrackingFeed feed = feedOf(
        snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist'),
            site('mal', pending: 1, failed: 1),
          ],
          activity: busyDay(),
          outbox: <PendingTrackingUpdate>[queued('dungeon', error: 'HTTP 503')],
        ),
      )!;
      expect(feed.state, HomeTrackingFeedState.failed);
      expect(feed.hero.mediaKey, 'dungeon');
      expect(feed.hero.error, 'HTTP 503');
      expect(feed.earlier.first.mediaKey, 'frieren');
    });

    test('queued updates lead in the sending state', () {
      final HomeTrackingFeed feed = feedOf(
        snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist'),
            site('mal', pending: 2),
          ],
          activity: busyDay(),
          outbox: <PendingTrackingUpdate>[queued('a'), queued('b')],
        ),
      )!;
      expect(feed.state, HomeTrackingFeedState.sending);
      expect(feed.waiting, 2);
      expect(
        homeTrackingFeedMetaLine(feed, _now),
        contains(t.media_tracking_pending_count(n: 2)),
      );
    });

    test('nothing sent or queued, or no site connected: no feed', () {
      expect(feedOf(snapshot()), isNull);
      expect(
        feedOf(
          snapshot(
            sites: const <MediaTrackingProviderStatus>[],
            activity: busyDay(),
          ),
        ),
        isNull,
      );
    });
  });

  group('HomeTrackingFeedCard', () {
    // The default 800×600 test surface would squeeze a 6-column cell (900).
    setUp(() {
      final TestWidgetsFlutterBinding binding =
          TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.views.first
        ..physicalSize = const Size(1200, 900)
        ..devicePixelRatio = 1;
    });
    tearDown(() {
      TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .views
          .first
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    Widget app(
      Widget child, {
      required Size size,
      bool glass = false,
      double textScale = 1,
    }) => TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[
            FushiEinkTheme(false),
            FushiGlassTheme(FushiGlassMaterial.off, glassDesign: glass),
          ],
        ),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(1200, 900),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: size, child: child),
            ),
          ),
        ),
      ),
    );

    // Real grid proportions: one column ≈ 140, one row ≈ 158, gap 12.
    Size cell(int cols, int rows) =>
        Size(cols * 140.0 + (cols - 1) * 12, rows * 158.0 + (rows - 1) * 12);

    const Map<String, ({bool poster, bool glass})> looks =
        <String, ({bool poster, bool glass})>{
          'card': (poster: false, glass: false),
          'collage': (poster: true, glass: false),
          'apple': (poster: false, glass: true),
        };

    final List<(int, int)> sizes = <(int, int)>[
      (1, 1),
      (2, 1),
      (3, 1),
      (4, 1),
      (6, 1),
      (1, 2),
      (2, 2),
      (4, 2),
      (6, 2),
    ];

    for (final MapEntry<String, ({bool poster, bool glass})> look
        in looks.entries) {
      for (final double scale in <double>[1, 1.6]) {
        testWidgets('every size lays out (${look.key}, text ×$scale)', (
          WidgetTester tester,
        ) async {
          final HomeTrackingFeed feed = feedOf(snapshot(activity: busyDay()))!;
          for (final (int cols, int rows) in sizes) {
            await tester.pumpWidget(
              app(
                HomeTrackingFeedCard(
                  feed: feed,
                  coverOf: (MediaTrackingRecentSend s) => null,
                  onOpen: () {},
                  poster: look.value.poster,
                ),
                size: cell(cols, rows),
                glass: look.value.glass,
                textScale: scale,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '${cols}x$rows ${look.key} ×$scale',
            );
          }
        });
      }
    }

    Future<void> pumpAt(WidgetTester tester, int cols, int rows) async {
      final HomeTrackingFeed feed = feedOf(snapshot(activity: busyDay()))!;
      await tester.pumpWidget(
        app(
          HomeTrackingFeedCard(
            feed: feed,
            coverOf: (MediaTrackingRecentSend s) => null,
            onOpen: () {},
            poster: true,
          ),
          size: cell(cols, rows),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder earlier() => find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(
            'home-tracking-feed-earlier-',
          ),
    );

    testWidgets('1×1: cover with a mark and the progress, no title', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 1, 1);
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-mark')),
        findsOneWidget,
      );
      expect(find.text('Episode 12'), findsOneWidget);
      expect(find.text('Title frieren'), findsNothing);
    });

    testWidgets('2×1: the hero with sites, time and "+4 more today"', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 2, 1);
      expect(find.text(t.home_tracking_feed_title_synced), findsOneWidget);
      expect(find.text('Title frieren'), findsOneWidget);
      expect(find.text('Episode 12'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-meta')),
        findsOneWidget,
      );
      expect(find.text(t.home_tracking_feed_more_today(n: 4)), findsOneWidget);
      expect(earlier(), findsNothing);
    });

    testWidgets('6×1: earlier sends line up beside the hero', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 6, 1);
      expect(earlier(), findsNWidgets(3));
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-more')),
        findsNothing,
      );
    });

    testWidgets('2×2: the hero on top, a list below', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 2, 2);
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-list')),
        findsOneWidget,
      );
      expect(earlier(), findsWidgets);
    });

    testWidgets('6×2: adds the site column and the 7-day counts', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 6, 2);
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-sites')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-week')),
        findsOneWidget,
      );
      expect(find.text(t.home_tracking_feed_earlier), findsOneWidget);
    });

    testWidgets('4×2: no site column yet', (WidgetTester tester) async {
      await pumpAt(tester, 4, 2);
      expect(
        find.byKey(const ValueKey<String>('home-tracking-feed-sites')),
        findsNothing,
      );
      expect(earlier(), findsWidgets);
    });

    testWidgets('a failing update shows its error and the whole card opens', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      final HomeTrackingFeed feed = feedOf(
        snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('mal', pending: 1, failed: 1),
          ],
          outbox: <PendingTrackingUpdate>[queued('dungeon', error: 'HTTP 503')],
        ),
      )!;
      await tester.pumpWidget(
        app(
          HomeTrackingFeedCard(
            feed: feed,
            coverOf: (MediaTrackingRecentSend s) => null,
            onOpen: () => opened++,
            poster: false,
          ),
          size: cell(2, 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.home_tracking_feed_title_failed), findsOneWidget);
      expect(find.text('HTTP 503'), findsOneWidget);
      await tester.tap(find.text('Title dungeon'));
      expect(opened, 1);
    });
  });
}
