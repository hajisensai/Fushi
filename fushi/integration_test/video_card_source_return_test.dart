import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/main.dart' show FushiReaderApp;
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_source_fingerprint.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/focus_driver.dart';
import 'helpers/media_fixtures.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _bookUid = 'video/itest-card-source-return';
const int _savedPositionMs = 30000;
const int _clipStartMs = 5000;

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < const Duration(seconds: 40)) {
    await tester.pump(const Duration(milliseconds: 125));
  }
  expect(ready(), isTrue, reason: reason);
}

Future<void> _finish(WidgetTester tester, Future<void> action) async {
  bool done = false;
  Object? failure;
  unawaited(
    action.then(
      (_) => done = true,
      onError: (Object error) {
        failure = error;
        done = true;
      },
    ),
  );
  await _until(tester, () => done, reason: '来源导航应完成');
  if (failure != null) throw StateError('Source navigation failed: $failure');
}

VideoFushiTestHooks? _hooks(WidgetTester tester) {
  final Finder page = find.byType(VideoFushiPage);
  if (page.evaluate().isEmpty) return null;
  return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
}

SourceReviewSession _session(WidgetTester tester) =>
    tester.widget<SourceReviewBanner>(find.byType(SourceReviewBanner)).session;

Future<int> _count(FushiDatabase db, String table) async =>
    (await db.customSelect('SELECT count(*) AS n FROM $table').getSingle())
        .read<int>('n');

/// A focusable video ancestor does not prove that Tab reached the button.
Future<void> _activateButton(
  WidgetTester tester,
  FocusDriver driver,
  Finder target,
) async {
  expect(target, findsOneWidget);
  final bool reached = await driver.focusUntil(() {
    final FocusNode? focused = driver.focused;
    if (focused == null || focused is FocusScopeNode || focused.skipTraversal) {
      return false;
    }
    final BuildContext? owner = focused.context;
    if (owner == null) return false;
    final Set<Element> controls = target.evaluate().toSet();
    if (controls.contains(owner)) return true;
    bool inside = false;
    owner.visitAncestorElements((Element ancestor) {
      if (!controls.contains(ancestor)) return true;
      inside = true;
      return false;
    });
    return inside;
  });
  expect(reached, isTrue, reason: 'Tab 应到达来源工具栏按钮');
  await driver.activate();
}

