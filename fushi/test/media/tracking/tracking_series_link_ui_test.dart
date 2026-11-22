// Series-level book links in the UI (design notes section E, point 2): the
// Track sheet of a volume counted by its series card's link, the "Whole
// series" / "Only this volume" choice when linking, and the Tracking page's
// series rows (volumes, card removed, volumes needing attention). Real
// tracking service, in-memory database, a stand-in book site.
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

  group('Track sheet of a volume counted by a series link', () {
    late int card;

    Future<void> openSheet(WidgetTester tester, {bool apple = false}) async {
      await open(tester);
      await tester.runAsync(() async {
        card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
        await seriesLink('$card');
      });
      await pumpApp(
        tester,
        Scaffold(
          body: BookTrackingDialog(service: service, bookKey: 'Ajin 02'),
        ),
        apple: apple,
      );
    }

    for (final bool apple in <bool>[false, true]) {
      testWidgets('"Tracked with the series", no search until "Link this '
          'volume separately" (${apple ? 'Apple' : 'Material'})', (
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
        final Finder search = find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiIconButton &&
              widget.tooltip == t.media_tracking_track_search,
        );
        expect(search, findsNothing, reason: 'counted by the series link');
        // No "whole series" choice: the site has a series link already.
        expect(
          find.byKey(const ValueKey<String>('book-tracking-scope-$_site')),
          findsNothing,
        );

        await tester.tap(button('book-tracking-series-separate'));
        await settle(tester, rounds: 2);
        expect(search, findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('book-tracking-scope-$_site')),
          findsNothing,
          reason: 'linking separately links this volume only',
        );
        await tester.tap(search);
        await settle(tester);
        await tester.tap(find.text(t.media_tracking_track_approve).first);
        await settle(tester);
        final MediaTrackingMappingRow? own = await findBook(tester, 'Ajin 02');
        expect(own?.subjectId, 1);
        expect(
          (await findSeries(tester, card))?.subjectId,
          700,
          reason: 'kept',
        );
        expect(
          find.byKey(
            const ValueKey<String>('book-tracking-series-own-link-$_site'),
          ),
          findsOneWidget,
        );
        expect(find.text(t.tracking_series_state_own_link), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('"Don\'t count this volume" lists the volume as not tracked; '
        '"Count again" takes it off', (WidgetTester tester) async {
      await openSheet(tester);
      await tester.tap(button('book-tracking-series-exclude'));
      await settle(tester);
      final List<MediaTrackingIgnoredRow> ignored = (await tester.runAsync(
        service.listIgnored,
      ))!;
      expect(ignored.single.mediaType, TrackingMediaType.book.value);
      expect(ignored.single.mediaKey, 'Ajin 02');
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('book-tracking-series-reason-$_site'),
          ),
          matching: find.text(t.tracking_series_state_excluded),
        ),
        findsOneWidget,
      );
      expect(find.text(t.tracking_series_badge_not_counted), findsOneWidget);

      await tester.tap(button('book-tracking-series-count-again'));
      await settle(tester);
      expect(await tester.runAsync(service.listIgnored), isEmpty);
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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Change volume number" gives the volume its own link to the '
        'series entry with that number', (WidgetTester tester) async {
      await openSheet(tester);
      await tester.tap(button('book-tracking-series-renumber'));
      await settle(tester, rounds: 4);
      await tester.enterText(find.byType(EditableText).last, '5');
      await tester.pump();
      await tester.tap(find.text(t.dialog_ok).last);
      await settle(tester);
      final MediaTrackingMappingRow? own = await findBook(tester, 'Ajin 02');
      expect(own?.subjectId, 700);
      expect(own?.progressOffset, 5);
      expect(own?.progressMode, TrackingProgressMode.volume.value);
      expect(find.text(t.tracking_series_state_own_link), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Remove series link" asks, then removes the series link', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);
      await tester.tap(button('book-tracking-series-remove'));
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
        find.byKey(const ValueKey<String>('book-tracking-series-$_site')),
        findsNothing,
      );
      expect(find.text(t.media_tracking_track_not_linked), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('linking a volume of a series card', () {
    late int card;

    Future<void> openSheet(WidgetTester tester, {bool apple = false}) async {
      await open(tester);
      await tester.runAsync(() async {
        card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
      });
      await pumpApp(
        tester,
        Scaffold(
          body: BookTrackingDialog(service: service, bookKey: 'Ajin 01'),
        ),
        apple: apple,
      );
    }

    Future<void> searchAndLink(WidgetTester tester) async {
      await tester.tap(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiIconButton &&
              widget.tooltip == t.media_tracking_track_search,
        ),
      );
      await settle(tester);
      await tester.tap(find.text(t.media_tracking_track_approve).first);
      await settle(tester);
    }

    for (final bool apple in <bool>[false, true]) {
      testWidgets('"Whole series" is the default: a search result links the '
          'series card (${apple ? 'Apple' : 'Material'})', (
        WidgetTester tester,
      ) async {
        await openSheet(tester, apple: apple);
        expect(
          find.byKey(const ValueKey<String>('book-tracking-scope-$_site')),
          findsOneWidget,
        );
        expect(
          find.text(t.tracking_series_scope_whole(series: 'Ajin')),
          findsOneWidget,
        );
        await searchAndLink(tester);
        final MediaTrackingMappingRow? series = await findSeries(tester, card);
        expect(series?.subjectId, 1);
        expect(series?.progressMode, TrackingProgressMode.volume.value);
        expect(series?.progressOffset, 0);
        expect(await findBook(tester, 'Ajin 01'), isNull);
        expect(
          find.text(
            t.tracking_series_tracked_with(
              series: 'Ajin',
              site: 'Site a',
              volume: '1',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('"Only this volume" links the volume alone', (
      WidgetTester tester,
    ) async {
      await openSheet(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('book-tracking-scope-volume-$_site')),
      );
      await settle(tester, rounds: 2);
      await searchAndLink(tester);
      expect((await findBook(tester, 'Ajin 01'))?.subjectId, 1);
      expect(await findSeries(tester, card), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('approving a suggestion for the whole series keeps its '
        'source and score', (WidgetTester tester) async {
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
          body: BookTrackingDialog(service: service, bookKey: 'Ajin 01'),
        ),
      );
      expect(find.text(t.media_tracking_track_suggestions), findsOneWidget);
      await tester.tap(find.text(t.media_tracking_track_approve).first);
      await settle(tester);
      final MediaTrackingMappingRow? series = await findSeries(tester, card);
      expect(series?.subjectId, 42);
      expect(series?.linkSource, TrackingLinkSource.suggestion);
      expect(series?.confidence, closeTo(0.8, 1e-9));
      expect(await findBook(tester, 'Ajin 01'), isNull);
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
    );

    for (final bool apple in <bool>[false, true]) {
      testWidgets('Linked: a series row names the card, counts its volumes '
          'and opens to them (${apple ? 'Apple' : 'Material'})', (
        WidgetTester tester,
      ) async {
        await open(tester);
        late int link;
        await tester.runAsync(() async {
          final int card = await seriesCard('Ajin', <String>[
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
        final Finder row = find.byKey(
          ValueKey<String>('tracking-linked-$link'),
        );
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text('Ajin')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.textContaining(
              t.tracking_series_unit_not_counted(
                volumes: trackingVolumesCount(3),
                n: '1',
              ),
            ),
          ),
          findsOneWidget,
        );
        expect(find.byType(TrackingSeriesVolumeRow), findsNothing);

        await tester.tap(
          find.byKey(ValueKey<String>('tracking-series-toggle-$link')),
        );
        await settle(tester, rounds: 4);
        expect(find.byType(TrackingSeriesVolumeRow), findsNWidgets(3));
        expect(
          find.textContaining(
            '${t.media_tracking_track_by_volume(volume: '2')} · '
            '${t.tracking_series_state_counted}',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(t.tracking_series_state_excluded),
          findsOneWidget,
        );

        // The search finds the series by a volume's title.
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey<String>('tracking-page-filter')),
            matching: find.byType(EditableText),
          ),
          'Ajin 02',
        );
        await settle(tester, rounds: 2);
        expect(row, findsOneWidget);
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
      expect(
        find.byKey(ValueKey<String>('tracking-series-toggle-$link')),
        findsNothing,
      );
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
        'its Track sheet', (WidgetTester tester) async {
      await open(tester);
      await tester.runAsync(() async {
        final int card = await seriesCard('Ajin', <String>[
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
      await settle(tester, rounds: 16);
      expect(find.byType(BookTrackingDialog), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('book-tracking-series-reason-$_site'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
