import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/stats/interval_coverage.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/media_fixtures.dart';
import 'test_helpers.dart';

/// BUG-2108 真机 E2E：观看时长只计首次覆盖——拖回重听的那段不计。
///
/// 真播放器（media_kit / libmpv）播一段 30s 测试视频：先播到 ≥ 6s，拖回 3s 重听到
/// ≥ 9s（3s 重听 + 3s 新内容），暂停关页。断言：
///  * `study_segments` 该视频段时长 ≈ 首次覆盖的 9s（容差内），且**明显小于**播放态
///    墙钟（≈ 12s+）——旧口径按播放态整窗计会得到 ≥ 12s；
///  * 覆盖并集已落偏好表，是一段连续区间、总长 ≈ 9s。
///
/// 跑法（Windows 离屏）：
///   powershell -File fushi/tool/run_windows_itest.ps1 \
///     -Target integration_test/video_watch_coverage_itest.dart
const String _kBookUid = 'video/itest-watch-coverage';
const int _kFirstPassMs = 6000;
const int _kRewindToMs = 3000;
const int _kSecondPassMs = 9000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('rewind replay is not credited; coverage persists', (
    WidgetTester tester,
  ) async {
    app.main(const <String>[]);
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    final AppModel appModel = container.read(appProvider);
    final FushiDatabase db = appModel.database;
    final VideoBookRepository repo = VideoBookRepository(db);

    final Directory dir =
        await Directory.systemTemp.createTemp('fushi_watch_coverage_');
    final File videoFile = await generateTestVideo(
      outPath: '${dir.path}${Platform.pathSeparator}coverage_probe.mp4',
      duration: const Duration(seconds: 30),
    );
    await repo.saveVideoBook(VideoBooksCompanion(
      bookUid: const Value(_kBookUid),
      title: const Value('watch coverage probe'),
      videoPath: Value(videoFile.absolute.path),
      lastPositionMs: const Value(0),
    ));
    // 干净起点：上一轮残留的覆盖 / 段会让「首次覆盖」失真。
    await db.deleteVideoStatisticsForIdentity(
      title: 'watch coverage probe',
      bookUid: _kBookUid,
    );

    final NavigatorState navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push<void>(MaterialPageRoute<void>(
      builder: (_) => VideoFushiPage(bookUid: _kBookUid, repo: repo),
    )));

    VideoFushiTestHooks? readHooks() {
      if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
      return tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
          as VideoFushiTestHooks;
    }

    bool ready = false;
    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (readHooks()?.debugPositionMs != null) {
        ready = true;
        break;
      }
    }
    expect(ready, isTrue, reason: '控制器应在 load 后就绪');

    /// 采样直到位置 ≥ [targetMs]（最多 [maxMs] 墙钟）；返回首次看到位置推进的墙钟时刻。
    Future<DateTime?> playUntil(int targetMs, {int maxMs = 15000}) async {
      DateTime? firstAdvance;
      final Stopwatch sw = Stopwatch()..start();
      int? last;
      while (sw.elapsedMilliseconds < maxMs) {
        await tester.pump(const Duration(milliseconds: 125));
        final int? pos = readHooks()?.debugPositionMs;
        if (pos != null && last != null && pos > last) {
          firstAdvance ??= DateTime.now();
        }
        last = pos;
        if (pos != null && pos >= targetMs) return firstAdvance;
      }
      fail('位置在 ${maxMs}ms 内没到 $targetMs（最后 $last）');
    }

    // 第一遍：0 → ≥ 6s（自动起播）。
    final DateTime? playStart = await playUntil(_kFirstPassMs);
    expect(playStart, isNotNull);
    // 拖回 3s 重听，再播到 ≥ 9s：3s 重听（已覆盖）+ 3s 新内容。
    await readHooks()!.debugSeekMs(_kRewindToMs);
    await tester.pump(const Duration(milliseconds: 500));
    await playUntil(_kSecondPassMs);
    final int wallPlayedMs =
        DateTime.now().difference(playStart!).inMilliseconds;
    await readHooks()!.debugPause();
    await tester.pump(const Duration(milliseconds: 300));

    await navigator.maybePop();
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
    }
    // dispose 里 tracker.stop() 是 fire-and-forget：给落库一点时间。
    await tester.pump(const Duration(seconds: 2));

    final List<StudySegmentRow> segments = await db.getStudySegmentsForMedia(
      mediaKind: kActivityMediaVideo,
      mediaKey: _kBookUid,
    );
    final int credited = segments.fold(
      0,
      (int sum, StudySegmentRow s) => sum + s.durationMs,
    );
    final String? coverageJson = await db.getPref(
      videoWatchCoveragePrefKey(_kBookUid),
    );
    final IntervalCoverage coverage = IntervalCoverage.fromJson(coverageJson);
    debugPrint(
      '[watch-coverage] wallPlayed=${wallPlayedMs}ms '
      'credited=${credited}ms segments=${segments.length} '
      'coverage=$coverageJson',
    );

    // 首次覆盖 ≈ 9s：下限放宽给起播 / 采样节奏，上限卡在「重听那 3s 不计」之内。
    expect(credited, greaterThanOrEqualTo(_kSecondPassMs - 2500),
        reason: '首次覆盖的 ~9s 内容应计入');
    expect(credited, lessThanOrEqualTo(_kSecondPassMs + 1500),
        reason: '重听的 3s 不该计（旧口径会记 ≥ 12s）');
    expect(credited, lessThan(wallPlayedMs - 2000),
        reason: '计时必须明显小于播放态墙钟 ${wallPlayedMs}ms（差 = 重听时长）');
    expect(coverageJson, isNotNull, reason: '覆盖并集须落偏好表');
    expect(coverage.ranges, hasLength(1), reason: '0..9s 连续一段');
    expect(coverage.total, greaterThanOrEqualTo(_kSecondPassMs - 1500));
    expect(coverage.total, lessThanOrEqualTo(_kSecondPassMs + 2000));
  });
}
