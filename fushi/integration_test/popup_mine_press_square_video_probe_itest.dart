import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
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
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3308 真机探针（视频页查词浮层）：真实 OS 鼠标按下/松开「+」，桌面级截屏取证。
/// 环境变量同 popup_mine_press_square_probe_itest.dart。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets(
    'video popup mine button press leaves no square background',
    timeout: const Timeout(Duration(minutes: 8)),
    (WidgetTester tester) async {
      final String script = Platform.environment['PRESS_SCRIPT'] ?? '';
      final String outDir = Platform.environment['PRESS_OUT'] ?? '';
      final List<String> variants =
          (Platform.environment['PRESS_VARIANTS'] ?? 'default').split(',');
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = testErrorHandler);
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel appModel = await enableFocusNavigation(tester);
      await appModel.prefsRepo.setVideoAnime4kPromptShown();
      expect(await seedDictionary(tester), isTrue);
      final String origBrightness = appModel.themeNotifier.brightnessMode;
      HomePage.debugSelectTab!(HomeTab.video);
      await tester.pump(const Duration(seconds: 1));
      final String uid = await seedVideo(tester);
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
      final VideoFushiTestHooks video =
          tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
      for (int i = 0; i < 120 && video.debugPositionMs == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await video.debugPause();

      try {
        for (final String variant in variants) {
          await appModel.themeNotifier.setBrightnessMode(
            variant.contains('dark') ? 'dark' : 'light',
          );
          await tester.pump(const Duration(seconds: 2));
          await video.debugLookupAt('testword', 0);
          await tester.pump(const Duration(seconds: 2));
          final Finder popup = find.byWidgetPredicate(
            (Widget w) =>
                w is DictionaryPopupWebView &&
                w.result.searchTerm == 'testword' &&
                w.result.entries.isNotEmpty,
          );
          expect(popup, findsWidgets);
          final DictionaryPopupWebViewState state =
              tester.state(popup.last) as DictionaryPopupWebViewState;
          Map<Object?, Object?>? r;
          for (int i = 0; i < 80 && r == null; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            final dynamic raw = await state.debugEval(r'''
(() => { const b = document.querySelector('.mine-button');
  if (!b) return null; const r = b.getBoundingClientRect();
  if (r.width === 0) return null;
  return {x: r.left + r.width / 2, y: r.top + r.height / 2,
    w: r.width, h: r.height, cls: document.documentElement.className,
    bg: getComputedStyle(document.documentElement).backgroundColor,
    bodyBg: getComputedStyle(document.body).backgroundColor}; })()''');
            if (raw is Map) r = raw.cast<Object?, Object?>();
          }
          expect(r, isNotNull, reason: 'mine button must render');
          await tester.pump(const Duration(seconds: 1));
          final Rect wvRect = tester.getRect(popup.last);
          final double dpr = tester.view.devicePixelRatio;
          final double lx = wvRect.left + (r!['x']! as num).toDouble();
          final double ly = wvRect.top + (r['y']! as num).toDouble();
          debugPrint(
            '[press-probe-video] variant=$variant wvRect=$wvRect '
            'btn=$r dpr=$dpr logical=($lx,$ly)',
          );
          final Future<ProcessResult> proc = Process.run('powershell', <String>[
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            script,
            '-TargetPid',
            '$pid',
            '-LogicalX',
            '$lx',
            '-LogicalY',
            '$ly',
            '-Dpr',
            '$dpr',
            '-OutDir',
            outDir,
            '-Tag',
            'video-$variant',
          ]);
          ProcessResult? res;
          proc.then((ProcessResult v) => res = v);
          for (int i = 0; i < 900 && res == null; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          debugPrint(
            '[press-probe-video] ps exit=${res?.exitCode} '
            'out=${res?.stdout} err=${res?.stderr}',
          );
          final dynamic after = await state.debugEval(r'''
(() => ({sel: String(getSelection()), active: document.activeElement &&
  (document.activeElement.tagName + '.' + document.activeElement.className),
  ring: (() => { const g = document.getElementById('fushi-caret-ring');
    return g ? g.style.cssText : null; })(),
  mine: document.querySelector('.mine-button')?.className}))()''');
          debugPrint('[press-probe-video] variant=$variant after=$after');
          await video.debugPause();
        }
      } finally {
        await appModel.themeNotifier.setBrightnessMode(origBrightness);
      }
    },
  );
}
