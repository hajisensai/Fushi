// T2 fix round F5 on the Tracking page and its link dialog: search focus
// (G1), a reopened book link keeps its saved number (G4), number fields
// (G5), the remove confirmation names the item (G8), the "Link an item"
// picker (G10), singular counts (G12), module off (G15).
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/book_tracking_dialog.dart';
import 'package:fushi/src/media/tracking/page/tracking_link_dialog.dart';
import 'package:fushi/src/media/tracking/page/tracking_page.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_rows.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// Anime site with a title search.
final class _AnimeSite implements TrackingProvider, TrackingSubjectSearch {
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => 'anime';

  @override
  String get displayName => 'Anime site';

  @override
  String get siteHost => 'anime.example';

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

  @override
  Future<List<TrackingSearchHit>> searchSubjects(
    String query,
    TrackingKind kind,
  ) async => const <TrackingSearchHit>[
    TrackingSearchHit(
      subjectId: 101,
      name: 'Frieren',
      kind: TrackingKind.anime,
      episodeCount: 1,
    ),
  ];

  @override
  Future<TrackingSearchHit?> subjectById(
    int subjectId,
    TrackingKind kind,
  ) async => null;

  @override
  Uri? subjectPageUrl(int subjectId, TrackingKind kind) => null;
}

/// Book site that plans the unit itself (volume links).
final class _BookSite implements TrackingProvider, TrackingBookLinker {
  final List<TrackingBookSubject> catalogue = <TrackingBookSubject>[
    const TrackingBookSubject(
      subjectId: 77,
      name: 'Ajin',
      kind: TrackingKind.novel,
      finalVolume: 1,
    ),
  ];

  @override
  String get id => 'books';

  @override
  String get displayName => 'Book site';

