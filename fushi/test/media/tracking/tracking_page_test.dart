// The Tracking page and its link dialog (night plan decisions 2 and 3),
// with the real tracking service, an in-memory database and stand-in sites.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/book_tracking_dialog.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_link_dialog.dart';
import 'package:fushi/src/media/tracking/page/tracking_local_targets.dart';
import 'package:fushi/src/media/tracking/page/tracking_page.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_rows.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiListLeadingIcon;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiOverflowMenu;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiTextButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';
import 'package:material_ui/material_ui.dart';

import '../../../integration_test/helpers/focus_driver.dart';
import '../../helpers/test_platform_services.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in site that searches a fixed list and records what it sends.
final class _StandInSite implements TrackingProvider, TrackingSubjectSearch {
  _StandInSite(
    this.id, {
    required this.kinds,
    Set<TrackingKind>? defaultKinds,
    this.results = const <TrackingSearchHit>[],
  }) : _defaultKinds = defaultKinds;

  @override
  final String id;
  final Set<TrackingKind> kinds;
  final Set<TrackingKind>? _defaultKinds;
  final List<TrackingSearchHit> results;
  final List<String> queries = <String>[];
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get displayName => 'Site $id';

  @override
  String get siteHost => '$id.example';

  @override
  TrackingProviderCapabilities get capabilities => TrackingProviderCapabilities(
    kinds: kinds,
    progressModes: const <TrackingProgressMode>{
      TrackingProgressMode.episode,
      TrackingProgressMode.chapter,
      TrackingProgressMode.volume,
    },
    onByDefault: _defaultKinds,
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
  ) async {
    queries.add(query);
    return <TrackingSearchHit>[
      for (final TrackingSearchHit hit in results)
        if (hit.kind == kind) hit,
    ];
  }

  @override
  Future<TrackingSearchHit?> subjectById(
    int subjectId,
    TrackingKind kind,
  ) async {
    for (final TrackingSearchHit hit in results) {
      if (hit.subjectId == subjectId && hit.kind == kind) return hit;
    }
    return null;
  }

  @override
  Uri? subjectPageUrl(int subjectId, TrackingKind kind) =>
      Uri.parse('https://$siteHost/$subjectId');
}

/// Bangumi with only search and lookup.
final class _BangumiSearchApi implements BangumiTrackingApi {
  final List<int> searchedTypes = <int>[];

  static const BangumiSubject _game = BangumiSubject(
    id: 55,
    type: 4,
    name: 'Some game',
    nameCn: '某游戏',
    platform: 'PC',
    episodeCount: 0,
    volumeCount: 0,
  );

