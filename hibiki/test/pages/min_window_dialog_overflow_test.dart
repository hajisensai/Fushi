// TODO-1389: RenderFlex bottom overflow at TODO-1377 min window height.
// TODO-1377 lowered the desktop main-window minimum HEIGHT 640 -> 480 (client
// logical height about 440px). It only off-screen-verified 5 main surfaces
// (shelf/video/lookup/settings/dictionary), not dialogs/sheets. This test
// reproduces, at the min window height, three height-capped-frame + non
// -scrolling-body bottom overflows and locks the fix (scroll viewport or
// scrollable:true):
//   1. MediaSourcesDialog: HibikiReorderableColumn is non-scrolling and was the
//      one dialog MISSING the SingleChildScrollView wrap (BUG-445 shape; the
//      sibling local_audio_sources_dialog already had it).
//   2. sasayaki rematch desktop dialog: non-scrolling two-slider Column capped
//      by the outer 0.62 factor.
//   3. series rename dialog: cover image + text field non-scrolling Column
//      capped by the outer 0.74 factor.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/media_sources_dialog.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

class _DialogTestAppModel extends AppModel {
  _DialogTestAppModel() : super(testPlatformServices());
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  ThemeData theme() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
      );

  Future<void> pumpFrame(
    WidgetTester tester, {
    required Size screen,
    required double maxHeightFactor,
    required bool innerScrollable,
    required Widget body,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: Scaffold(
          body: Center(
            child: HibikiDialogFrame(
              maxWidth: 480,
              maxHeightFactor: maxHeightFactor,
              scrollable: false,
              child: HibikiModalSheetFrame(
                title: 'T',
                leadingIcon: Icons.info_outline,
                scrollable: innerScrollable,
                body: body,
                footer: const SizedBox(height: 36),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Widget sentenceAudioLikeBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const <Widget>[
          SizedBox(height: 140, width: double.infinity),
          SizedBox(height: 16),
          SizedBox(height: 140, width: double.infinity),
        ],
      );

  Widget seriesLikeBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const <Widget>[
          Center(child: SizedBox(width: 92, height: 120)),
          SizedBox(height: 12),
          SizedBox(height: 56),
        ],
      );

  bool isOverflow(Object? e) =>
      e != null && e.toString().toLowerCase().contains('overflow');

  group('sentenceAudioHighlight rematch dialog (0.62 cap) mechanism', () {
    testWidgets('scrollable false overflows at a short window (root cause)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 400),
        maxHeightFactor: 0.62,
        innerScrollable: false,
        body: sentenceAudioLikeBody(),
      );
      expect(isOverflow(tester.takeException()), isTrue,
          reason: 'non-scrolling two-slider Column overflows under 248px cap');
    });

    testWidgets('scrollable true scrolls without overflow (fix)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 400),
        maxHeightFactor: 0.62,
        innerScrollable: true,
        body: sentenceAudioLikeBody(),
      );
      expect(tester.takeException(), isNull, reason: 'scrollable true scrolls');
      expect(
        find.descendant(
          of: find.byType(HibikiModalSheetFrame),
          matching: find.byType(Scrollable),
        ),
        findsWidgets,
        reason: 'fixed body lives in a scroll viewport',
      );
    });
  });

  group('series rename dialog (0.74 cap) mechanism', () {
    testWidgets('scrollable false overflows at a short window (root cause)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 320),
        maxHeightFactor: 0.74,
        innerScrollable: false,
        body: seriesLikeBody(),
      );
      expect(isOverflow(tester.takeException()), isTrue,
          reason: 'cover image + field non-scrolling Column overflows');
    });

    testWidgets('scrollable true scrolls without overflow (fix)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 320),
        maxHeightFactor: 0.74,
        innerScrollable: true,
        body: seriesLikeBody(),
      );
      expect(tester.takeException(), isNull, reason: 'scrollable true scrolls');
    });
  });

  group('MediaSourcesDialog (real widget, BUG-445 shape)', () {
    Future<HibikiDatabase> seededDb(int sourceCount) async {
      final HibikiDatabase db = HibikiDatabase.forTesting(
          DatabaseConnection(NativeDatabase.memory()));
      for (int i = 0; i < sourceCount; i++) {
        await db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: 'src_$i',
            mediaKind: 'book',
            rootPath: '/tmp/src_$i',
            createdAt: i,
          ),
        );
      }
      return db;
    }

    Future<void> pumpDialog(
      WidgetTester tester, {
      required HibikiDatabase db,
      required Size screen,
    }) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final AppModel appModel = _DialogTestAppModel()
        ..wireDatabaseForTesting(db);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => appModel),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              theme: theme(),
              home: const Scaffold(
                body: Center(child: MediaSourcesDialog(mediaKind: 'book')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
        'TODO-1389 many sources scroll without overflow under min window cap',
        (WidgetTester tester) async {
      final HibikiDatabase db = await seededDb(24);
      addTearDown(db.close);
      await pumpDialog(tester, db: db, screen: const Size(520, 440));

      expect(tester.takeException(), isNull,
          reason: 'overflowing sources should scroll, not RenderFlex-overflow');

      final Finder reorderable = find.byType(HibikiReorderableColumn);
      expect(reorderable, findsOneWidget);
      final Finder outerScrollable = find.ancestor(
        of: reorderable,
        matching: find.byType(Scrollable),
      );
      expect(outerScrollable, findsWidgets,
          reason: 'fixed: reorderable wrapped in SingleChildScrollView');

      final ScrollableState state = tester.state(outerScrollable.first);
      expect(state.position.maxScrollExtent, greaterThan(0.0),
          reason: 'overflowing content leaves scroll extent');
    });
  });
}