/// Real libmpv playback and real database; launch only with the Windows runner:
/// powershell -File fushi/tool/run_windows_itest.ps1
///   -Target integration_test/video_card_source_return_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'video source continue plays and returning to the clip preserves viewing progress',
    timeout: const Timeout(Duration(minutes: 5)),
    (WidgetTester tester) async {
      // Fail before app startup if this would point at ordinary user data.
      expect(Platform.isWindows, isTrue);
      final String isolatedRoot = Platform.environment['FUSHI_TEST_ROOT'] ?? '';
      final String appData = Platform.environment['APPDATA'] ?? '';
      expect(isolatedRoot, isNotEmpty, reason: '请使用隔离 Windows itest runner');
      expect(p.isWithin(isolatedRoot, appData), isTrue);

      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel model = await enableFocusNavigation(tester);
      final FushiDatabase db = model.database;
      final VideoBookRepository videos = VideoBookRepository(db);
      final Directory fixtureDir = Directory(
        p.join(isolatedRoot, 'source-video'),
      );
      await fixtureDir.create(recursive: true);
      final File video = await generateTestVideo(
        outPath: p.join(fixtureDir.path, 'source-review.mp4'),
        duration: const Duration(seconds: 45),
      );
      await videos.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value(_bookUid),
          title: const Value('Source return video fixture'),
          videoPath: Value(video.absolute.path),
          lastPositionMs: const Value(_savedPositionMs),
        ),
      );
      final VideoBookRow before = (await videos.getByBookUid(_bookUid))!;
      final int statsBefore = await _count(db, 'study_segments');
      final int historyBefore = await _count(db, 'media_open_history');
      final String? coverageBefore = await db.getPref(
        videoWatchCoveragePrefKey(_bookUid),
      );
      final WidgetRef ref = tester.element(find.byType(FushiReaderApp))
          as ConsumerStatefulElement;
      final CardSourceLink link = CardSourceLink(
        kind: CardSourceKind.video,
        uid: _bookUid,
        sourceId: CardSourceLink.newSourceId(),
        episodeIndex: 0,
        startMs: _clipStartMs,
        endMs: 8000,
        fingerprint: await VideoSourceFingerprint.instance.fingerprint(
          video.path,
        ),
      );

      await _finish(tester, openCardSource(ref: ref, link: link));
      await _until(tester, () {
        final VideoFushiTestHooks? hooks = _hooks(tester);
        return hooks != null &&
            (hooks.debugDurationMs ?? 0) > 40000 &&
            ((hooks.debugPositionMs ?? -10000) - _clipStartMs).abs() < 1000;
      }, reason: '真实视频应暂停定位到卡片 5s，而不是原观看 30s');
      final VideoFushiTestHooks firstHooks = _hooks(tester)!;
      final SourceReviewSession firstSession = _session(tester);
      expect(firstSession.isReview, isTrue);
      expect(firstHooks.debugIsPlaying, isFalse);
      expect(find.text(t.card_source_review_video_continue), findsOneWidget);
      // Returning to the clip is the Anki source link itself; the page keeps
      // no in-page clip button, so nothing survives continuing to watch.
      expect(
        find.byKey(const ValueKey<String>('source-review-return-to-source')),
        findsNothing,
      );
      final ObserveShot reviewShot = await captureFlutterFrame(
        tester,
        'source-review-video-review',
      );
      expect(reviewShot.saved, isTrue);

      // Use existing controller hooks to play/pause real libmpv. User-facing
      // continue / return actions below must go through keyboard focus and UI.
      await firstHooks.debugPlay();
      await _until(
        tester,
        () => (firstHooks.debugPositionMs ?? 0) >= _clipStartMs + 2000,
        reason: '回看中手动播放必须真实推进',
      );
      expect(firstHooks.debugIsPlaying, isTrue);
      await firstHooks.debugPause();
      final VideoBookRow reviewed = (await videos.getByBookUid(_bookUid))!;
      expect(reviewed.lastPositionMs, before.lastPositionMs);
      expect(reviewed.lastPlayedAt, before.lastPlayedAt);
      expect(reviewed.completedAt, before.completedAt);
      expect(await _count(db, 'study_segments'), statsBefore);
      expect(await _count(db, 'media_open_history'), historyBefore);
      expect(
        await db.getPref(videoWatchCoveragePrefKey(_bookUid)),
        coverageBefore,
      );
      debugPrint('[video-source-itest] manual review playback preserved DB');

      final FocusDriver focus = FocusDriver(tester);
      final int pausedAt = firstHooks.debugPositionMs!;
      await _activateButton(
        tester,
        focus,
        find.widgetWithText(TextButton, t.card_source_review_video_continue),
      );
      await _until(
        tester,
        () =>
            !firstSession.isReview &&
            firstHooks.debugIsPlaying &&
            (firstHooks.debugPositionMs ?? 0) >= pausedAt + 2000,
        reason: '继续观看按钮应立即恢复播放并真实推进，不可只改变横幅',
      );
      // Normal watching must look exactly like ordinary playback: the review
      // banner is a second top bar and has to be gone, not merely relabelled.
      expect(find.byType(SourceReviewBanner), findsNothing);
      final ObserveShot continuedShot = await captureFlutterFrame(
        tester,
        'source-review-video-watching',
      );
      expect(continuedShot.saved, isTrue);

      // Put ordinary viewing far from the source clip, so a stale saved clip
      // cannot accidentally satisfy the final persistence assertion.
      await firstHooks.debugSeekMs(18000);
      await _until(
        tester,
        () => (firstHooks.debugPositionMs ?? 0) >= 19000,
        reason: '继续观看后的真实播放应推进到新的观看位置',
      );
      await firstHooks.debugPause();
      final int normalPosition = firstHooks.debugPositionMs!;
      // Re-opening the same card link is the supported way back to the clip.
      await _finish(tester, openCardSource(ref: ref, link: link));
      await _until(tester, () {
        final VideoFushiTestHooks? hooks = _hooks(tester);
        if (hooks == null || identical(hooks, firstHooks)) return false;
        return (hooks.debugDurationMs ?? 0) > 40000 &&
            ((hooks.debugPositionMs ?? -10000) - _clipStartMs).abs() < 1000;
      }, reason: '回到卡片片段应新建隔离回看，并重新定位到 5s');
      expect(_session(tester), isNot(same(firstSession)));
      expect(_session(tester).isReview, isTrue);
      expect(_hooks(tester)!.debugIsPlaying, isFalse);
      final VideoBookRow saved = (await videos.getByBookUid(_bookUid))!;
      expect(saved.lastPositionMs, greaterThanOrEqualTo(normalPosition - 1000));
      expect(saved.lastPositionMs, lessThan(30000));
      expect(saved.completedAt, before.completedAt);
      final int normalStats = await _count(db, 'study_segments');
      expect(normalStats, greaterThan(statsBefore));
      final String? normalCoverage = await db.getPref(
        videoWatchCoveragePrefKey(_bookUid),
      );
      expect(normalCoverage, isNot(coverageBefore));

      await _hooks(tester)!.debugPlay();
      await _until(
        tester,
        () => (_hooks(tester)?.debugPositionMs ?? 0) >= _clipStartMs + 1500,
        reason: '第二次回看片段应可播放',
      );
      bool closed = false;
      await _finish(
        tester,
        ExternalMediaNavigation.instance.closeActive().then(
              (bool result) => closed = result,
            ),
      );
      expect(closed, isTrue);
      expect(find.byType(VideoFushiPage), findsNothing);
      expect(
        (await videos.getByBookUid(_bookUid))!.lastPositionMs,
        saved.lastPositionMs,
      );
      expect(await _count(db, 'study_segments'), normalStats);
      expect(
        await db.getPref(videoWatchCoveragePrefKey(_bookUid)),
        normalCoverage,
      );
      debugPrint(
        '[video-source-itest] PASS clip=$_clipStartMs '
        'normalSaved=${saved.lastPositionMs} stats=$normalStats',
      );
    },
  );
}
