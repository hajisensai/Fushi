// Media tracking on the home page: when the strip appears, what it says, the
// state mark of a Continue entry, and that the cover row draws that mark
// without taking the cover's tap.

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/pages/implementations/home_tracking_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

MediaTrackingProviderStatus site(
  String id, {
  bool enabled = true,
  bool configured = true,
  bool unauthorized = false,
  int pending = 0,
  int lastSyncAt = 0,
  List<int> failedMappings = const <int>[],
}) => MediaTrackingProviderStatus(
  providerId: id,
  enabled: enabled,
  configured: configured,
  accountName: '',
  lastSyncAt: lastSyncAt,
  lastSucceeded: 0,
  lastFailed: failedMappings.length,
  unauthorized: unauthorized,
  pending: pending,
  failures: <MediaTrackingFailure>[
    for (final int id in failedMappings)
      MediaTrackingFailure(
        mappingId: id,
        mediaTitle: 't',
        subjectId: 1,
        subjectName: 's',
        attemptCount: 1,
        nextAttemptAt: 0,
        error: 'boom',
      ),
  ],
);

MediaTrackingMappingRow mapping(
  int id,
  String provider,
  TrackingMediaType type,
  String key,
) => MediaTrackingMappingRow(
  id: id,
  provider: provider,
  mediaType: type.value,
  mediaKey: key,
  mediaTitle: 'title $id',
  kind: TrackingKind.anime.value,
  subjectId: 100 + id,
  subjectName: 'subject $id',
  progressMode: TrackingProgressMode.episode.value,
  progressOffset: 1,
  createdAt: 0,
  updatedAt: 0,
  sentCompleted: false,
);

MediaTrackingUnlinkedItem unlinked(TrackingMediaType type, String key) =>
    MediaTrackingUnlinkedItem(
      mediaType: type,
      mediaKey: key,
      mediaTitle: 'old',
      kind: TrackingKind.anime,
      lastActivityAt: 0,
    );

