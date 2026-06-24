import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// TODO-801 / TODO-802 acceptance gate (real Windows engine + focus-driven).
///
/// Verifies that after the "Appearance" category group was dropped, the theme
/// selector and the "Edit Book CSS" entry stay reachable inside the
/// "Layout & Display" sub-page (normal mode + lyrics mode), with no fatal
/// FlutterError / overflow at render time.
///
/// This is NOT a source scan: it mounts the real [ReaderQuickSettingsSheet]
/// widget (same construction the reader page uses), renders it on the real
/// Windows engine, and uses focus-driven navigation ([FocusDriver] / synthetic
/// Tab + Enter, never tester.tap / coordinate taps) to enter the layout
/// sub-page, then asserts on the actually-rendered widget tree.
///
/// Note: the full reader route (open a book -> bottom-bar settings -> sheet)
/// needs an InAppWebViewController + gamepad-A activation, both of which a
/// hidden Windows integration runner cannot synthesize (see the KNOWN GAP in
/// desktop_settings_smoke_test). So this mounts the same sheet widget the
/// reader builds with a fake webview controller -- render path, sub-page
/// routing and focus behaviour match the real app; only the WebView and the
/// gamepad-A boundary are bypassed.
///
/// Run (PowerShell, from hibiki/):
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/reader_settings_layout_reachability_test.dart -d windows

class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

AppModel _testAppModel() {
  final HibikiDatabase db = HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(PlatformServices.forCurrentPlatform())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });
  return appModel;
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required bool lyricsMode,
  String? extractDir,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) =>
                ReaderQuickSettingsSheet(
              controller: null,
              toc: const <TtuTocEntry>[],
              readerProgress: const (1, 3),
              onJumpSection: (_) async {},
              onBookmark: () async {},
              onExitReader: () {},
              webViewController: _FakeInAppWebViewController(),
              appModel: _testAppModel(),
              ref: ref,
              isHibikiReader: true,
              lyricsMode: lyricsMode,
              onToggleLyricsMode: () {},
              extractDir: extractDir,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _enterLayoutNarrow(WidgetTester tester, FocusDriver driver) async {
  final Finder layoutRow = find.ancestor(
    of: find.text(t.section_layout),
    matching: find.byType(AdaptiveSettingsNavigationRow),
  );
  final bool focused = await driver.focusWidget(layoutRow, maxSteps: 40);
  expect(focused, isTrue,
      reason: 'layout navigation row must be focus-reachable via Tab');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 300));
  if (find.text(t.ttu_theme).evaluate().isEmpty) {
    await driver.focusWidget(layoutRow, maxSteps: 40);
    await driver.activateIntent();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'TODO-802 narrow: appearance gone, layout sub-page hosts theme + book-CSS '
      '(focus-driven, real engine)', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[reader-layout] FlutterError: ${details.exceptionAsString()}');
    };
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await _pumpSheet(tester, lyricsMode: false, extractDir: '/tmp/book_x');

      // GATE 1: appearance category is gone from the reader settings.
      expect(find.text(t.settings_destination_appearance), findsNothing,
          reason: 'GATE1: appearance category must be gone');
      expect(find.text(t.section_navigation), findsOneWidget);
      expect(find.text(t.section_layout), findsOneWidget);

      final FocusDriver driver = FocusDriver(tester);
      await _enterLayoutNarrow(tester, driver);

      // GATE 2: theme selector visible + operable.
      expect(find.text(t.ttu_theme), findsOneWidget,
          reason: 'GATE2: theme selector merged into layout sub-page');
      expect(find.byType(HibikiSchemeSwatch), findsWidgets,
          reason: 'GATE2: theme swatches must render');

      // GATE 3: edit-book-CSS entry present when extractDir != null.
      expect(find.text(t.book_css_editor_edit_css), findsOneWidget,
          reason:
              'GATE3: book-CSS row in layout sub-page when extractDir != null');

      // GATE 5: no fatal FlutterError / overflow at render time.
      assertStrictErrors(errors);
      debugPrint('[reader-layout] PASS narrow');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });

  testWidgets('TODO-801: book-CSS row hidden when extractDir is null',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester, lyricsMode: false, extractDir: null);

    final FocusDriver driver = FocusDriver(tester);
    await _enterLayoutNarrow(tester, driver);

    expect(find.text(t.ttu_theme), findsOneWidget);
    expect(find.text(t.book_css_editor_edit_css), findsNothing,
        reason: 'TODO-801: no CSS row when extractDir is unavailable');
  });

  testWidgets('TODO-802 lyrics: theme + book-CSS still reachable',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) => errors.add(details);
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await _pumpSheet(tester, lyricsMode: true, extractDir: '/tmp/book_x');

      expect(find.text(t.settings_destination_appearance), findsNothing);

      final FocusDriver driver = FocusDriver(tester);
      await _enterLayoutNarrow(tester, driver);

      // GATE 4: lyrics-mode layout sub-page exposes theme + edit-book-CSS.
      expect(find.text(t.ttu_theme), findsOneWidget,
          reason: 'GATE4: lyrics mode must reach the theme selector');
      expect(find.byType(HibikiSchemeSwatch), findsWidgets);
      expect(find.text(t.book_css_editor_edit_css), findsOneWidget,
          reason: 'GATE4: lyrics mode must reach edit-book-CSS');

      assertStrictErrors(errors);
      debugPrint('[reader-layout] PASS lyrics');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });

  testWidgets('TODO-802 wide: no appearance category; layout pane hosts theme + CSS',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) => errors.add(details);
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await _pumpSheet(tester, lyricsMode: false, extractDir: '/tmp/book_x');

      // GATE 1 (wide left pane): no appearance category.
      expect(find.text(t.settings_destination_appearance), findsNothing,
          reason: 'GATE1: wide left pane must not contain appearance');
      expect(find.text(t.section_layout), findsOneWidget);

      // Select layout via focus (wide left pane uses HibikiListItem).
      final FocusDriver driver = FocusDriver(tester);
      final Finder layoutItem = find.text(t.section_layout);
      final bool focused = await driver.focusWidget(layoutItem, maxSteps: 40);
      expect(focused, isTrue,
          reason: 'GATE2: wide layout item must be reachable');
      await driver.activate();
      await tester.pump(const Duration(milliseconds: 300));
      if (find.text(t.ttu_theme).evaluate().isEmpty) {
        await driver.focusWidget(layoutItem, maxSteps: 40);
        await driver.activateIntent();
        await tester.pump(const Duration(milliseconds: 300));
      }

      // GATE 2 + 3 (wide right pane).
      expect(find.text(t.ttu_theme), findsOneWidget,
          reason: 'GATE2: wide layout pane must contain the theme selector');
      expect(find.text(t.book_css_editor_edit_css), findsOneWidget,
          reason: 'GATE3: wide layout pane must contain edit-book-CSS');

      assertStrictErrors(errors);
      debugPrint('[reader-layout] PASS wide');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