  @override
  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  }) async {
    searchedTypes.add(subjectType);
    return const <BangumiSubject>[_game];
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async => _game;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const TrackingSearchHit _frieren = TrackingSearchHit(
  subjectId: 101,
  name: 'Sousou no Frieren',
  altName: 'Frieren: Beyond Journey’s End',
  kind: TrackingKind.anime,
  episodeCount: 28,
);

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late MediaTrackingService service;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

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

  Future<void> seedVideo(String uid, String title) => db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: title,
      videoPath: '/anime/$uid.mkv',
      completedAt: Value<DateTime?>(DateTime.fromMillisecondsSinceEpoch(2000)),
    ),
  );

  Future<void> seedGame() => db.upsertGalgame(
    GalgamesCompanion.insert(
      id: 'game',
      name: 'Some game',
      exePath: '/games/game.exe',
      workdir: '/games',
      addedAt: 1000,
      playStatus: const Value<int>(2),
    ),
  );

  Future<void> link(
    String provider,
    String key,
    String title,
    TrackingKind kind, {
    TrackingMediaType type = TrackingMediaType.video,
    int? subjectId,
  }) => repository.saveMapping(
    mediaType: type,
    mediaKey: key,
    mediaTitle: title,
    kind: kind,
    // Each item its own site entry unless a test groups them (T1 F21).
    subjectId: subjectId ?? 1000 + key.hashCode % 100000,
    subjectName: 'Remote $title',
    progressMode: kind == TrackingKind.anime
        ? TrackingProgressMode.episode
        : TrackingProgressMode.volume,
    progressOffset: 1,
    provider: provider,
  );

  TrackingPage page() =>
      TrackingPage(service: service, database: db, onOpenSettings: () {});

  for (final bool apple in <bool>[false, true]) {
    testWidgets('three groups: sign-in, failed send, item to link; a game is '
        'not listed without a game site (${apple ? 'Apple' : 'Material'})', (
      WidgetTester tester,
    ) async {
      final _StandInSite anime = _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime},
      );
      final _StandInSite manga = _StandInSite(
        'b',
        kinds: <TrackingKind>{TrackingKind.manga},
      );
      await open(tester, <TrackingProvider>[anime, manga]);
      await tester.runAsync(() async {
        await seedVideo('v1', 'Frieren 01');
        await seedVideo('v2', 'Dungeon Meshi 01');
        await seedGame();
        await link('a', 'v2', 'Dungeon Meshi 01', TrackingKind.anime);
        await repository.enqueueProgress(
          mediaType: TrackingMediaType.video,
          mediaKey: 'v2',
          localProgress: 0,
          completed: false,
          provider: 'a',
        );
        final PendingTrackingUpdate queued = (await repository.allPending(
          provider: 'a',
        )).single;
        await repository.markFailed(queued.outbox, 'HTTP 500 boom');
        await prefs.setPref(
          TrackingProviderPrefKeys.forProvider('b').lastSyncUnauthorized,
          true,
        );
      });
      await pumpApp(tester, page(), apple: apple);

      expect(tester.takeException(), isNull);
      // Something needs attention: the page opens on that tab.
      expect(
        find.text(t.media_tracking_page_sign_in_row(site: 'Site b')),
        findsOneWidget,
      );
      expect(find.text('Frieren 01'), findsOneWidget);
      expect(find.textContaining('HTTP 500 boom'), findsOneWidget);
      expect(find.text('Some game'), findsNothing);
      // T1 F19: the status icon of a row to link is not the link button's
      // glyph (Apple maps "link off" to the plain link), and the row menu
      // uses the presentation's own overflow glyph.
      final Finder toLink = find.ancestor(
        of: find.text('Frieren 01'),
        matching: find.byType(TrackingAttentionRow),
      );
      final IconData status = tester
          .widget<FushiListLeadingIcon>(
            find.descendant(
              of: toLink,
              matching: find.byType(FushiListLeadingIcon),
            ),
          )
          .icon;
      expect(status, apple ? FushiIcons.help : FushiIcons.linkOff);
      expect(
        tester
            .widget<FushiOverflowMenu<String>>(
              find.descendant(
                of: toLink,
                matching: find.byType(FushiOverflowMenu<String>),
              ),
            )
            .icon,
        apple ? FushiIcons.moreHoriz : FushiIcons.more,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-page-site-a')),
        findsOneWidget,
      );

      // The Apple segments draw their own labels: find the tab by its text.
      await tester.tap(find.text('${t.media_tracking_page_tab_linked} (1)'));
      await settle(tester, rounds: 3);
      expect(find.byType(TrackingLinkedRow), findsOneWidget);
      expect(find.text('Dungeon Meshi 01'), findsOneWidget);
      expect(find.text('Frieren 01'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('no site connected: empty state with a way to settings', (
    WidgetTester tester,
  ) async {
    int opened = 0;
    await open(tester, const <TrackingProvider>[]);
    await tester.runAsync(() => seedVideo('v1', 'Frieren 01'));
    await pumpApp(
      tester,
      TrackingPage(
        service: service,
        database: db,
        onOpenSettings: () => opened++,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-page-no-site')),
      findsOneWidget,
    );
    expect(find.text('Frieren 01'), findsNothing);
    await tester.tap(find.text(t.settings).last);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('kind filter and title search on the Linked tab', (
    WidgetTester tester,
  ) async {
    await open(tester, <TrackingProvider>[
      _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime, TrackingKind.manga},
      ),
    ]);
    await tester.runAsync(() async {
      await link('a', 'v1', 'Frieren 01', TrackingKind.anime);
      await link('a', 'v2', 'Dungeon Meshi 01', TrackingKind.anime);
      await link(
        'a',
        'm1',
        'Ajin 01',
        TrackingKind.manga,
        type: TrackingMediaType.book,
      );
    });
    await pumpApp(
      tester,
      TrackingPage(
        service: service,
        database: db,
        onOpenSettings: () {},
        initialTab: TrackingPageTab.linked,
      ),
    );
    expect(find.byType(TrackingLinkedRow), findsNWidgets(3));

    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-page-kind-manga')),
    );
    await settle(tester, rounds: 2);
    expect(find.byType(TrackingLinkedRow), findsOneWidget);
    expect(find.text('Ajin 01'), findsOneWidget);

    // Off again: every kind.
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-page-kind-manga')),
    );
    await settle(tester, rounds: 2);
    expect(find.byType(TrackingLinkedRow), findsNWidgets(3));

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-page-filter')),
        matching: find.byType(EditableText),
      ),
      'frie',
    );
    await settle(tester, rounds: 2);
    expect(find.byType(TrackingLinkedRow), findsOneWidget);
    expect(find.text('Frieren 01'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-page-filter')),
        matching: find.byType(EditableText),
      ),
      'nothing like this',
    );
    await settle(tester, rounds: 2);
    expect(
      find.byKey(const ValueKey<String>('tracking-page-filter-empty')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('2,000 links: one frame builds only the visible rows', (
    WidgetTester tester,
  ) async {
    await open(tester, <TrackingProvider>[
      _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
    ]);
    await tester.runAsync(() async {
      for (int i = 0; i < 2000; i++) {
        await link('a', 'v$i', 'Title $i', TrackingKind.anime);
      }
    });
    await pumpApp(
      tester,
      TrackingPage(
        service: service,
        database: db,
        onOpenSettings: () {},
        initialTab: TrackingPageTab.linked,
      ),
    );
    final int built = find.byType(TrackingLinkedRow).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(100));
    expect(
      find.text('${t.media_tracking_page_tab_linked} (2000)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('link dialog', () {
    const MediaTrackingLocalTarget video = MediaTrackingLocalTarget(
      type: TrackingMediaType.video,
      key: 'v1',
      title: 'Frieren 01',
    );

    /// A page with a button that opens the dialog the way the app does.
    Widget dialog({VoidCallback? onOpenSettings}) => Scaffold(
      body: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showTrackingLinkDialog(
            context,
            service: service,
            database: db,
            item: video,
            onOpenSettings: onOpenSettings,
          ),
          child: const Text('open'),
        ),
      ),
    );

    Future<void> openDialog(
      WidgetTester tester, {
      VoidCallback? onOpenSettings,
    }) async {
      await pumpApp(tester, dialog(onOpenSettings: onOpenSettings));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byType(TrackingLinkDialog), findsOneWidget);
    }

    testWidgets('two eligible sites: a picker, the default site chosen', (
      WidgetTester tester,
    ) async {
      final _StandInSite other = _StandInSite(
        'c',
        kinds: <TrackingKind>{TrackingKind.anime},
        defaultKinds: const <TrackingKind>{},
      );
      final _StandInSite main = _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime},
        results: const <TrackingSearchHit>[_frieren],
      );
      // The default site is registered second: it is still preselected.
      await open(tester, <TrackingProvider>[other, main]);
      // Anime is off by default on a site that is not its default.
      await tester.runAsync(
        () => service.setKindEnabled('c', TrackingKind.anime, true),
      );
      await openDialog(tester);
      expect(
        find.byKey(const ValueKey<String>('tracking-link-site-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-link-site-c')),
        findsOneWidget,
      );
      // The pre-fill is the cleaned title: the trailing episode number goes.
      expect(main.queries, <String>['Frieren']);
      // T1 F19: the dialog is drawn on the filled field's colour, so the
      // fields are outlined (visible) in Material.
      final InputDecorator query = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('tracking-link-query')),
          matching: find.byType(InputDecorator),
        ),
      );
      expect(
        query.decoration.enabledBorder?.borderSide.style,
        BorderStyle.solid,
      );
      expect(query.decoration.enabledBorder!.borderSide.width, greaterThan(0));
      expect(other.queries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('one eligible site: no picker; a manga-only site does not '
        'count', (WidgetTester tester) async {
      await open(tester, <TrackingProvider>[
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
        _StandInSite('b', kinds: <TrackingKind>{TrackingKind.manga}),
      ]);
      await openDialog(tester);
      expect(
        find.byKey(const ValueKey<String>('tracking-link-site-a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-link-site-b')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-link-query')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-link-no-site')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('no eligible site: says what to do, leads to settings', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      await open(tester, <TrackingProvider>[
        _StandInSite('b', kinds: <TrackingKind>{TrackingKind.manga}),
      ]);
      await openDialog(tester, onOpenSettings: () => opened++);
      expect(
        find.byKey(const ValueKey<String>('tracking-link-no-site')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-link-query')),
        findsNothing,
      );
      await tester.tap(find.text(t.settings));
      await settle(tester, rounds: 2);
      expect(opened, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('without a Bangumi token: search, pick, the link is saved on '
        'the chosen site and the progress is sent', (
      WidgetTester tester,
    ) async {
      final _StandInSite site = _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime},
        results: const <TrackingSearchHit>[_frieren],
      );
      await open(tester, <TrackingProvider>[site]);
      await tester.runAsync(() => seedVideo('v1', 'Frieren 01'));
      expect(service.isConfigured, isFalse, reason: 'no Bangumi token');
      await openDialog(tester);
      expect(find.text('Sousou no Frieren'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('tracking-link-result-101')),
      );
      await settle(tester, rounds: 20);

      late final MediaTrackingMappingRow? saved;
      await tester.runAsync(() async {
        saved = await repository.findMapping(
          mediaType: TrackingMediaType.video,
          mediaKey: 'v1',
          provider: 'a',
        );
      });
      expect(saved, isNotNull);
      expect(saved!.subjectId, 101);
      expect(saved!.kind, TrackingKind.anime.value);
      expect(saved!.progressMode, TrackingProgressMode.episode.value);
      expect(saved!.progressOffset, 1);
      expect(saved!.linkSource, 'manual');
      // T2 G2: nothing goes out while Undo is offered; it goes when the
      // page lets it go (here no page: as when it closes).
      expect(site.pushed, isEmpty, reason: 'held for the Undo window');
      await tester.runAsync(service.releaseAllLinkHolds);
      await settle(tester, rounds: 4);
      expect(site.pushed, isNotEmpty, reason: 'the watched episode went out');
      expect(site.pushed.last.mapping.id, saved!.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('service', () {
    testWidgets('Bangumi searches through the same interface (games)', (
      WidgetTester tester,
    ) async {
      final _BangumiSearchApi api = _BangumiSearchApi();
      await tester.runAsync(() async {
        db = FushiDatabase.forTesting(NativeDatabase.memory());
        prefs = PreferencesRepository(db);
        await prefs.loadFromDb();
        await prefs.setPref(kBangumiAccessTokenPref, 'token');
        service = MediaTrackingService(
          repository: MediaTrackingRepository(db),
          preferences: prefs,
          userAgent: 'test-agent',
          apiFactory: (String _) => api,
        );
      });
      addTearDown(() async {
        service.dispose();
        await tester.runAsync(() async {
          prefs.dispose();
          await db.close();
        });
      });
      expect(
        service
            .manualLinkSitesFor(TrackingKind.game)
            .map((TrackingProvider p) => p.id),
        <String>[kTrackingProviderBangumi],
      );
      late final List<TrackingSearchHit> hits;
      late final List<TrackingSearchHit> byId;
      await tester.runAsync(() async {
        hits = await service.searchSiteSubjects(
          providerId: kTrackingProviderBangumi,
          kind: TrackingKind.game,
          query: 'Some game',
        );
        byId = await service.searchSiteSubjects(
          providerId: kTrackingProviderBangumi,
          kind: TrackingKind.game,
          query: 'https://bgm.tv/subject/55',
        );
      });
      expect(api.searchedTypes, <int>[4]);
      expect(hits.single.name, '某游戏');
      expect(hits.single.altName, 'Some game');
      expect(byId.single.subjectId, 55);
      expect(
        service.subjectPageUrl(kTrackingProviderBangumi, 55, TrackingKind.game),
        Uri.parse('https://bgm.tv/subject/55'),
      );
    });

    testWidgets('a media server episode relinked by hand is sent again', (
      WidgetTester tester,
    ) async {
      final _StandInSite site = _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime},
      );
      await open(tester, <TrackingProvider>[site]);
      await tester.runAsync(() async {
        await service.linkItemToSubject(
          mediaType: TrackingMediaType.remoteVideo,
          mediaKey: 'jellyfin:u:ep3',
          mediaTitle: 'Frieren S1E3',
          kind: TrackingKind.anime,
          providerId: 'a',
          hit: _frieren,
          progressMode: TrackingProgressMode.episode,
          progressOffset: 3,
        );
      });
      expect(site.pushed, hasLength(1));
      expect(site.pushed.single.mapping.mediaType, 'remote_video');
      expect(site.pushed.single.mapping.progressOffset, 3);
    });

    testWidgets('only signed-in sites that track the kind can link it, '
        'default first', (WidgetTester tester) async {
      await open(tester, <TrackingProvider>[
        _StandInSite(
          'c',
          kinds: <TrackingKind>{TrackingKind.anime},
          defaultKinds: const <TrackingKind>{},
        ),
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
        _StandInSite('b', kinds: <TrackingKind>{TrackingKind.manga}),
      ]);
      expect(
        service
            .manualLinkSitesFor(TrackingKind.anime)
            .map((TrackingProvider p) => p.id),
        <String>['a'],
        reason: 'anime is off by default on c',
      );
      await tester.runAsync(() async {
        await service.setKindEnabled('c', TrackingKind.anime, true);
        // Turning a kind on starts a sync: let it end before the database.
        await service.syncNow();
      });
      expect(
        <String>[
          for (final TrackingProvider p in service.manualLinkSitesFor(
            TrackingKind.anime,
          ))
            p.id,
        ],
        <String>['a', 'c'],
      );
      expect(service.manualLinkSitesFor(TrackingKind.game), isEmpty);
      // Bangumi has no token: not offered.
      expect(
        service
            .manualLinkSitesFor(TrackingKind.manga)
            .map((TrackingProvider p) => p.id),
        <String>['b'],
      );
    });
  });

  for (final bool apple in <bool>[false, true]) {
    testWidgets('"Don\'t track" from both tabs, the Ignored view and "Track '
        'again" (${apple ? 'Apple' : 'Material'})', (
      WidgetTester tester,
    ) async {
      await open(tester, <TrackingProvider>[
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
      ]);
      await tester.runAsync(() async {
        await seedVideo('v1', 'Frieren 01');
        await seedVideo('v2', 'Dungeon Meshi 01');
        await link('a', 'v2', 'Dungeon Meshi 01', TrackingKind.anime);
      });
      await pumpApp(tester, page(), apple: apple);
      expect(find.text('Frieren 01'), findsOneWidget);

      // Needs attention: the row menu puts the item on the list.
      await tester.tap(
        find.byKey(const ValueKey<String>('tracking-attention-menu-0')),
      );
      await settle(tester, rounds: 3);
      await tester.tap(find.text(t.media_tracking_ignore_action).last);
      await settle(tester);
      expect(find.text('Frieren 01'), findsNothing);
      // T1 F13: the notice offers Undo.
      expect(find.text(t.media_tracking_ignore_undo), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('tracking-page-attention-empty')),
        findsOneWidget,
      );

      await tester.tap(find.text('${t.media_tracking_page_tab_ignored} (1)'));
      await settle(tester, rounds: 3);
      expect(find.byType(TrackingIgnoredRow), findsOneWidget);
      expect(find.text('Frieren 01'), findsOneWidget);

      // Linked: the link is kept but paused.
      await tester.tap(find.text('${t.media_tracking_page_tab_linked} (1)'));
      await settle(tester, rounds: 3);
      await tester.tap(find.byType(TrackingRowMenu).first);
      await settle(tester, rounds: 3);
      await tester.tap(find.text(t.media_tracking_ignore_action).last);
      await settle(tester);
      expect(
        find.textContaining(t.media_tracking_ignore_paused),
        findsOneWidget,
      );
      await tester.tap(find.byType(TrackingRowMenu).first);
      await settle(tester, rounds: 3);
      expect(find.text(t.media_tracking_ignore_undo_action), findsWidgets);
      await tester.tapAt(const Offset(4, 4));
      await settle(tester, rounds: 3);

      // Ignored: "Track again" undoes both.
      await tester.tap(find.text('${t.media_tracking_page_tab_ignored} (2)'));
      await settle(tester, rounds: 3);
      expect(find.byType(TrackingIgnoredRow), findsNWidgets(2));
      final Finder undo = find.byWidgetPredicate(
        (Widget widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'tracking-ignored-undo-',
            ),
      );
      await tester.tap(undo.first);
      await settle(tester);
      await tester.tap(undo.first);
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('tracking-page-ignored-empty')),
        findsOneWidget,
      );
      expect(await tester.runAsync(service.listIgnored), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('"Don\'t track the series" from a volume\'s row ignores its '
      'series collection', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[
      _StandInSite('a', kinds: <TrackingKind>{TrackingKind.manga}),
    ]);
    late int series;
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Ajin 01',
          title: 'Ajin 01',
          epubPath: '/books/ajin01.cbz',
          extractDir: '/books/ajin01',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
          completedAt: Value<DateTime?>(
            DateTime.fromMillisecondsSinceEpoch(5000),
          ),
        ),
      );
      series = await db.createMediaCollection('Ajin');
      await db.addToCollection(series, MediaKind.epub, 'Ajin 01');
    });
    await pumpApp(tester, page());
    expect(find.text('Ajin 01'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-attention-menu-0')),
    );
    await settle(tester, rounds: 3);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-row-action-ignore-series')),
    );
    await settle(tester);
    expect(find.text('Ajin 01'), findsNothing);
    final List<MediaTrackingIgnoredRow> ignored = (await tester.runAsync(
      service.listIgnored,
    ))!;
    expect(ignored.single.mediaType, TrackingMediaType.bookCollection.value);
    expect(ignored.single.mediaKey, '$series');
    expect(ignored.single.mediaTitle, 'Ajin');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a media server episode with no series: the link dialog starts '
      'at its episode number', (WidgetTester tester) async {
    await open(tester, <TrackingProvider>[
      _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime},
        results: const <TrackingSearchHit>[_frieren],
      ),
    ]);
    await tester.runAsync(
      () => service.recordRemoteVideoCompleted(
        const RemoteAnimeEpisode(
          mediaKey: 'jellyfin|srv|u|lone7',
          title: 'Episode 7',
          episodeNumber: 7,
          seasonNumber: 2,
          serverName: 'Home server',
        ),
      ),
    );
    await pumpApp(tester, page());
    await tester.tap(find.text('Episode 7'));
    await settle(tester, rounds: 20);
    expect(find.byType(TrackingLinkDialog), findsOneWidget);
    final TextField offset = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-link-offset')),
        matching: find.byType(TextField),
      ),
    );
    expect(offset.controller!.text, '7');
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-result-101')),
    );
    await settle(tester, rounds: 20);
    final MediaTrackingMappingRow? mapping = await tester
        .runAsync<MediaTrackingMappingRow?>(
          () => repository.findMapping(
            mediaType: TrackingMediaType.remoteVideo,
            mediaKey: 'jellyfin|srv|u|lone7',
            provider: 'a',
          ),
        );
    expect(mapping?.progressOffset, 7);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('T1 F6 + F7: any library item can be linked before it has '
      'progress, and a single episode starts at its own number', (
    WidgetTester tester,
  ) async {
    await open(tester, <TrackingProvider>[
      _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime},
        results: const <TrackingSearchHit>[_frieren],
      ),
    ]);
    const String title = "[FSP] Beyond Time's Gaze Episode 46 [4K HEVC AAC]";
    await tester.runAsync(
      () => db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'btg46',
          title: title,
          videoPath: 'C:/anime/$title.mkv',
        ),
      ),
    );
    await pumpApp(tester, page());
    expect(find.text(title), findsNothing, reason: 'no progress, no row');
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-page-link-item')),
    );
    await settle(tester, rounds: 20);
    expect(find.byType(TrackingLinkDialog), findsOneWidget);
    // T2 G10: nothing is chosen for the user; the library is searched.
    expect(
      find.byKey(const ValueKey<String>('tracking-link-query')),
      findsNothing,
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-link-local-search')),
        matching: find.byType(EditableText),
      ),
      'beyond',
    );
    await settle(tester, rounds: 2);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-local-video-btg46')),
    );
    await settle(tester, rounds: 20);
    TextField field(String key) => tester.widget<TextField>(
      find.descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(TextField),
      ),
    );
    expect(field('tracking-link-offset').controller!.text, '46');
    expect(field('tracking-link-query').controller!.text, "Beyond Time's Gaze");
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-result-101')),
    );
    await settle(tester, rounds: 20);
    final MediaTrackingMappingRow? mapping = await tester
        .runAsync<MediaTrackingMappingRow?>(
          () => repository.findMapping(
            mediaType: TrackingMediaType.video,
            mediaKey: 'btg46',
            provider: 'a',
          ),
        );
    expect(mapping?.progressOffset, 46);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a PDF can be linked as manga: the link dialog offers the kind '
      'and the link keeps it', (WidgetTester tester) async {
    final _StandInSite novels = _StandInSite(
      'n',
      kinds: <TrackingKind>{TrackingKind.novel},
    );
    final _StandInSite manga = _StandInSite(
      'm',
      kinds: <TrackingKind>{TrackingKind.manga},
      results: const <TrackingSearchHit>[
        TrackingSearchHit(
          subjectId: 202,
          name: 'Ajin',
          kind: TrackingKind.manga,
        ),
      ],
    );
    await open(tester, <TrackingProvider>[novels, manga]);
    await tester.runAsync(
      () => db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Ajin 01.pdf',
          title: 'Ajin 01.pdf',
          epubPath: '/books/ajin01.pdf',
          extractDir: '/books/ajin01',
          chapterCount: 200,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('pdf'),
          completedAt: Value<DateTime?>(
            DateTime.fromMillisecondsSinceEpoch(5000),
          ),
        ),
      ),
    );
    await pumpApp(tester, page());
    await tester.tap(find.text('Ajin 01.pdf'));
    await settle(tester, rounds: 20);
    expect(find.byType(TrackingLinkDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('tracking-link-kind')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('tracking-link-result-202')),
      findsNothing,
      reason: 'novel first: the manga site is not offered',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-kind-manga')),
    );
    await settle(tester, rounds: 20);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-result-202')),
    );
    await settle(tester, rounds: 20);
    final MediaTrackingMappingRow? link = await tester
        .runAsync<MediaTrackingMappingRow?>(
          () => repository.findMapping(
            mediaType: TrackingMediaType.book,
            mediaKey: 'Ajin 01.pdf',
            provider: 'm',
          ),
        );
    expect(link?.kind, TrackingKind.manga.value);
    expect(link?.subjectId, 202);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Track sheet of a PDF: "Track as" novel or manga', (
    WidgetTester tester,
  ) async {
    await open(tester, <TrackingProvider>[
      _StandInSite('a', kinds: <TrackingKind>{TrackingKind.manga}),
    ]);
    await tester.runAsync(
      () => db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Ajin 01.pdf',
          title: 'Ajin 01.pdf',
          epubPath: '/books/ajin01.pdf',
          extractDir: '/books/ajin01',
          chapterCount: 200,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('pdf'),
        ),
      ),
    );
    await pumpApp(
      tester,
      Scaffold(
        body: BookTrackingDialog(service: service, bookKey: 'Ajin 01.pdf'),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('book-tracking-kind')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('book-tracking-kind-manga')),
    );
    await settle(tester);
    expect(
      find.byKey(const ValueKey<String>('book-tracking-kind')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final bool apple in <bool>[false, true]) {
    testWidgets('Track sheet: "Don\'t track the series" and "Track again" '
        '(${apple ? 'Apple' : 'Material'})', (WidgetTester tester) async {
      await open(tester, <TrackingProvider>[
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.manga}),
      ]);
      late int series;
      await tester.runAsync(() async {
        await db.insertEpubBook(
          EpubBooksCompanion.insert(
            bookKey: 'Ajin 01',
            title: 'Ajin 01',
            epubPath: '/books/ajin01.cbz',
            extractDir: '/books/ajin01',
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: 1,
            format: const Value<String>('manga'),
          ),
        );
        series = await db.createMediaCollection('Ajin');
        await db.addToCollection(series, MediaKind.epub, 'Ajin 01');
      });
      await pumpApp(
        tester,
        Scaffold(
          body: BookTrackingDialog(service: service, bookKey: 'Ajin 01'),
        ),
        apple: apple,
      );
      expect(
        find.byKey(const ValueKey<String>('book-tracking-ignore')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('book-tracking-ignore-series')),
      );
      await settle(tester);
      expect(
        find.text(t.media_tracking_ignore_series_paused_note(name: 'Ajin')),
        findsOneWidget,
      );
      // T1 F12: links are kept (paused); the note must not say otherwise.
      expect(find.textContaining('nothing is linked'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('book-tracking-ignore')),
        findsNothing,
      );
      final List<MediaTrackingIgnoredRow> ignored = (await tester.runAsync(
        service.listIgnored,
      ))!;
      expect(ignored.single.mediaType, TrackingMediaType.bookCollection.value);
      expect(ignored.single.mediaKey, '$series');

      await tester.tap(
        find.byKey(const ValueKey<String>('book-tracking-series-track-again')),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('book-tracking-ignore-series')),
        findsOneWidget,
      );
      expect(await tester.runAsync(service.listIgnored), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final bool apple in <bool>[false, true]) {
    testWidgets('Activity: newest first, errors shown, search, narrow width '
        '(${apple ? 'Apple' : 'Material'})', (WidgetTester tester) async {
      await open(tester, <TrackingProvider>[
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
      ]);
      await tester.runAsync(() async {
        await link('a', 'v1', 'Frieren 01', TrackingKind.anime);
        await link('a', 'v2', 'Dungeon Meshi 01', TrackingKind.anime);
        for (final String key in <String>['v1', 'v2']) {
          await repository.enqueueProgress(
            mediaType: TrackingMediaType.video,
            mediaKey: key,
            localProgress: 0,
            completed: false,
            provider: 'a',
          );
        }
        final List<PendingTrackingUpdate> pending = await repository.allPending(
          provider: 'a',
        );
        PendingTrackingUpdate of(String key) => pending.firstWhere(
          (PendingTrackingUpdate u) => u.mapping.mediaKey == key,
        );
        await repository.logActivity(of('v1'), nowMs: 1000);
        await repository.logActivity(
          of('v2'),
          error: 'HTTP 500 boom',
          nowMs: 2000,
        );
      });
      await pumpApp(
        tester,
        TrackingPage(
          service: service,
          database: db,
          onOpenSettings: () {},
          initialTab: TrackingPageTab.activity,
        ),
        apple: apple,
      );
      expect(find.byType(TrackingActivityRow), findsNWidgets(2));
      final List<String> titles = <String>[
        for (final TrackingActivityRow row in tester.widgetList(
          find.byType(TrackingActivityRow),
        ))
          row.row.mediaTitle,
      ];
      expect(titles, <String>['Dungeon Meshi 01', 'Frieren 01']);
      expect(find.textContaining('HTTP 500 boom'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey<String>('tracking-page-filter')),
          matching: find.byType(EditableText),
        ),
        'frie',
      );
      await settle(tester, rounds: 2);
      expect(find.byType(TrackingActivityRow), findsOneWidget);

      // A phone's width: the four tabs scroll sideways, with faded edges
      // saying there is more (T1 F14). (The Apple control paints its own
      // labels: the tab is found by its text.)
      tester.view.physicalSize = const Size(360, 800);
      await settle(tester, rounds: 4);
      final Finder activityTab = find.text(t.media_tracking_page_tab_activity);
      expect(
        find.ancestor(
          of: activityTab,
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w.runtimeType.toString().startsWith('FadingEdgeScrollView'),
          ),
        ),
        findsOneWidget,
        reason: 'the overflowing tab strip shows a scroll hint',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a media server season with no ids is listed once and linked '
      'by hand; the newest episode goes out', (WidgetTester tester) async {
    final _StandInSite site = _StandInSite(
      'a',
      kinds: <TrackingKind>{TrackingKind.anime},
      results: const <TrackingSearchHit>[_frieren],
    );
    await open(tester, <TrackingProvider>[site]);
    await tester.runAsync(() async {
      for (final int number in <int>[3, 4]) {
        await service.recordRemoteVideoCompleted(
          RemoteAnimeEpisode(
            mediaKey: 'jellyfin|srv|u|e$number',
            title: 'Frieren S1E$number',
            episodeNumber: number,
            seasonNumber: 1,
            seriesId: 'series9',
            seriesTitle: 'Frieren',
            serverName: 'Home server',
          ),
        );
      }
    });
    await pumpApp(tester, page());
    expect(find.text('Frieren S1'), findsOneWidget);
    expect(
      find.textContaining(t.media_tracking_remote_episodes_watched(n: '2')),
      findsOneWidget,
    );

    await tester.tap(find.text('Frieren S1'));
    await settle(tester, rounds: 20);
    expect(find.byType(TrackingLinkDialog), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('tracking-link-result-101')),
    );
    await settle(tester, rounds: 20);
    // Sent once the Undo bar closes (T2 G2).
    await tester.pump(kTrackingLinkUndoVisible + const Duration(seconds: 1));
    await settle(tester, rounds: 20);

    expect(site.pushed, isNotEmpty);
    expect(site.pushed.last.mapping.mediaType, 'remote_series');
    expect(site.pushed.last.outbox.progress, 4);
    expect(find.text('Frieren S1'), findsNothing, reason: 'not listed now');
    expect(
      await tester.runAsync(repository.listRemoteEpisodes),
      hasLength(2),
      reason: 'kept for the season link',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final bool apple in <bool>[false, true]) {
    testWidgets(
      'changing a manga link: the dialog with its unit choice lays '
      'out (${apple ? 'Apple' : 'Material'})',
      // Apple: BUG-4397 (the Apple dialog shell sizes its content with
      // IntrinsicWidth; the Apple segmented control must answer that).
      (WidgetTester tester) async {
        await open(tester, <TrackingProvider>[
          _StandInSite(
            'a',
            kinds: <TrackingKind>{TrackingKind.manga},
            results: const <TrackingSearchHit>[_frieren],
          ),
        ]);
        await tester.runAsync(
          () => link(
            'a',
            'm1',
            'Ajin 01',
            TrackingKind.manga,
            type: TrackingMediaType.book,
          ),
        );
        await pumpApp(
          tester,
          TrackingPage(
            service: service,
            database: db,
            onOpenSettings: () {},
            initialTab: TrackingPageTab.linked,
          ),
          apple: apple,
        );
        await tester.tap(find.text('Ajin 01'));
        await settle(tester);
        expect(find.byType(TrackingLinkDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  // Keyboard alone (focus-driven: Tab moves, Enter activates; no taps).
  for (final bool apple in <bool>[false, true]) {
    testWidgets('keyboard only: tabs, kind filter, search, rows, row menu and '
        'the link dialog (${apple ? 'Apple' : 'Material'})', (
      WidgetTester tester,
    ) async {
      final _StandInSite site = _StandInSite(
        'a',
        kinds: <TrackingKind>{TrackingKind.anime, TrackingKind.manga},
        results: const <TrackingSearchHit>[_frieren],
      );
      await open(tester, <TrackingProvider>[site]);
      await tester.runAsync(() async {
        await link('a', 'v1', 'Frieren 01', TrackingKind.anime);
        await link(
          'a',
          'm1',
          'Ajin 01',
          TrackingKind.manga,
          type: TrackingMediaType.book,
        );
      });
      await pumpApp(
        tester,
        TrackingPage(
          service: service,
          database: db,
          onOpenSettings: () {},
          initialTab: TrackingPageTab.linked,
        ),
        apple: apple,
      );
      final FocusDriver driver = FocusDriver(tester);
      Future<void> press(Finder target, String what) async {
        expect(await driver.focusWidget(target), isTrue, reason: what);
        await driver.activate();
        await settle(tester);
      }

      // The focus is on [key] itself or inside it (not on a row that merely
      // contains it).
      bool focusIn(String key) {
        final BuildContext? ctx = driver.focused?.context;
        if (ctx == null) return false;
        if (ctx.widget.key == ValueKey<String>(key)) return true;
        bool found = false;
        ctx.visitAncestorElements((Element el) {
          found = el.widget.key == ValueKey<String>(key);
          return !found;
        });
        return found;
      }

      Future<void> pressKey(String key, {LogicalKeyboardKey? move}) async {
        expect(
          await driver.focusUntil(
            () => focusIn(key),
            key: move ?? LogicalKeyboardKey.tab,
          ),
          isTrue,
          reason: key,
        );
        await driver.activate();
        await settle(tester, rounds: 6);
      }

      // The header actions, the four tabs, the search field, the kinds and
      // every row's actions are Tab stops, in reading order.
      final List<FocusNode> order = await driver.reachAll(maxSteps: 40);
      List<String> keysOf(FocusNode node) {
        final List<String> keys = <String>[];
        node.context?.visitAncestorElements((Element el) {
          final Key? key = el.widget.key;
          if (key is ValueKey<String>) keys.add(key.value);
          return true;
        });
        return keys;
      }

      int firstIndex(String key) =>
          order.indexWhere((FocusNode n) => keysOf(n).contains(key));
      final List<int> positions = <int>[
        for (final String key in <String>[
          'tracking-page-sync-now',
          'tracking-page-tabs',
          'tracking-page-search',
          'tracking-page-kinds',
          'tracking-linked-1',
          'tracking-linked-menu-1',
          'tracking-linked-2',
        ])
          firstIndex(key),
      ];
      expect(positions, everyElement(greaterThanOrEqualTo(0)));
      expect(
        positions,
        orderedEquals(<int>[...positions]..sort()),
        reason: 'focus order follows the page top to bottom',
      );

      // A tab: Enter switches to it.
      await press(
        find.text(t.media_tracking_page_tab_activity),
        'Activity tab',
      );
      expect(find.byType(TrackingLinkedRow), findsNothing);
      await press(
        find.text('${t.media_tracking_page_tab_linked} (2)'),
        'Linked tab',
      );
      expect(find.byType(TrackingLinkedRow), findsNWidgets(2));

      // The kind filter: Enter toggles a kind.
      await press(find.text(trackingKindLabel('manga')), 'manga filter');
      expect(find.byType(TrackingLinkedRow), findsOneWidget);
      await press(find.text(trackingKindLabel('manga')), 'manga filter off');
      expect(find.byType(TrackingLinkedRow), findsNWidgets(2));

      // Search: the field takes focus and typing filters.
      final Finder search = find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-page-filter')),
        matching: find.byType(EditableText),
      );
      expect(await driver.focusWidget(search), isTrue, reason: 'search');
      tester.testTextInput.enterText('frie');
      await settle(tester, rounds: 3);
      expect(find.byType(TrackingLinkedRow), findsOneWidget);
      tester.testTextInput.enterText('');
      await settle(tester, rounds: 3);
      expect(find.byType(TrackingLinkedRow), findsNWidgets(2));

      // A row's menu: Enter opens it, the arrow keys reach an action,
      // Enter runs it.
      await pressKey('tracking-linked-menu-2');
      // The Apple menu draws its own rows: the action is found by its text.
      final Finder ignoreAction = find.text(t.media_tracking_ignore_action);
      expect(ignoreAction, findsOneWidget, reason: 'Enter opened the menu');
      bool focusOnAction() {
        final BuildContext? ctx = driver.focused?.context;
        if (ctx == null || driver.focused is FocusScopeNode) return false;
        final Element action = ignoreAction.evaluate().first;
        bool inside = false;
        action.visitAncestorElements((Element el) {
          inside = el == ctx;
          return !inside;
        });
        return inside;
      }

      expect(
        await driver.focusUntil(
          focusOnAction,
          maxSteps: 6,
          key: LogicalKeyboardKey.arrowDown,
        ),
        isTrue,
        reason: 'the arrow keys reach the menu action',
      );
      await driver.activate();
      await settle(tester, rounds: 6);
      expect(await tester.runAsync(service.listIgnored), hasLength(1));

      // A row: Enter opens the link dialog; Cancel closes it.
      await press(
        find.byKey(const ValueKey<String>('tracking-linked-1')),
        'linked row',
      );
      expect(find.byType(TrackingLinkDialog), findsOneWidget);
      expect(
        await driver.focusWidget(
          find.byKey(const ValueKey<String>('tracking-link-query')),
        ),
        isTrue,
        reason: 'dialog search field',
      );
      // Cancel itself takes the focus (not a container around it).
      final Element cancel = find
          .ancestor(
            of: find.descendant(
              of: find.byType(TrackingLinkDialog),
              matching: find.text(t.cancel),
            ),
            matching: find.byType(FushiTextButton),
          )
          .evaluate()
          .first;
      bool focusOnCancel() {
        final BuildContext? ctx = driver.focused?.context;
        if (ctx == null) return false;
        if (ctx == cancel) return true;
        bool inside = false;
        ctx.visitAncestorElements((Element el) {
          inside = el == cancel;
          return !inside;
        });
        return inside;
      }

      expect(await driver.focusUntil(focusOnCancel), isTrue, reason: 'Cancel');
      // Enter on Cancel closes the dialog. The Apple dialog takes about
      // 420 ms to leave (Material about 200 ms): wait 720 ms, not 360 ms
      // (the F3 "Apple dialog does not close" finding was this wait).
      await driver.activate();
      await settle(tester);
      expect(find.byType(TrackingLinkDialog), findsNothing);

      // Escape closes it too.
      await press(
        find.byKey(const ValueKey<String>('tracking-linked-1')),
        'linked row (Escape)',
      );
      expect(find.byType(TrackingLinkDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(TrackingLinkDialog), findsNothing);

      // Again, and save by Enter on a result.
      await press(
        find.byKey(const ValueKey<String>('tracking-linked-1')),
        'linked row again',
      );
      await press(
        find.byKey(const ValueKey<String>('tracking-link-result-101')),
        'search result',
      );
      expect(find.byType(TrackingLinkDialog), findsNothing);
      final MediaTrackingMappingRow saved = (await tester.runAsync(
        () => repository.listMappings(),
      ))!.firstWhere((MediaTrackingMappingRow m) => m.mediaKey == 'v1');
      expect(saved.subjectId, 101);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  // T1 F15: rows lead with the cleaned title, the raw name below, and say
  // why an item waits and what kind it is (no metadata: "Video").
  for (final bool apple in <bool>[false, true]) {
    testWidgets('a row to link: cleaned title, raw name, reason and a neutral '
        'kind (${apple ? 'Apple' : 'Material'})', (WidgetTester tester) async {
      await open(tester, <TrackingProvider>[
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
      ]);
      const String raw = '[SubsGroup] Koori no Jouheki - 01 [1080p]';
      await tester.runAsync(() => seedVideo('v1', raw));
      await pumpApp(tester, page(), apple: apple);
      expect(tester.takeException(), isNull);
      final Finder row = find.byType(TrackingAttentionRow);
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('Koori no Jouheki')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byKey(const ValueKey<String>('tracking-row-raw-name')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining(
            '${t.media_tracking_kind_video} · '
            '${t.media_tracking_reason_not_scraped}',
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(t.media_tracking_anime), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  // T1 F21: links to one site entry are one row, collapsed by default.
  for (final bool apple in <bool>[false, true]) {
    testWidgets('links to one site entry form one row that opens to its links; '
        'search matches any member (${apple ? 'Apple' : 'Material'})', (
      WidgetTester tester,
    ) async {
      await open(tester, <TrackingProvider>[
        _StandInSite('a', kinds: <TrackingKind>{TrackingKind.anime}),
      ]);
      await tester.runAsync(() async {
        await link('a', 'c1', 'The Ramparts of Ice', TrackingKind.anime,
            type: TrackingMediaType.videoCollection, subjectId: 55);
        await link('a', 'v1', 'Ramparts S1E1', TrackingKind.anime,
            subjectId: 55);
        await link('a', 'v2', 'Ramparts S1E2', TrackingKind.anime,
            subjectId: 55);
        await link('a', 'v3', 'Frieren 01', TrackingKind.anime);
      });
      await pumpApp(
        tester,
        TrackingPage(
          service: service,
          database: db,
          onOpenSettings: () {},
          initialTab: TrackingPageTab.linked,
        ),
        apple: apple,
      );
      expect(tester.takeException(), isNull);
      const ValueKey<String> group = ValueKey<String>(
        'tracking-linked-group-a-55',
      );
      expect(find.byKey(group), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(group),
          matching: find.textContaining(t.media_tracking_group_links(n: '3')),
        ),
        findsOneWidget,
      );
      expect(find.byType(TrackingLinkedRow), findsOneWidget, reason: 'v3');

      await tester.tap(
        find.byKey(const ValueKey<String>('tracking-group-toggle-a-55')),
      );
      await settle(tester, rounds: 4);
      expect(find.byType(TrackingLinkedRow), findsNWidgets(4));
      expect(find.byType(TrackingGroupMember), findsNWidgets(3));

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey<String>('tracking-page-filter')),
          matching: find.byType(EditableText),
        ),
        'S1E2',
      );
      await settle(tester, rounds: 2);
      // T2 G11: only the matching link is listed (its siblings are not).
      expect(find.byKey(group), findsNothing);
      expect(find.byType(TrackingLinkedRow), findsOneWidget);
      expect(find.textContaining('S1E1'), findsNothing);
      expect(find.text('Frieren 01'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  // T1 F16: one click links; the current entry is marked; Undo restores the
  // previous link exactly.
  for (final bool apple in <bool>[false, true]) {
    testWidgets('changing a link: the current entry is marked, one click '
        'links, Undo puts the old link back (${apple ? 'Apple' : 'Material'})', (
      WidgetTester tester,
    ) async {
      await open(tester, <TrackingProvider>[
        _StandInSite(
          'a',
          kinds: <TrackingKind>{TrackingKind.anime},
          results: const <TrackingSearchHit>[_frieren],
        ),
      ]);
      await tester.runAsync(
        () => link('a', 'v1', 'Frieren 01', TrackingKind.anime, subjectId: 7),
      );
      final MediaTrackingMappingRow before = (await tester.runAsync(
        repository.listMappings,
      ))!.single;
      await pumpApp(
        tester,
        TrackingPage(
          service: service,
          database: db,
          onOpenSettings: () {},
          initialTab: TrackingPageTab.linked,
        ),
        apple: apple,
      );
      await tester.tap(
        find.byKey(ValueKey<String>('tracking-linked-${before.id}')),
      );
      await settle(tester);
      expect(find.byType(TrackingLinkDialog), findsOneWidget);
      // The current entry is listed first (the search did not find it).
      expect(
        find.byKey(const ValueKey<String>('tracking-link-current')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('tracking-link-result-7')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('tracking-link-result-101')),
      );
      await settle(tester);
      expect(find.byType(TrackingLinkDialog), findsNothing);
      expect(
        (await tester.runAsync(repository.listMappings))!.single.subjectId,
        101,
      );
      expect(
        find.textContaining(
          t.media_tracking_link_linked_to(
            entry: _frieren.name,
            site: 'Site a',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(t.undo));
      await settle(tester);
      final List<MediaTrackingMappingRow> after = (await tester.runAsync(
        repository.listMappings,
      ))!;
      expect(after, <MediaTrackingMappingRow>[before]);
      // T2 G2: the link waited for the Undo window, so nothing reached the
      // site, and the message says so.
      expect(
        find.text(t.media_tracking_link_undone_nothing_sent(site: 'Site a')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
