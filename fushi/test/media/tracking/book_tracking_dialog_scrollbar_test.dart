// The book / manga Track sheet on desktop. A user test session logged "The
// provided ScrollController is attached to more than one ScrollPosition"
// (Scrollbar) while the Track sheet was in use. The likely shape: the search
// results and the sheet's own scroll view sharing one (primary) controller.
// This opens the sheet the way the shelf does (an app dialog over a page
// whose scroll controller is inherited as PrimaryScrollController on every
// platform), searches until the results overflow the window, and scrolls.
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/book_tracking_dialog.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in book site whose search returns 30 manga.
final class _BookSite implements TrackingProvider, TrackingBookLinker {
  _BookSite(this.id);

  @override
  final String id;

  @override
  String get displayName => 'Site $id';

  @override
  String get siteHost => '$id.example';

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
    for (int i = 1; i <= 30; i++)
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
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    testWidgets('desktop Track sheet with many search results on two sites: '
        'no scroll controller on two scroll views '
        '(${apple ? 'Apple' : 'Material'})', (WidgetTester tester) async {
      late final FushiDatabase db;
      late final PreferencesRepository prefs;
      late final MediaTrackingService service;
      await tester.runAsync(() async {
        db = FushiDatabase.forTesting(NativeDatabase.memory());
        prefs = PreferencesRepository(db);
        await prefs.loadFromDb();
        service = MediaTrackingService(
          repository: MediaTrackingRepository(db),
          preferences: prefs,
          userAgent: 'test-agent',
          extraProviders: <TrackingProvider>[_BookSite('a'), _BookSite('b')],
        );
        await service.setKindEnabled('b', TrackingKind.manga, true);
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
      });

      Future<void> settle({int rounds = 12}) async {
        for (int i = 0; i < rounds; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 60));
        }
      }

      List<String> shared() => <String>[
        for (final ScrollableState state in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        ))
          if ((state.widget.controller?.positions.length ?? 1) > 1)
            '${state.widget.axisDirection} ${state.context.widget}',
      ];

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final ScrollController page = ScrollController();
        addTearDown(page.dispose);
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
                home: Scaffold(
                  body: PrimaryScrollController(
                    controller: page,
                    automaticallyInheritForPlatforms: TargetPlatform.values
                        .toSet(),
                    child: ListView(
                      controller: page,
                      children: <Widget>[
                        for (int i = 0; i < 40; i++)
                          Builder(
                            builder: (BuildContext context) => ListTile(
                              key: ValueKey<String>('shelf-$i'),
                              title: Text('Shelf row $i'),
                              onTap: () => unawaited(
                                showBookTrackingDialog(
                                  context,
                                  service: service,
                                  bookKey: 'Ajin 01',
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey<String>('shelf-0')));
        await settle(rounds: 20);
        expect(find.byType(BookTrackingDialog), findsOneWidget);
        expect(shared(), isEmpty, reason: 'sheet open');

        for (final int site in <int>[0, 1]) {
          final Finder search = find.byWidgetPredicate(
            (Widget widget) =>
                widget is FushiIconButton &&
                widget.tooltip == t.media_tracking_track_search,
          );
          expect(search, findsNWidgets(2));
          await tester.ensureVisible(search.at(site));
          await tester.pump();
          await tester.tap(search.at(site));
          await settle();
        }
        expect(find.text('Unrelated result 1'), findsWidgets);
        expect(shared(), isEmpty, reason: 'results shown');

        await tester.drag(
          find.byType(BookTrackingDialog),
          const Offset(0, -600),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(640, 360),
            scrollDelta: Offset(0, 400),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(shared(), isEmpty, reason: 'after scrolling');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
        service.dispose();
        await tester.runAsync(() async {
          prefs.dispose();
          await db.close();
        });
      }
    });
  }
}