  @override
  String get siteHost => 'books.example';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.novel, TrackingKind.manga},
        progressModes: <TrackingProgressMode>{
          TrackingProgressMode.chapter,
          TrackingProgressMode.volume,
        },
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
    for (final TrackingBookSubject s in catalogue)
      if (s.kind == kind) s,
  ];

  @override
  Future<TrackingBookSubject?> bookById(int subjectId) async {
    for (final TrackingBookSubject s in catalogue) {
      if (s.subjectId == subjectId) return s;
    }
    return null;
  }

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
  bool trackingOn = true;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    trackingOn = true;
  });

  Future<void> open(WidgetTester tester, List<TrackingProvider> sites) async {
    await tester.runAsync(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      repository = MediaTrackingRepository(db);
      service = MediaTrackingService(
        repository: repository,
        preferences: prefs,
        userAgent: 'test-agent',
        extraProviders: sites,
        trackingOn: () => trackingOn,
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

  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    TrackingPageTab tab = TrackingPageTab.linked,
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
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: TrackingPage(
              service: service,
              database: db,
              onOpenSettings: () {},
              initialTab: tab,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<int> linkVideo(String key, String title, int subject) =>
      repository.saveMapping(
        mediaType: TrackingMediaType.video,
        mediaKey: key,
        mediaTitle: title,
        kind: TrackingKind.anime,
        subjectId: subject,
        subjectName: 'Remote $title',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 1,
        provider: 'anime',
      );

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(EditableText),
  );

  testWidgets('G1: the search box keeps its focus (and its state) when the '
      'list turns empty and back', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    await tester.runAsync(() async {
      await linkVideo('v1', 'Frieren 01', 1);
      await linkVideo('v2', 'Dungeon Meshi 01', 2);
    });
    await pumpPage(tester);
    final Finder search = field('tracking-page-filter');
    await tester.enterText(search, 'fri');
    await settle(tester, rounds: 2);
    final EditableTextState state = tester.state<EditableTextState>(search);
    expect(state.widget.focusNode.hasFocus, isTrue);

    await tester.enterText(search, 'frizzz');
    await settle(tester, rounds: 2);
    expect(
      find.byKey(const ValueKey<String>('tracking-page-filter-empty')),
      findsOneWidget,
    );
    expect(identical(tester.state<EditableTextState>(search), state), isTrue);
    expect(state.widget.focusNode.hasFocus, isTrue);

    // Typed on (no new tap): rows come back, focus stays.
    state.updateEditingValue(const TextEditingValue(text: 'fri'));
    await settle(tester, rounds: 2);
    expect(find.byType(TrackingLinkedRow), findsOneWidget);
    expect(identical(tester.state<EditableTextState>(search), state), isTrue);
    expect(state.widget.focusNode.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('G4 + G5 + G12: a reopened book link shows its saved number; '
      'the number takes digits only and Link waits for a valid one', (
    WidgetTester tester,
  ) async {
    final _BookSite site = _BookSite();
    await open(tester, <TrackingProvider>[site]);
    late int id;
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Ajin 02',
          title: 'Ajin 02',
          epubPath: '/books/ajin02.epub',
          extractDir: '/books/ajin02',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('epub'),
        ),
      );
      id = await repository.saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: 'Ajin 02',
        mediaTitle: 'Ajin 02',
        kind: TrackingKind.novel,
        subjectId: 77,
        subjectName: 'Ajin',
        progressMode: TrackingProgressMode.volume,
        progressOffset: 1,
        provider: 'books',
      );
    });
    await pumpPage(tester);
    await tester.tap(find.byKey(ValueKey<String>('tracking-linked-$id')));
    await settle(tester, rounds: 20);
    expect(find.byType(TrackingLinkDialog), findsOneWidget);
    // G12: one volume, not "1 volumes".
    expect(find.textContaining('1 volume ·'), findsOneWidget);
    expect(find.textContaining('1 volumes'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-result-77')),
    );
    await settle(tester, rounds: 12);
    final Finder number = field('tracking-link-book-number');
    // G4: the saved number (1), not the planned one ("02" = 2).
    expect(tester.widget<EditableText>(number).controller.text, '1');

    FushiFilledButton linkButton() => tester.widget<FushiFilledButton>(
      find.byKey(const ValueKey<String>('tracking-link-save')),
    );
    await tester.enterText(number, '1ab-0.5x');
    await settle(tester, rounds: 2);
    expect(tester.widget<EditableText>(number).controller.text, '105');
    await tester.enterText(number, 'abc');
    await settle(tester, rounds: 2);
    expect(tester.widget<EditableText>(number).controller.text, '');
    expect(linkButton().onPressed, isNull);
    expect(
      find.text(t.media_tracking_link_number_invalid(min: '1')),
      findsOneWidget,
    );
    await tester.enterText(number, '0');
    await settle(tester, rounds: 2);
    expect(linkButton().onPressed, isNull);
    await tester.enterText(number, '3');
    await settle(tester, rounds: 2);
    expect(linkButton().onPressed, isNotNull);
    expect(find.text(t.media_tracking_link_offset_helper_volume), findsOne);
    await tester.tap(find.byKey(const ValueKey<String>('tracking-link-save')));
    await settle(tester, rounds: 20);
    final MediaTrackingMappingRow? saved = await tester
        .runAsync<MediaTrackingMappingRow?>(
          () => repository.findMapping(
            mediaType: TrackingMediaType.book,
            mediaKey: 'Ajin 02',
            provider: 'books',
          ),
        );
    expect(saved?.progressOffset, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('G5: a wrong starting number blocks the one-click link', (
    WidgetTester tester,
  ) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    late int id;
    await tester.runAsync(() async {
      id = await linkVideo('v1', 'Frieren 01', 7);
    });
    await pumpPage(tester);
    await tester.tap(find.byKey(ValueKey<String>('tracking-linked-$id')));
    await settle(tester, rounds: 20);
    await tester.enterText(field('tracking-link-offset'), '0');
    await settle(tester, rounds: 2);
    expect(
      find.text(t.media_tracking_link_number_invalid(min: '1')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-result-101')),
    );
    await settle(tester, rounds: 12);
    expect(find.byType(TrackingLinkDialog), findsOneWidget);
    expect(
      (await tester.runAsync(repository.listMappings))!.single.subjectId,
      7,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('G10: "Link an item" searches the library and names each '
      "item's kind like the page", (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    await tester.runAsync(() async {
      for (final (String uid, String title) in <(String, String)>[
        ('d1', 'How.Dare.You.S01E01.1080p'),
        ('a1', 'Frieren 01'),
      ]) {
        await db.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: uid,
            title: title,
            videoPath: '/v/$uid.mkv',
          ),
        );
      }
      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: 'd1',
          source: 'tmdb',
          subjectId: '1',
          title: 'How Dare You!!',
          tagsJson: const Value<String?>('[{"name":"Drama"}]'),
          scrapedAt: DateTime(2026),
        ),
      );
    });
    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-page-link-item')),
    );
    await settle(tester, rounds: 20);
    final Finder drama = find.byKey(
      const ValueKey<String>('tracking-link-local-video-d1'),
    );
    expect(drama, findsOneWidget);
    expect(
      find.descendant(
        of: drama,
        matching: find.text(t.media_tracking_kind_live_action),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-link-local-video-a1')),
        matching: find.text(t.media_tracking_kind_video),
      ),
      findsOneWidget,
    );
    // Nothing chosen yet: no site search ran for a guessed item.
    expect(
      find.byKey(const ValueKey<String>('tracking-link-query')),
      findsNothing,
    );
    await tester.enterText(field('tracking-link-local-search'), 'dare');
    await settle(tester, rounds: 2);
    expect(
      find.byKey(const ValueKey<String>('tracking-link-local-video-a1')),
      findsNothing,
    );
    await tester.tap(drama);
    await settle(tester, rounds: 20);
    expect(
      find.byKey(const ValueKey<String>('tracking-link-local-chosen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-link-query')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('"Link an item" marks the current link of the chosen item like '
      'its own row does', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    await tester.runAsync(() async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'a1',
          title: 'Frieren 01',
          videoPath: '/v/a1.mkv',
        ),
      );
      await linkVideo('a1', 'Frieren 01', 101);
    });
    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-page-link-item')),
    );
    await settle(tester, rounds: 20);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-local-video-a1')),
    );
    await settle(tester, rounds: 20);
    expect(
      find.byKey(const ValueKey<String>('tracking-link-current')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('"Link an item" keeps its size when typing hides the "N more" '
      'line', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    await tester.runAsync(() async {
      for (int i = 0; i < 40; i++) {
        await db.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: 'v$i',
            title: 'Show $i',
            videoPath: '/v/v$i.mkv',
          ),
        );
      }
    });
    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-page-link-item')),
    );
    await settle(tester, rounds: 20);
    final Finder more = find.text(t.media_tracking_link_local_more(n: '10'));
    expect(more, findsOneWidget);
    // The dialog is centred: shrinking moves its content up.
    final Finder search = find.byKey(
      const ValueKey<String>('tracking-link-local-search'),
    );
    final Offset before = tester.getTopLeft(search);
    await tester.enterText(field('tracking-link-local-search'), 'Show 1');
    await settle(tester, rounds: 4);
    expect(more.hitTestable(), findsNothing);
    expect(tester.getTopLeft(search), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('G8: the remove confirmation names the item', (
    WidgetTester tester,
  ) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    late int id;
    await tester.runAsync(() async {
      id = await linkVideo('v1', 'Frieren 01', 7);
    });
    await pumpPage(tester);
    // The raw local name (what the grouped child row shows), so S1E1 and
    // S1E2 differ; the cleaned title only when there is no raw name.
    final TrackingLinkedEntry linkedEntry = tester
        .widget<TrackingLinkedRow>(find.byType(TrackingLinkedRow))
        .entry;
    final String title = linkedEntry.rawName ?? linkedEntry.title;
    await tester.tap(
      find.byKey(ValueKey<String>('tracking-linked-remove-$id')),
    );
    await settle(tester, rounds: 6);
    expect(
      find.text(
        t.media_tracking_page_remove_confirm_item(
          title: title,
          site: 'Anime site',
        ),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('G14: the Track sheet badge of a link whose series is not '
      'tracked says so instead of "Linked"', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[_BookSite()]);
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Ajin 02',
          title: 'Ajin 02',
          epubPath: '/books/ajin02.epub',
          extractDir: '/books/ajin02',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('epub'),
        ),
      );
      final int series = await db.createMediaCollection('Ajin');
      await db.addToCollection(series, MediaKind.epub, 'Ajin 02');
      await repository.saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: 'Ajin 02',
        mediaTitle: 'Ajin 02',
        kind: TrackingKind.novel,
        subjectId: 77,
        subjectName: 'Ajin',
        progressMode: TrackingProgressMode.volume,
        progressOffset: 2,
        provider: 'books',
      );
      await service.ignoreItem(
        mediaType: TrackingMediaType.bookCollection,
        mediaKey: '$series',
        mediaTitle: 'Ajin',
      );
    });
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
            home: Scaffold(
              body: BookTrackingDialog(service: service, bookKey: 'Ajin 02'),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    final Finder badge = find.byKey(
      const ValueKey<String>('book-tracking-site-badge'),
    );
    expect(
      find.descendant(
        of: badge,
        matching: find.text(t.media_tracking_ignore_paused),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: badge,
        matching: find.text(t.media_tracking_track_linked),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('G15: the module turned off while the page is open leaves '
      'nothing to use', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[_AnimeSite()]);
    await tester.runAsync(() => linkVideo('v1', 'Frieren 01', 7));
    await pumpPage(tester);
    expect(find.byType(TrackingLinkedRow), findsOneWidget);
    trackingOn = false;
    service.notifyStatusChanged();
    await settle(tester, rounds: 6);
    expect(find.byKey(const ValueKey<String>('tracking-page-off')), findsOne);
    expect(find.byType(TrackingLinkedRow), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('tracking-page-link-item')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