MediaTrackingHomeSnapshot snapshot({
  List<MediaTrackingProviderStatus> sites =
      const <MediaTrackingProviderStatus>[],
  List<MediaTrackingMappingRow> mappings = const <MediaTrackingMappingRow>[],
  List<MediaTrackingUnlinkedItem> notLinked =
      const <MediaTrackingUnlinkedItem>[],
}) => MediaTrackingHomeSnapshot(
  sites: sites,
  siteNames: const <String, String>{
    'anilist': 'AniList',
    'mangabaka': 'MangaBaka',
  },
  mappings: mappings,
  unlinked: notLinked,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('HomeTrackingSummary', () {
    test('counts only sites that are on and signed in', () {
      final HomeTrackingSummary s = HomeTrackingSummary.of(
        snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist', pending: 2, lastSyncAt: 50, failedMappings: [7]),
            site('mangabaka', enabled: false, pending: 9, unauthorized: true),
            site('bangumi', configured: false, failedMappings: <int>[8]),
          ],
          notLinked: <MediaTrackingUnlinkedItem>[
            unlinked(TrackingMediaType.video, 'v1'),
          ],
        ),
      );
      expect(s.connected, 1);
      expect(s.pending, 2);
      expect(s.failed, 1);
      expect(s.signInNeeded, 0);
      expect(s.unlinked, 1);
      expect(s.lastSyncAt, 50);
      expect(s.needsAttention, isTrue);
    });

    test('with no site connected, unlinked history is not a to-do', () {
      final HomeTrackingSummary s = HomeTrackingSummary.of(
        snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist', configured: false),
          ],
          notLinked: <MediaTrackingUnlinkedItem>[
            unlinked(TrackingMediaType.video, 'v1'),
          ],
        ),
      );
      expect(s.connected, 0);
      expect(s.unlinked, 0);
      expect(s.needsAttention, isFalse);
    });

    test('a rejected sign-in needs attention', () {
      final HomeTrackingSummary s = HomeTrackingSummary.of(
        snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist', unauthorized: true),
          ],
        ),
      );
      expect(s.signInNeeded, 1);
      expect(s.needsAttention, isTrue);
    });
  });

  group('resolveHomeTrackingPanelVisible', () {
    final HomeTrackingSummary quiet = HomeTrackingSummary.of(
      snapshot(sites: <MediaTrackingProviderStatus>[site('anilist')]),
    );
    final HomeTrackingSummary todo = HomeTrackingSummary.of(
      snapshot(
        sites: <MediaTrackingProviderStatus>[site('anilist')],
        notLinked: <MediaTrackingUnlinkedItem>[
          unlinked(TrackingMediaType.video, 'v1'),
        ],
      ),
    );

    bool visible(
      HomeDashboardPanelMode mode,
      HomeTrackingSummary summary, {
      bool available = true,
    }) => resolveHomeTrackingPanelVisible(
      available: available,
      mode: mode,
      summary: summary,
    );

    test('automatic: only while something needs the user', () {
      expect(visible(HomeDashboardPanelMode.auto, quiet), isFalse);
      expect(visible(HomeDashboardPanelMode.auto, todo), isTrue);
      expect(
        visible(HomeDashboardPanelMode.auto, HomeTrackingSummary.none),
        isFalse,
      );
    });

    test('pinned on shows every state, pinned off hides every state', () {
      expect(visible(HomeDashboardPanelMode.shown, quiet), isTrue);
      expect(
        visible(HomeDashboardPanelMode.shown, HomeTrackingSummary.none),
        isTrue,
      );
      expect(visible(HomeDashboardPanelMode.hidden, todo), isFalse);
    });

    test('never without tracking in the build or the Services module', () {
      expect(
        visible(HomeDashboardPanelMode.shown, todo, available: false),
        isFalse,
      );
    });

    test('the panel id is frozen', () {
      expect(HomeDashboardPanel.tracking.id, 'tracking');
    });
  });

  group('homeTrackingPanelText', () {
    final DateTime now = DateTime(2026, 11, 10, 12);

    test('problems come first, most blocking first', () {
      final String text = homeTrackingPanelText(
        HomeTrackingSummary.of(
          snapshot(
            sites: <MediaTrackingProviderStatus>[
              site('anilist', unauthorized: true, failedMappings: <int>[1]),
            ],
            notLinked: <MediaTrackingUnlinkedItem>[
              unlinked(TrackingMediaType.video, 'a'),
              unlinked(TrackingMediaType.video, 'b'),
            ],
          ),
        ),
        now,
      );
      expect(
        text,
        '${t.home_tracking_panel_sign_in} · '
        '${t.home_tracking_panel_to_link(n: 2)} · '
        '${t.home_tracking_panel_failed(n: 1)}',
      );
    });

    test('no site, waiting to send, and all sent', () {
      expect(
        homeTrackingPanelText(HomeTrackingSummary.none, now),
        t.home_tracking_panel_not_connected,
      );
      expect(
        homeTrackingPanelText(
          HomeTrackingSummary.of(
            snapshot(
              sites: <MediaTrackingProviderStatus>[site('anilist', pending: 3)],
            ),
          ),
          now,
        ),
        t.media_tracking_pending_count(n: 3),
      );
      expect(
        homeTrackingPanelText(
          HomeTrackingSummary.of(
            snapshot(sites: <MediaTrackingProviderStatus>[site('anilist')]),
          ),
          now,
        ),
        t.media_tracking_all_synced,
      );
      expect(
        homeTrackingPanelText(
          HomeTrackingSummary.of(
            snapshot(
              sites: <MediaTrackingProviderStatus>[
                site(
                  'anilist',
                  lastSyncAt: now
                      .subtract(const Duration(minutes: 5))
                      .millisecondsSinceEpoch,
                ),
              ],
            ),
          ),
          now,
        ),
        startsWith('${t.media_tracking_all_synced} · '),
      );
    });
  });

  group('homeTrackingMark', () {
    const HomeTrackingKey video = (type: TrackingMediaType.video, key: 'v1');
    const HomeTrackingKey season = (
      type: TrackingMediaType.videoCollection,
      key: '12',
    );

    test('no connected site: nothing to say', () {
      expect(
        homeTrackingMark(
          snapshot: snapshot(
            sites: <MediaTrackingProviderStatus>[
              site('anilist', configured: false),
            ],
            mappings: <MediaTrackingMappingRow>[
              mapping(1, 'anilist', TrackingMediaType.video, 'v1'),
            ],
          ),
          keys: const <HomeTrackingKey>[video],
        ),
        isNull,
      );
    });

    test('linked through the collection reads as tracked on that site', () {
      final FushiContinueMark? mark = homeTrackingMark(
        snapshot: snapshot(
          sites: <MediaTrackingProviderStatus>[site('anilist')],
          mappings: <MediaTrackingMappingRow>[
            mapping(1, 'anilist', TrackingMediaType.videoCollection, '12'),
          ],
        ),
        keys: const <HomeTrackingKey>[video, season],
      );
      expect(mark, isNotNull);
      expect(mark!.problem, isFalse);
      expect(mark.icon, FushiIcons.check);
      expect(mark.label, t.home_tracking_mark_linked(site: 'AniList'));
    });

    test('a failed send wins over a working link on another site', () {
      final FushiContinueMark? mark = homeTrackingMark(
        snapshot: snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist'),
            site('mangabaka', failedMappings: <int>[2]),
          ],
          mappings: <MediaTrackingMappingRow>[
            mapping(1, 'anilist', TrackingMediaType.book, 'b1'),
            mapping(2, 'mangabaka', TrackingMediaType.book, 'b1'),
          ],
        ),
        keys: const <HomeTrackingKey>[
          (type: TrackingMediaType.book, key: 'b1'),
        ],
      );
      expect(mark!.problem, isTrue);
      expect(mark.label, t.home_tracking_mark_failed(site: 'MangaBaka'));
    });

    test('a link on a site that is switched off does not count', () {
      final FushiContinueMark? mark = homeTrackingMark(
        snapshot: snapshot(
          sites: <MediaTrackingProviderStatus>[
            site('anilist'),
            site('mangabaka', enabled: false),
          ],
          mappings: <MediaTrackingMappingRow>[
            mapping(2, 'mangabaka', TrackingMediaType.video, 'v1'),
          ],
          notLinked: <MediaTrackingUnlinkedItem>[
            unlinked(TrackingMediaType.video, 'v1'),
          ],
        ),
        keys: const <HomeTrackingKey>[video],
      );
      expect(mark!.problem, isTrue);
      expect(mark.icon, FushiIcons.linkOff);
      expect(mark.label, t.media_tracking_manual_required);
    });

    test('an entry tracking never looked at gets no mark', () {
      expect(
        homeTrackingMark(
          snapshot: snapshot(
            sites: <MediaTrackingProviderStatus>[site('anilist')],
          ),
          keys: const <HomeTrackingKey>[video],
        ),
        isNull,
      );
    });
  });

  group('widgets', () {
    Widget app(Widget child, {bool glass = false, bool eink = false}) =>
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              extensions: <ThemeExtension<dynamic>>[
                FushiEinkTheme(eink),
                FushiGlassTheme(FushiGlassMaterial.off, glassDesign: glass),
              ],
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 360, child: child),
              ),
            ),
          ),
        );

    for (final bool glass in <bool>[false, true]) {
      testWidgets('strip with a to-do: text, Review button, both open '
          '(${glass ? 'Apple' : 'Material'})', (WidgetTester tester) async {
        int opened = 0;
        final HomeTrackingSummary summary = HomeTrackingSummary.of(
          snapshot(
            sites: <MediaTrackingProviderStatus>[site('anilist')],
            notLinked: <MediaTrackingUnlinkedItem>[
              unlinked(TrackingMediaType.video, 'v1'),
            ],
          ),
        );
        await tester.pumpWidget(
          app(
            HomeTrackingPanel(summary: summary, onOpen: () => opened++),
            glass: glass,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(t.home_tracking_panel_title), findsOneWidget);
        expect(find.text(t.home_tracking_panel_to_link(n: 1)), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('home-tracking-panel-action')),
        );
        await tester.tap(find.text(t.home_tracking_panel_title));
        expect(opened, 2);
      });
    }

    testWidgets('strip when all is sent has no button', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        app(
          HomeTrackingPanel(
            summary: HomeTrackingSummary.of(
              snapshot(sites: <MediaTrackingProviderStatus>[site('anilist')]),
            ),
            onOpen: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(t.media_tracking_all_synced), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('home-tracking-panel-action')),
        findsNothing,
      );
    });

    testWidgets('cover row draws the mark and the cover keeps its tap', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      FushiContinueEntry entry(FushiContinueMark? mark) => FushiContinueEntry(
        key: const ValueKey<String>('tile'),
        title: 'Book',
        cover: const ColoredBox(color: Color(0xFF808080)),
        mark: mark,
        onOpen: () => opened++,
      );
      Widget tile(FushiContinueMark? mark) => app(
        Builder(
          builder: (BuildContext context) => FushiContinueSideTile(
            entry: entry(mark),
            coverHeight: 150,
            metaHeight: FushiContinueSideMeta.full.heightFor(context),
          ),
        ),
      );

      await tester.pumpWidget(tile(null));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('fushi-continue-mark')),
        findsNothing,
      );

      await tester.pumpWidget(
        tile(
          const FushiContinueMark(
            icon: FushiIcons.linkOff,
            label: 'Needs manual link',
            problem: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder badge = find.byKey(
        const ValueKey<String>('fushi-continue-mark'),
      );
      expect(badge, findsOneWidget);
      expect(tester.takeException(), isNull);
      // A tap on the badge lands on the cover card under it.
      await tester.tapAt(tester.getCenter(badge));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(
        find.bySemanticsLabel(RegExp('Book.*Needs manual link')),
        findsOneWidget,
      );
    });
  });
}
