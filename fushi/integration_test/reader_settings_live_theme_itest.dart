import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/settings/theme_preset_card.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi_core/fushi_core.dart' show PrefCodec;
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3008: real EPUB -> T -> focus the blue preset -> Enter, without closing
/// settings. Only run through the isolated Windows runner; no user book/data.
///
/// .\tool\run_windows_itest.ps1 integration_test\reader_settings_live_theme_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, {int ticks = 8}) async {
    for (int i = 0; i < ticks; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (int i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(finder, findsOneWidget);
  }

  testWidgets(
    'open reader settings follows warm to blue theme and reopening',
    (WidgetTester tester) async {
      // Fail before app startup if a caller bypasses the isolated test runner.
      if (fushiTestRootPath() == null || fushiTestRunId() == null) {
        throw StateError(
          'Use tool/run_windows_itest.ps1 with an isolated test root',
        );
      }
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      final Size originalSize = await windowManager.getSize();
      final AppModel model = await readyAppModel(tester);
      final String previousTheme = model.appThemeKey;
      final String previousBrightness = model.brightnessMode;
      final String previousDesign = model.themeNotifier.designSystem;
      final bool previousEink = model.einkMode;
      final bool previousFocusNavigation =
          model.experimentalFocusNavigationEnabled;
      try {
        await windowManager.setSize(const Size(1280, 900));
        await pump(tester);
        await enableFocusNavigation(tester);
        await model.themeNotifier.setEinkMode(false);
        await model.themeNotifier.setDesignSystem('material');
        await model.setBrightnessMode('dark');
        // The dark orange scheme produces the warm brown panel in the report.
        await model.setAppThemeKey('m3-orange');
        await pump(tester);
        final String book = await seedReaderBook(
          tester,
          fileName: 'bug3008-generated-reader.epub',
        );
        await openBookViaProductionPath(tester, book);
        await waitFor(
          tester,
          find.byKey(const ValueKey<String>('fushi_content_ready')),
        );
        final Size readerViewport = MediaQuery.sizeOf(
          tester.element(find.byType(ReaderFushiPage)),
        );
        expect(
          readerViewport.width,
          greaterThanOrEqualTo(kReaderPanelExpandedWidth),
        );
        debugPrint(
          '[bug3008] originalWindow=$originalSize '
          'desktopWindow=${await windowManager.getSize()} '
          'readerViewport=$readerViewport dpr=${tester.view.devicePixelRatio}',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        final Finder shell = find.byKey(
          const ValueKey<String>('fushi_reader_side_sheet'),
        );
        await waitFor(tester, shell);
        await pump(tester);
        final Finder settings = find.byType(ReaderQuickSettingsSheet);
        expect(settings, findsOneWidget);
        final State<StatefulWidget> session = tester.state(settings);
        final Finder rail = find.byKey(
          const ValueKey<String>('fushi_reader_panel_switcher'),
        );
        expect(
          rail,
          findsOneWidget,
          reason: 'this test requires a desktop-width window',
        );

        Color panelColor() => tester.widget<Material>(shell).color!;
        void expectLivePalette() {
          final ColorScheme pageScheme = Theme.of(
            tester.element(find.byType(ReaderFushiPage)),
          ).colorScheme;
          final BuildContext settingsContext = tester.element(settings);
          expect(Theme.of(settingsContext).colorScheme, pageScheme);
          expect(panelColor(), pageScheme.surfaceContainerLow);
          final FushiFloatingPill pill = tester.widget<FushiFloatingPill>(
            find
                .descendant(of: rail, matching: find.byType(FushiFloatingPill))
                .first,
          );
          expect(pill.color, pageScheme.surfaceContainer);
          debugPrint(
            '[bug3008] theme=${model.appThemeKey} '
            'panel=${panelColor().toARGB32().toRadixString(16)} '
            'rail=${pill.color.toARGB32().toRadixString(16)} '
            'bounds=${tester.getRect(shell)}',
          );
        }

        expectLivePalette();
        final Color warmPanel = panelColor();
        expect(
          (await captureFlutterFrame(tester, 'bug3008-warm-open')).saved,
          isTrue,
        );
        final Finder blue = find.byKey(
          const ValueKey<String>('theme-preset-m3-blue'),
        );
        final FocusDriver focus = FocusDriver(tester);
        expect(
          await focus.focusWidget(blue),
          isTrue,
          reason: 'the actual theme preset must be reachable by Tab',
        );
        await focus.activate();
        await pump(tester, ticks: 16);
        expect(model.appThemeKey, 'm3-blue');
        expect(
          PrefCodec.decode(
            (await model.database.getPref('app_theme_key'))!,
            '',
          ),
          'm3-blue',
        );
        expect(tester.widget<FushiThemePresetCard>(blue).selected, isTrue);
        expect(
          identical(session, tester.state(settings)),
          isTrue,
          reason: 'changing theme must not replace the open settings session',
        );
        expectLivePalette();
        expect(panelColor(), isNot(warmPanel));
        final Color openBluePanel = panelColor();
        expect(
          (await captureFlutterFrame(tester, 'bug3008-blue-still-open')).saved,
          isTrue,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pump(tester);
        expect(shell, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        await waitFor(tester, shell);
        await pump(tester);
        expectLivePalette();
        expect(
          panelColor(),
          openBluePanel,
          reason:
              'keeping settings open and reopening must resolve identically',
        );
        expect(
          (await captureFlutterFrame(tester, 'bug3008-blue-reopened')).saved,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pump(tester);
        expect(shell, findsNothing);
        debugPrint(
          '[bug3008] PASS same-session theme, rail, persisted preset, reopen',
        );
      } finally {
        try {
          await model.setAppThemeKey(previousTheme);
          await model.setBrightnessMode(previousBrightness);
          await model.themeNotifier.setDesignSystem(previousDesign);
          await model.themeNotifier.setEinkMode(previousEink);
          await model.setExperimentalFocusNavigationEnabled(
            previousFocusNavigation,
          );
        } finally {
          await windowManager.setSize(originalSize);
          await pump(tester);
        }
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
