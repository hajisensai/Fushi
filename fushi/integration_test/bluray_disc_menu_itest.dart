import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/startup/observe_blank_detector.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/bluray_disc_track_fixture.dart';
import 'helpers/observe_capture.dart' show observeScreenshotDir;
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// Real disc VM + native overlay + production video page, never mocked mpv.
/// Run through tool/run_windows_itest.ps1 with these -DartDefine values:
/// FUSHI_BLURAY_MENU_ROOT: playable disc root (containing BDMV).
/// FUSHI_BLURAY_MENU_ENTRY: imported representative MPLS basename, e.g. 00001.
/// FUSHI_BLURAY_MENU_EXPECTED: MPLS selected by the authored menu.
/// FUSHI_BLURAY_MENU_KEYS: comma-separated up/down/left/right/enter/escape.
/// FUSHI_BLURAY_MENU_REPLAY_KEYS: replay from Top after an override, default enter.
/// FUSHI_BLURAY_MENU_VERIFY_TRACKS: additionally exercise persisted text/Off versus
/// authored PGS/audio; the initial key sequence must enable the desired tracks.
/// Android passes the same defines plus an isolated FUSHI_TEST_ROOT and provisions
/// the readable fixture through its device test runner before launch.
/// The keys must describe this fixture's authored menu; default is enter.
/// Missing fixture is an explicit skip, never counted as menu acceptance.
/// Screenshots are evidence for visual inspection, not an assertion that every
/// authored overlay pixel is correct. This test does not cover pointer input.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String root = String.fromEnvironment('FUSHI_BLURAY_MENU_ROOT');
  const String entry = String.fromEnvironment('FUSHI_BLURAY_MENU_ENTRY');
  const String expected = String.fromEnvironment('FUSHI_BLURAY_MENU_EXPECTED');
  const String keySequence = String.fromEnvironment(
    'FUSHI_BLURAY_MENU_KEYS',
    defaultValue: 'enter',
  );
  const String replayKeys = String.fromEnvironment(
    'FUSHI_BLURAY_MENU_REPLAY_KEYS',
    defaultValue: 'enter',
  );
  const bool verifyTracks = bool.fromEnvironment(
    'FUSHI_BLURAY_MENU_VERIFY_TRACKS',
  );
  const String subtitleId = String.fromEnvironment(
    'FUSHI_BLURAY_MENU_SUBTITLE_ID',
    defaultValue: '1',
  );
  const String audioId = String.fromEnvironment(
    'FUSHI_BLURAY_MENU_AUDIO_ID',
    defaultValue: '1',
  );
  final String? skipReason = !Platform.isWindows && !Platform.isAndroid
      ? 'Windows or Android native Blu-ray menu fixture required'
      : root.isEmpty || entry.isEmpty || expected.isEmpty
      ? 'Set FUSHI_BLURAY_MENU_ROOT, ENTRY and EXPECTED for a real disc'
      : !File(p.join(root, 'BDMV', 'index.bdmv')).existsSync()
      ? 'Disc fixture is not mounted: $root'
      : null;
  if (skipReason != null) {
    debugPrint('[bluray-menu] SKIP: $skipReason');
  }

  testWidgets(
    'disc menu selects native title identity and suspends progress',
    (WidgetTester tester) async {
      expect(RegExp(r'^\d{5}$').hasMatch(entry), isTrue);
      expect(RegExp(r'^\d{5}$').hasMatch(expected), isTrue);
      final String entryPath = p.join(root, 'BDMV', 'PLAYLIST', '$entry.mpls');
      final String expectedPath = p.join(
        root,
        'BDMV',
        'PLAYLIST',
        '$expected.mpls',
      );
      expect(File(entryPath).existsSync(), isTrue);
      expect(File(expectedPath).existsSync(), isTrue);

      final FlutterExceptionHandler? errorHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = errorHandler);
      expect(
        fushiTestRootPath(),
        isNotNull,
        reason: 'Use an isolated platform test runner for the test library',
      );
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      FlutterError.onError = errorHandler;
      // Use the model the helper already resolved: after the focus-navigation
      // toggle rebuilds the root, a second MaterialApp lookup finds nothing.
      final AppModel appModel = await enableFocusNavigation(tester);
      final FushiDatabase db = appModel.database;
      final VideoBookRepository repo = VideoBookRepository(db);
      final String uid =
          'video/itest-disc-menu-${DateTime.now().microsecondsSinceEpoch}';
      const int resumeSentinel = 12000;
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: const Value('BD menu integration fixture'),
          videoPath: Value(entryPath),
          lastPositionMs: const Value(resumeSentinel),
        ),
      );
      if (verifyTracks) {
        expect(
          entry,
          expected,
          reason: 'Track fixture must reuse its seeded MPLS',
        );
        await seedPersistedBlurayTextSubtitle(
          repo: repo,
          bookUid: uid,
          isolatedRoot: fushiTestRootPath()!,
        );
      }
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage.neutralized(
              bookUid: uid,
              repo: repo,
              openBlurayMenu: true,
            ),
          ),
        ),
      );
      VideoFushiTestHooks? hooks() {
        final Finder page = find.byType(VideoFushiPage);
        if (page.evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
      }

      final FocusDriver driver = FocusDriver(tester);
      // The product owns the initial menu intent, even when the author routes
      // first play into a movie. Never repair that entry path from this test.
      await _waitFor(
        tester,
        () {
          final VideoFushiTestHooks? current = hooks();
          final VideoDiscNavigationState? state =
              current?.debugDiscNavigationState;
          expect(
            current?.debugDiscPlaylistPath,
            isNull,
            reason:
                'First play must not acquire a movie identity before the menu',
          );
          if (state != null) {
            expect(current!.debugDiscLearningBlocked, isTrue);
            expect(current.debugDiscTitleReady, isFalse);
          }
          return _isTopMenu(state);
        },
        'initial authored top menu',
        hooks,
      );
      final VideoFushiTestHooks menu = hooks()!;
      expect(menu.debugDiscNavigationSupported, isTrue);
      expect(menu.debugDiscLearningBlocked, isTrue);
      expect(menu.debugDiscTitleReady, isFalse);
      await _capture(tester, 'bluray-menu-before');
      await _pumpFor(tester, const Duration(seconds: 1));
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(
        (await repo.getByBookUid(uid))!.lastPositionMs,
        resumeSentinel,
        reason: 'Opening/playing menu must not overwrite representative resume',
      );
      expect(
        await db.getStudySegmentsForMedia(
          mediaKind: kActivityMediaVideo,
          mediaKey: uid,
        ),
        isEmpty,
        reason: 'First play and menu animation are not study time',
      );

      expect(
        hooks()!.debugVideoFocusAttached,
        isTrue,
        reason: 'The authored-menu layout must host the shared video FocusNode',
      );
      expect(
        hooks()!.debugVideoSurfaceHoldsFocus,
        isTrue,
        reason: 'Native menu keys must reach the video surface',
      );
      await _sendMenuKeys(tester, keySequence);
      await _waitFor(
        tester,
        () => hooks()?.debugDiscTitleReady == true,
        'selected movie title',
        hooks,
      );
      final VideoFushiTestHooks title = hooks()!;
      expect(
        p.equals(title.debugDiscPlaylistPath!, expectedPath),
        isTrue,
        reason: 'Identity must come from native MPLS, not edition index',
      );
      final String titleUid = title.debugActiveBookUid;
      if (entry == expected) {
        expect(
          titleUid,
          uid,
          reason: 'Native selection must reuse the existing MPLS row',
        );
      }
      expect(
        p.equals((await repo.getByBookUid(titleUid))!.videoPath, expectedPath),
        isTrue,
      );
      expect(p.equals(title.debugMiningSource!, expectedPath), isTrue);
      expect(title.debugDiscLearningBlocked, isFalse);
      final int initialPosition = title.debugPositionMs ?? 0;
      await _waitFor(
        tester,
        () => (hooks()?.debugPositionMs ?? 0) >= initialPosition + 1500,
        'movie playback advancement',
        hooks,
      );
      await _capture(tester, 'bluray-menu-selected-title');
      if (verifyTracks) {
        await verifyBlurayDiscPgs(
          tester: tester,
          hooks: hooks,
          expectedSubtitleId: subtitleId,
          expectedAudioId: audioId,
          screenshotName: 'bluray-disc-pgs-before-override',
          capture: (String name) => _capture(tester, name),
        );
        await selectFushiSubtitleOffByFocus(
          tester: tester,
          driver: driver,
          hooks: hooks,
          repo: repo,
          bookUid: titleUid,
        );
      }

      // Return through the actual focusable product button, not direct mpv calls.
      expect(
        await driver.focusWidget(
          find.byKey(const ValueKey<String>('bluray-menu-top')),
        ),
        isTrue,
      );
      await driver.activate();
      await _waitFor(
        tester,
        () => _isTopMenu(hooks()?.debugDiscNavigationState),
        'return to authored menu',
        hooks,
      );
      expect(hooks()!.debugDiscLearningBlocked, isTrue);
      expect(hooks()!.debugDiscTitleReady, isFalse);
      await _capture(tester, 'bluray-menu-returned');
      // Let title tracker disposal finish, then compare two real DB snapshots.
      await _pumpFor(tester, const Duration(seconds: 1));
      final int savedPosition = (await repo.getByBookUid(
        titleUid,
      ))!.lastPositionMs;
      final int credited = await _creditedMs(db, titleUid);
      await _pumpFor(tester, const Duration(seconds: 3));
      expect(
        (await repo.getByBookUid(titleUid))!.lastPositionMs,
        savedPosition,
      );
      expect(
        await _creditedMs(db, titleUid),
        credited,
        reason: 'Returning to menu must suspend movie study progress',
      );
      // Enter must return to native menu ownership after using the Flutter Top
      // button. Re-selecting the same MPLS also exercises generation rebinding.
      expect(hooks()!.debugVideoFocusAttached, isTrue);
      expect(
        hooks()!.debugVideoSurfaceHoldsFocus,
        isTrue,
        reason: 'Returning through the toolbar must return focus to the menu',
      );
      await _sendMenuKeys(tester, replayKeys);
      await _waitFor(
        tester,
        () => hooks()?.debugDiscTitleReady == true,
        'movie selected again after toolbar return',
        hooks,
      );
      expect(hooks()!.debugActiveBookUid, titleUid);
      expect(p.equals(hooks()!.debugDiscPlaylistPath!, expectedPath), isTrue);
      if (verifyTracks) {
        await verifyBlurayDiscPgs(
          tester: tester,
          hooks: hooks,
          expectedSubtitleId: subtitleId,
          expectedAudioId: audioId,
          screenshotName: 'bluray-disc-pgs-after-off-return',
          capture: (String name) => _capture(tester, name),
        );
      }
      expect(
        await driver.focusWidget(
          find.byKey(const ValueKey<String>('bluray-menu-top')),
        ),
        isTrue,
      );
      await driver.activate();
      await _waitFor(
        tester,
        () => _isTopMenu(hooks()?.debugDiscNavigationState),
        'second return to authored menu',
        hooks,
      );
      await _pumpFor(tester, const Duration(seconds: 1));
      final int finalSavedPosition = (await repo.getByBookUid(
        titleUid,
      ))!.lastPositionMs;
      await navigator.maybePop();
      await _waitFor(
        tester,
        () => find.byType(VideoFushiPage).evaluate().isEmpty,
        'video page disposal',
        hooks,
      );
      await _pumpFor(tester, const Duration(seconds: 1));
      expect(
        (await repo.getByBookUid(titleUid))!.lastPositionMs,
        finalSavedPosition,
        reason: 'Closing from menu must not persist menu time as movie resume',
      );
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

const Map<String, LogicalKeyboardKey> _keys = <String, LogicalKeyboardKey>{
  'up': LogicalKeyboardKey.arrowUp,
  'down': LogicalKeyboardKey.arrowDown,
  'left': LogicalKeyboardKey.arrowLeft,
  'right': LogicalKeyboardKey.arrowRight,
  'enter': LogicalKeyboardKey.enter,
  'escape': LogicalKeyboardKey.escape,
};

bool _isTopMenu(VideoDiscNavigationState? state) =>
    state != null &&
    state.navigationActive &&
    state.stable &&
    state.title == 0 &&
    state.menuDomain &&
    state.menuActive;

Future<void> _sendMenuKeys(WidgetTester tester, String sequence) async {
  for (final String token in sequence.split(',')) {
    final LogicalKeyboardKey? key = _keys[token.trim()];
    expect(key, isNotNull, reason: 'Unknown fixture menu key: $token');
    final FocusNode? focus = FocusManager.instance.primaryFocus;
    debugPrint(
      '[bluray-menu] send $token focus=${focus?.debugLabel} '
      'widget=${focus?.context?.widget.runtimeType} '
      'ancestors=${focus?.ancestors.map((FocusNode node) => node.debugLabel).join(" > ")}',
    );
    final bool handled = await tester.sendKeyEvent(key!);
    debugPrint('[bluray-menu] key $token handled=$handled');
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() predicate,
  String phase,
  VideoFushiTestHooks? Function() hooks,
) async {
  final Stopwatch clock = Stopwatch()..start();
  String? lastStage;
  while (clock.elapsed < const Duration(seconds: 90)) {
    if (predicate()) return;
    final VideoFushiTestHooks? current = hooks();
    final String? stage = current?.debugDiscLoadStage;
    if (stage != lastStage) {
      debugPrint(
        '[bluray-menu] $phase stage=$stage '
        'supported=${current?.debugDiscNavigationSupported} '
        'pending=${current?.debugHasPendingController}',
      );
      lastStage = stage;
    }
    if (current?.debugLoadFailed == true) {
      await _captureDiagnostic(tester, 'bluray-menu-load-failed');
      fail(
        '$phase: video load failed at $stage: '
        '${current?.debugLoadFailureReason}',
      );
    }
    final String? error = hooks()?.debugDiscMenuError;
    if (error != null) {
      await _captureDiagnostic(tester, 'bluray-menu-native-error');
      fail('$phase: $error');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  final VideoDiscNavigationState? state = hooks()?.debugDiscNavigationState;
  await _captureDiagnostic(tester, 'bluray-menu-timeout');
  fail(
    '$phase timed out: supported=${hooks()?.debugDiscNavigationSupported}, '
    'error=${hooks()?.debugDiscMenuError}, stage=${hooks()?.debugDiscLoadStage}, '
    'pending=${hooks()?.debugHasPendingController}, '
    'native=${state?.navigationActive}, '
    'menu=${state?.menuActive}, domain=${state?.menuDomain}, '
    'title=${state?.title}, playlist=${state?.playlist}, '
    'generation=${state?.generation}, stable=${state?.stable}',
  );
}

Future<void> _captureDiagnostic(WidgetTester tester, String name) async {
  try {
    await _capture(tester, name);
  } on Object catch (error) {
    debugPrint('[bluray-menu] Diagnostic screenshot unavailable: $error');
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final Stopwatch clock = Stopwatch()..start();
  while (clock.elapsed < duration) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<int> _creditedMs(FushiDatabase db, String uid) async {
  final List<StudySegmentRow> segments = await db.getStudySegmentsForMedia(
    mediaKind: kActivityMediaVideo,
    mediaKey: uid,
  );
  return segments.fold<int>(
    0,
    (int sum, StudySegmentRow row) => sum + row.durationMs,
  );
}

/// Bounded rendering capture: live menu/video animation never settles.
Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 100));
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer? layer = view.debugLayer as OffsetLayer?;
  expect(layer, isNotNull);
  final ui.Image image = await layer!.toImage(view.paintBounds);
  try {
    final ByteData? rgba = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(rgba, isNotNull);
    expect(rgbaLooksNonBlank(rgba!.buffer.asUint8List()), isTrue);
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    expect(png, isNotNull);
    final String path = p.join(observeScreenshotDir().path, '$name.png');
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    debugPrint('[bluray-menu] Screenshot for native overlay review: $path');
  } finally {
    image.dispose();
  }
}
