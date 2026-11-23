// Series-level book links in the UI (design notes section E, point 2, as
// reworked on review): the series card's Tracking section manages series
// links and how each volume counts; a volume's Track sheet only shows it and
// leads to the card; the Tracking page lists a series link as the parent of
// its group row, and offers merging volume links as a card in Needs
// attention. Real tracking service, in-memory database, a stand-in site.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/book_tracking_dialog.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_page.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_rows.dart';
import 'package:fushi/src/media/tracking/series_card_tracking_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/book_series_link.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

const String _site = 'a';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in manga / novel site whose search returns entries that never
/// match a local title by themselves (nothing is linked automatically).
final class _BookSite implements TrackingProvider, TrackingBookLinker {
  @override
  String get id => _site;

  @override
  String get displayName => 'Site a';

  @override
  String get siteHost => 'a.example';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.manga, TrackingKind.novel},
        progressModes: <TrackingProgressMode>{
          TrackingProgressMode.chapter,
          TrackingProgressMode.volume,
        },
        onByDefault: <TrackingKind>{TrackingKind.manga, TrackingKind.novel},
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
  Future<List<TrackingBookSubject>> searchBooks(
    String query,
    TrackingKind kind,
  ) async => <TrackingBookSubject>[
    for (int i = 1; i <= 2; i++)
      TrackingBookSubject(
        subjectId: i,
        name: 'Unrelated result $i',
        kind: kind,
        titles: <String>['Unrelated result $i'],
      ),
  ];

  @override
  Future<TrackingBookSubject?> bookById(int subjectId) async => null;

  @override
  Future<TrackingBookSubject?> bookForLinkedId(
    String providerId,
    int subjectId,
  ) async => null;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late MediaTrackingService service;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      repository = MediaTrackingRepository(db);
      service = MediaTrackingService(
        repository: repository,
        preferences: prefs,
        userAgent: 'test-agent',
        extraProviders: <TrackingProvider>[_BookSite()],
        bookLinkHints: (EpubBookRow book) async => null,
      );
    });
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(() async {
        prefs.dispose();
        await db.close();
      });
    });
  }

  /// Lets the database and the service answer, then draws.
  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    bool apple = false,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith(
            (Ref ref) => AppModel(testPlatformServices()),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: apple
                  ? FushiDesignSystem.cupertino
                  : FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: apple,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: home,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> insertBook(String title) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '/books/$title.cbz',
      extractDir: '/books/$title',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
      uid: Value<String>('uid:$title'),
    ),
  );

  /// The organiser's series card [name] holding [titles] (books inserted).
  Future<int> seriesCard(String name, List<String> titles) async {
    for (final String title in titles) {
      await insertBook(title);
    }
    final int id = await db.createMediaCollection(
      name,
      collectionType: 'playlist',
      origin: CollectionOrigin.rule,
    );
    for (final String title in titles) {
      await db.addToCollection(
        id,
        MediaKind.epub,
        'uid:$title',
        userIntent: false,
      );
    }
    return id;
  }

  /// A series link of card [cardKey] (a missing card id makes an orphan).
  Future<int> seriesLink(String cardKey, {String title = 'Ajin'}) =>
      repository.saveMapping(
        mediaType: TrackingMediaType.bookCollection,
        mediaKey: cardKey,
        mediaTitle: title,
        kind: TrackingKind.manga,
        subjectId: 700,
        subjectName: 'Ajin: Demi-Human',
        progressMode: TrackingProgressMode.volume,
        progressOffset: 0,
        provider: _site,
      );

  Future<MediaTrackingMappingRow?> findSeries(WidgetTester tester, int card) =>
      tester.runAsync<MediaTrackingMappingRow?>(
        () => repository.findMapping(
          mediaType: TrackingMediaType.bookCollection,
          mediaKey: '$card',
          provider: _site,
        ),
      );

  Future<MediaTrackingMappingRow?> findBook(WidgetTester tester, String key) =>
      tester.runAsync<MediaTrackingMappingRow?>(
        () => repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: key,
          provider: _site,
        ),
      );

  Finder button(String key) => find.byKey(ValueKey<String>('$key-$_site'));

  /// The series cards the page or sheet asked to open: (card id, volume).
  final List<(int, String)> opened = <(int, String)>[];
  Future<void> openCard(BuildContext context, int card, String bookKey) async =>
      opened.add((card, bookKey));
  setUp(opened.clear);

  Finder searchButton() => find.byWidgetPredicate(
    (Widget widget) =>
        widget is FushiIconButton &&
        widget.tooltip == t.media_tracking_track_search,
  );

  /// Picks [action] in the row menu [menuKey].
  Future<void> pickMenu(
    WidgetTester tester,
    String menuKey,
    String action,
  ) async {
    await tester.tap(find.byKey(ValueKey<String>(menuKey)));
    await settle(tester, rounds: 3);
    await tester.tap(
      find.byKey(ValueKey<String>('tracking-row-action-$action')),
    );
    await settle(tester);
  }

  group('Track sheet of a volume counted by a series link', () {
    late int card;

    Future<void> openSheet(
      WidgetTester tester, {
      bool apple = false,
      String? separateOn,
    }) async {
      await open(tester);
      await tester.runAsync(() async {
        card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
        await seriesLink('$card');
      });
      await pumpApp(
        tester,
        Scaffold(
          body: BookTrackingDialog(
            service: service,
            bookKey: 'Ajin 02',
            separateOn: separateOn,
            openSeriesCard: openCard,
          ),
        ),
        apple: apple,
      );
    }

    for (final bool apple in <bool>[false, true]) {
      testWidgets('read-only: how it counts, no search, managed on the series '
          'card (${apple ? 'Apple' : 'Material'})', (
        WidgetTester tester,
      ) async {
        await openSheet(tester, apple: apple);
        expect(
          find.text(
            t.tracking_series_tracked_with(
              series: 'Ajin',
              site: 'Site a',
              volume: '2',
            ),
          ),
          findsOneWidget,
        );
        expect(find.text(t.tracking_series_earlier_counted), findsOneWidget);
        expect(find.text(t.media_tracking_track_linked), findsOneWidget);
        expect(searchButton(), findsNothing, reason: 'counted by the series');
        for (final String key in <String>[
          'book-tracking-series-exclude',
          'book-tracking-series-separate',
          'book-tracking-series-renumber',
          'book-tracking-series-remove',
        ]) {
          expect(button(key), findsNothing, reason: '$key moved to the card');
        }

        await tester.tap(button('book-tracking-series-manage'));
        await settle(tester, rounds: 2);
        expect(opened, <(int, String)>[(card, 'Ajin 02')]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('opened to link the volume separately: the search links this '
        'volume alone, the series link stays', (WidgetTester tester) async {
      await openSheet(tester, separateOn: _site);
      expect(searchButton(), findsOneWidget);
      await tester.tap(searchButton());
      await settle(tester);
      await tester.tap(find.text(t.media_tracking_track_approve).first);
      await settle(tester);
      expect((await findBook(tester, 'Ajin 02'))?.subjectId, 1);
      expect((await findSeries(tester, card))?.subjectId, 700);
      expect(
        find.byKey(
          const ValueKey<String>('book-tracking-series-own-link-$_site'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Track sheet of a volume on a series card without a series link', () {
    late int card;

    Future<void> openSheet(WidgetTester tester) async {
      await open(tester);
      await tester.runAsync(() async {
        card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
        await repository.saveSuggestions(
          provider: _site,
          mediaType: TrackingMediaType.book,
          mediaKey: 'Ajin 01',
          suggestions: <TrackingSuggestionDraft>[
            (
              subjectId: 42,
              subjectName: 'Ajin',
              subjectKind: TrackingKind.manga,
              score: 0.8,
              details: const <String, Object?>{},
            ),
          ],
        );
      });
      await pumpApp(
        tester,
        Scaffold(
          body: BookTrackingDialog(
            service: service,
            bookKey: 'Ajin 01',
            openSeriesCard: openCard,
          ),
        ),
      );
    }

    testWidgets('links only this volume and points to the card for the whole '
        'series', (WidgetTester tester) async {
      await openSheet(tester);
      expect(
        find.text(t.tracking_series_link_on_card_hint(series: 'Ajin')),
        findsOneWidget,
      );
      // An approved suggestion links the volume, not the card.
      await tester.tap(find.text(t.media_tracking_track_approve).first);
      await settle(tester);
      expect((await findBook(tester, 'Ajin 01'))?.subjectId, 42);
      expect(await findSeries(tester, card), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Manage on series card" opens the card', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);
      await tester.tap(button('book-tracking-series-open-card'));
      await settle(tester, rounds: 2);
      expect(opened, <(int, String)>[(card, 'Ajin 01')]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Tracking section of the series card', () {
    late int card;

    Future<void> openSection(
      WidgetTester tester, {
      bool linked = true,
      bool apple = false,
    }) async {
      await open(tester);
      await tester.runAsync(() async {
        card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
        if (linked) await seriesLink('$card');
      });
      await pumpApp(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: SeriesCardTrackingSection(
              service: service,
              collectionId: card,
            ),
          ),
        ),
        apple: apple,
      );
    }

    String volumeMenu(String bookKey) =>
        'series-card-tracking-volume-menu-$_site-$bookKey';

    for (final bool apple in <bool>[false, true]) {
      testWidgets('"Link series" searches and links the whole card '
          '(${apple ? 'Apple' : 'Material'})', (WidgetTester tester) async {
        await openSection(tester, linked: false, apple: apple);
        expect(find.text(t.tracking_series_section_title), findsOneWidget);
        await tester.tap(
          find.byKey(
            const ValueKey<String>('series-card-tracking-link-$_site'),
          ),
        );
        await settle(tester);
        // The search runs on open with the card's name.
        await tester.tap(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('series-card-tracking-result-1'),
            ),
            matching: find.text(t.media_tracking_track_approve),
          ),
        );
        await settle(tester);
        final MediaTrackingMappingRow? series = await findSeries(tester, card);
        expect(series?.subjectId, 1);
        expect(series?.progressMode, TrackingProgressMode.volume.value);
        expect(await findBook(tester, 'Ajin 01'), isNull);
        expect(
          find.byKey(
            const ValueKey<String>('series-card-tracking-unit-$_site'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey<String>(
              'series-card-tracking-volume-$_site-Ajin 02',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('every volume with its number and state; "Don\'t count" and '
        '"Count again"', (WidgetTester tester) async {
      await openSection(tester);
      expect(
        find.textContaining(
          '${t.media_tracking_track_by_volume(volume: '2')} · '
          '${t.tracking_series_state_counted}',
        ),
        findsOneWidget,
      );
      await pickMenu(tester, volumeMenu('Ajin 02'), 'exclude');
      final List<MediaTrackingIgnoredRow> ignored = (await tester.runAsync(
        service.listIgnored,
      ))!;
      expect(ignored.single.mediaKey, 'Ajin 02');
      expect(
        find.textContaining(t.tracking_series_state_excluded),
        findsOneWidget,
      );

      await pickMenu(tester, volumeMenu('Ajin 02'), 'count-again');
      expect(await tester.runAsync(service.listIgnored), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Change volume number" gives the volume its own link to the '
        'series entry with that number', (WidgetTester tester) async {
      await openSection(tester);
      await pickMenu(tester, volumeMenu('Ajin 02'), 'renumber');
      await tester.enterText(find.byType(EditableText).last, '5');
      await tester.pump();
      await tester.tap(find.text(t.dialog_ok).last);
      await settle(tester);
      final MediaTrackingMappingRow? own = await findBook(tester, 'Ajin 02');
      expect(own?.subjectId, 700);
      expect(own?.progressOffset, 5);
      expect(find.text(t.tracking_series_state_own_link), findsNothing);
      expect(
        find.textContaining(t.tracking_series_state_own_link),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Remove series link" asks, then removes it', (
      WidgetTester tester,
    ) async {
      await openSection(tester);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('series-card-tracking-remove-$_site'),
        ),
      );
      await settle(tester, rounds: 4);
      expect(
        find.text(
          t.tracking_series_remove_confirm(series: 'Ajin', site: 'Site a'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(t.tracking_series_remove).last);
      await settle(tester);
      expect(await findSeries(tester, card), isNull);
      expect(
        find.byKey(const ValueKey<String>('series-card-tracking-link-$_site')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Tracking page', () {
    TrackingPage page(TrackingPageTab tab) => TrackingPage(
      service: service,
      database: db,
      onOpenSettings: () {},
      initialTab: tab,
      openSeriesCard: openCard,
    );

    for (final bool apple in <bool>[false, true]) {
      testWidgets('Linked: the series link is the parent of its group row, '
          'which opens onto its volumes (${apple ? 'Apple' : 'Material'})', (
        WidgetTester tester,
      ) async {
        await open(tester);
        late int card;
        late int link;
        await tester.runAsync(() async {
          card = await seriesCard('Ajin', <String>[
            'Ajin 01',
            'Ajin 02',
            'Ajin 03',
          ]);
          link = await seriesLink('$card');
          await repository.addIgnored(
            mediaType: TrackingMediaType.book,
            mediaKey: 'Ajin 03',
            mediaTitle: 'Ajin 03',
          );
        });
        await pumpApp(tester, page(TrackingPageTab.linked), apple: apple);
        final Finder group = find.byType(TrackingLinkGroupRow);
        expect(group, findsOneWidget);
        expect(
          find.descendant(
            of: group,
            matching: find.textContaining(
              'Ajin · ${t.tracking_series_unit_not_counted(volumes: trackingVolumesCount(3), n: '1')}',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byType(TrackingSeriesVolumeRow), findsNothing);
        expect(
          find.byKey(ValueKey<String>('tracking-series-toggle-$link')),
          findsNothing,
          reason: 'no second expand toggle',
        );

        await tester.tap(
          find.byKey(
            const ValueKey<String>('tracking-group-toggle-$_site-700'),
          ),
        );
        await settle(tester, rounds: 4);
        expect(
          find.byKey(ValueKey<String>('tracking-linked-$link')),
          findsOneWidget,
        );
        expect(find.byType(TrackingSeriesVolumeRow), findsNWidgets(3));
        expect(
          find.textContaining(t.tracking_series_state_excluded),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(ValueKey<String>('tracking-series-volume-$link-Ajin 02')),
        );
        await settle(tester, rounds: 2);
        expect(opened, <(int, String)>[(card, 'Ajin 02')]);

        // The search finds the series by a volume's title.
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey<String>('tracking-page-filter')),
            matching: find.byType(EditableText),
          ),
          'Ajin 02',
        );
        await settle(tester, rounds: 2);
        expect(group, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('a series link whose card was deleted: "Series card removed" '
        'under Linked and in Needs attention, removed from there', (
      WidgetTester tester,
    ) async {
      await open(tester);
      late int link;
      await tester.runAsync(() async {
        link = await seriesLink('999', title: 'Gone series');
      });
      await pumpApp(tester, page(TrackingPageTab.linked));
      final Finder row = find.byKey(ValueKey<String>('tracking-linked-$link'));
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining(t.tracking_series_card_removed),
        ),
        findsOneWidget,
      );
      expect(find.byType(TrackingLinkGroupRow), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());

      await pumpApp(tester, page(TrackingPageTab.attention));
      expect(
        find.textContaining(t.tracking_series_card_removed),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('tracking-attention-remove-0')),
      );
      await settle(tester, rounds: 4);
      await tester.tap(find.text(t.media_tracking_page_remove_link).last);
      await settle(tester);
      expect(await tester.runAsync(() => repository.listMappings()), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Needs attention: a volume the series link cannot count opens '
        'its series card', (WidgetTester tester) async {
      await open(tester);
      late int card;
      await tester.runAsync(() async {
        card = await seriesCard('Ajin', <String>[
          'Ajin 01',
          'Ajin 02',
          'Ajin Guidebook',
        ]);
        await seriesLink('$card');
      });
      final List<({MediaTrackingMappingRow link, TrackingSeriesMember member})>
      waiting = (await tester.runAsync(service.seriesVolumesNeedingAttention))!;
      expect(waiting.single.member.bookKey, 'Ajin Guidebook');
      final String reason =
          waiting.single.member.state == TrackingSeriesMemberState.otherSeries
          ? t.tracking_series_attention_other_series
          : t.tracking_series_attention_no_number;
      await pumpApp(tester, page(TrackingPageTab.attention));
      expect(find.textContaining(reason), findsOneWidget);
      await tester.tap(find.byTooltip(t.tracking_series_open_sheet).first);
      await settle(tester, rounds: 4);
      expect(opened, <(int, String)>[(card, 'Ajin Guidebook')]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    group('Needs attention: volume links one series link can replace', () {
      late int card;

      Future<void> openAttention(WidgetTester tester) async {
        await open(tester);
        await tester.runAsync(() async {
          card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
          for (final (String key, int volume) in <(String, int)>[
            ('Ajin 01', 1),
            ('Ajin 02', 2),
          ]) {
            await repository.saveMapping(
              mediaType: TrackingMediaType.book,
              mediaKey: key,
              mediaTitle: key,
              kind: TrackingKind.manga,
              subjectId: 700,
              subjectName: 'Ajin: Demi-Human',
              progressMode: TrackingProgressMode.volume,
              progressOffset: volume,
              provider: _site,
            );
          }
        });
        await pumpApp(tester, page(TrackingPageTab.attention));
      }

      testWidgets('a card that merges them only when the user confirms', (
        WidgetTester tester,
      ) async {
        await openAttention(tester);
        expect(
          find.textContaining(
            t.tracking_series_merge_summary(n: '2', entry: 'Ajin: Demi-Human'),
          ),
          findsOneWidget,
        );
        expect(await findSeries(tester, card), isNull, reason: 'not silently');

        await tester.tap(
          find.byKey(const ValueKey<String>('tracking-attention-merge-0')),
        );
        await settle(tester, rounds: 4);
        // Cancel first: nothing changes.
        await tester.tap(find.text(t.cancel).last);
        await settle(tester);
        expect(await findSeries(tester, card), isNull);

        await tester.tap(
          find.byKey(const ValueKey<String>('tracking-attention-merge-0')),
        );
        await settle(tester, rounds: 4);
        await tester.tap(find.text(t.tracking_series_merge_action).last);
        await settle(tester);
        expect((await findSeries(tester, card))?.subjectId, 700);
        expect(await findBook(tester, 'Ajin 01'), isNull);
        expect(await findBook(tester, 'Ajin 02'), isNull);
        expect(
          find.textContaining(
            t.tracking_series_merge_summary(n: '2', entry: 'Ajin: Demi-Human'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('"Don\'t merge" keeps the volume links and drops the card', (
        WidgetTester tester,
      ) async {
        await openAttention(tester);
        await pickMenu(tester, 'tracking-attention-menu-0', 'ignore');
        expect(
          find.text(t.tracking_series_merge_decline),
          findsNothing,
          reason: 'the menu closed',
        );
        expect(await findSeries(tester, card), isNull);
        expect(await findBook(tester, 'Ajin 01'), isNotNull);
        expect(await tester.runAsync(service.seriesMergeCandidates), isEmpty);
        expect(await tester.runAsync(service.listIgnored), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  });
}
