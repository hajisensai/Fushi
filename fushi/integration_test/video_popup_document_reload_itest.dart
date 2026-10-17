import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3002: real video lookup followed by a new document in the same WebView.
/// Run with run_windows_itest.ps1 -Visible; all fixtures and app data are isolated.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'video popup restores its result after document replacement',
    timeout: const Timeout(Duration(minutes: 5)),
    (WidgetTester tester) async {
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = testErrorHandler);
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      // App startup installs its logger; assertion ownership stays with tests.
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel appModel = await enableFocusNavigation(tester);
      // This scenario starts after the desktop player's first-use introduction.
      await appModel.prefsRepo.setVideoAnime4kPromptShown();
      expect(await seedDictionary(tester), isTrue);
      HomePage.debugSelectTab!(HomeTab.video);
      await tester.pump(const Duration(seconds: 1));
      final String uid = await seedVideo(tester);
      // The home section only shows recently imported videos. The shared
      // fixture intentionally leaves importedAt unset for all-videos tests.
      await (appModel.database.update(
        appModel.database.videoBooks,
      )..where((table) => table.bookUid.equals(uid))).write(
        VideoBooksCompanion(
          importedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      HomeVideoPage.debugRefreshVideos?.call();
      final Finder videoCard = find.byKey(
        ValueKey<String>('home_video_recent_$uid'),
      );
      for (int i = 0; i < 80 && videoCard.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(videoCard, findsOneWidget);
      final FocusDriver driver = FocusDriver(tester);
      expect(await driver.focusWidget(videoCard), isTrue);
      await driver.activate();
      for (
        int i = 0;
        i < 60 && find.byType(VideoFushiPage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(VideoFushiPage), findsOneWidget);
      final VideoFushiTestHooks video =
          tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
      for (int i = 0; i < 120 && video.debugPositionMs == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        video.debugPositionMs,
        isNotNull,
        reason: 'the native player must be ready before subtitle lookup',
      );
      await video.debugPause();
      await video.debugLookupAt('testword', 0);
      await tester.pump();
      final Finder popup = find.byWidgetPredicate(
        (Widget widget) =>
            widget is DictionaryPopupWebView &&
            widget.result.searchTerm == 'testword' &&
            widget.result.entries.isNotEmpty,
      );
      expect(popup, findsOneWidget);
      final DictionaryPopupWebViewState state = tester.state(popup);

      Future<Map<String, dynamic>> renderedDocument({String probe = ''}) async {
        Map<String, dynamic> snapshot = <String, dynamic>{};
        for (int i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          final Object? raw = await state.debugEval('''JSON.stringify({
          text: document.getElementById('entries-container')?.innerText || '',
          token: window.__fushiRenderToken || 0,
          url: location.href,
          theme: document.documentElement.getAttribute('data-theme'),
          background: document.documentElement.style.getPropertyValue('--background-color'),
          probe: document.documentElement.dataset.popupReloadProbe || '',
          renderFunction: typeof window.renderPopup,
          height: document.getElementById('entries-container')?.scrollHeight || 0
        })''');
          if (raw is String) snapshot = jsonDecode(raw) as Map<String, dynamic>;
          if ((snapshot['text'] as String? ?? '').contains('testword') &&
              snapshot['probe'] == probe &&
              (snapshot['height'] as num? ?? 0) > 0) {
            return snapshot;
          }
        }
        fail('popup document did not render: $snapshot');
      }

      final Map<String, dynamic> before = await renderedDocument();
      final String html =
          DictionaryPopupWebViewState.buildInlinePopupHtmlIfReady(
            themeAttr: before['theme'] as String,
            bgHex: before['background'] as String,
          )!;
      // Use production's native NavigateToString path, preserving its inline
      // document/bridge contract. The marker proves observation of a new DOM.
      const String reloadProbe = 'native-load-data';
      expect(html, contains('<html'));
      await state.debugLoadDocument(
        html.replaceFirst(
          '<html',
          '<html data-popup-reload-probe="$reloadProbe"',
        ),
      );
      final Map<String, dynamic> after = await renderedDocument(
        probe: reloadProbe,
      );
      expect(after['probe'], reloadProbe);
      expect(after['token'] as num, greaterThan(before['token'] as num));
      expect(after['height'] as num, greaterThan(0));
      expect(state, same(tester.state(popup)));
      final List<int>? nativePixels = await state.debugCaptureWebView();
      expect(nativePixels, isNotNull);
      expect(nativePixels, isNotEmpty);
      final File nativeShot = File(
        '${observeScreenshotDir().path}/video-popup-native-reloaded.png',
      );
      await nativeShot.writeAsBytes(nativePixels!, flush: true);
      // A live video page may keep ticking after pause. Capture one painted
      // shell frame without pumpAndSettle waiting for every app animation.
      await tester.pump();
      final OffsetLayer? shellLayer =
          tester.binding.renderViews.first.debugLayer as OffsetLayer?;
      expect(shellLayer, isNotNull);
      final ui.Image shellImage = await shellLayer!.toImage(
        tester.binding.renderViews.first.paintBounds,
      );
      final File shellShot = File(
        '${observeScreenshotDir().path}/video-popup-shell-reloaded.png',
      );
      try {
        final List<int> pixels = (await shellImage.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        await shellShot.writeAsBytes(pixels, flush: true);
      } finally {
        shellImage.dispose();
      }
      debugPrint(
        '[popup-document-reload] ${jsonEncode(<String, dynamic>{'before': before, 'after': after, 'nativeScreenshot': nativeShot.path, 'shellScreenshot': shellShot.path})}',
      );
    },
  );
}
