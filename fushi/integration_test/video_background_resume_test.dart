// 真机/模拟器集成测试：视频切到后台被暂停后，回前台必须**自动续上**。
//
// 复现用户报告：「视频切屏会暂停，切回来没续上」。根因是一条不对称的链——vendored
// media_kit 的 `Video` 默认 `pauseUponEnteringBackgroundMode: true` +
// `resumeUponEnteringForegroundMode: false`，进后台把正在播的视频停掉并把「暂停前在播」
// 记进自己的私有字段，回前台那一支却被默认 false 整个跳过；而视频页的 `resumed` 分支
// 按「真后台不暂停播放」的旧假设写成，既不 play 也读不到那个私有字段（BUG-2544）。
//
// 本测试跑真实 libmpv：造一段 60s 视频 → 打开 [VideoFushiPage] 等它起播 →
// 按真机序列投 `inactive → hidden → paused` → 断言
//   ① 真的停住了（播放态 false 且位置不再前进）；
//   ② 投 `hidden → inactive → resumed` 后**自动恢复播放**且位置继续前进。
// ② 正是用户症状：修复前这里会停在暂停，位置一动不动。
//
// 生命周期用 `channelBuffers.push('flutter/lifecycle', ...)` 投递，与平台 embedder 真机
// 发的是同一条通道消息，故 Windows 上跑出的结论对移动端成立（判据本身无平台门控）。
// **paused 期间不 pump**：SchedulerBinding 在 paused 会关掉帧调度，live binding 的 pump
// 会一直等不到 vsync；那段用 `runAsync` 等真实时间，读页面 state 不需要新帧。
//
// 运行（Windows 离屏，素材由 ffmpeg 现造，无需预置）：
//   .\fushi\tool\run_windows_itest.ps1 integration_test\video_background_resume_test.dart
// 运行（Android 模拟器 / 真机）——素材必须在**安装之后**推，`flutter test -d` 在 APK
// 变更时会卸载重装、清空 app 外部文件目录：
//   ffmpeg -y -f lavfi -i testsrc=size=320x240:rate=10 -f lavfi -i anullsrc=r=44100:cl=mono \
//          -t 60 -c:v mpeg4 -c:a aac background_resume_probe.mp4
//   flutter build apk --debug --target-platform android-x64 --no-pub
//   adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
//   adb push background_resume_probe.mp4 \
//     /sdcard/Android/data/app.fushi.reader/files/background_resume_probe.mp4
//   flutter test integration_test/video_background_resume_test.dart -d emulator-5556 --no-pub
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/media_fixtures.dart';
import 'test_helpers.dart';

/// 后台停留期间允许的位置漂移（ms）。暂停命令是 fire-and-forget，落地前可能还解出几帧；
/// 但真没停住的话这段时间会走掉整整一秒以上，两者不会混淆。
const int _kPausedDriftToleranceMs = 350;

/// 回前台后判「确实在继续播」的位置增量（ms）。
const int _kResumedAdvanceMs = 200;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'playback pauses on entering background and resumes on returning',
    (WidgetTester tester) async {
      final List<String> caught = <String>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        caught.add(details.exceptionAsString());
      };
      try {
        app.main(const <String>[]);
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        // 60s 测试视频：足够长，暂停/恢复窗口都落在片中，不会撞到片尾自然停止。
        //
        // Android 模拟器（x86_64）没有 FFmpegKit native 库，[generateTestVideo] 必失败，
        // 故那边只认预置素材（见文件头的 adb 命令）；桌面自给自足。
        const String prepushed = '/sdcard/Android/data/app.fushi.reader/files/'
            'background_resume_probe.mp4';
        final File videoFile;
        if (Platform.isAndroid) {
          expect(File(prepushed).existsSync(), isTrue,
              reason: '缺测试素材 $prepushed。先 adb install 再 adb push（重装会清空该'
                  '目录）；素材 = 60s testsrc mp4，见本文件头部注释。');
          videoFile = File(prepushed);
        } else {
          final Directory dir =
              await Directory.systemTemp.createTemp('fushi_bg_resume_');
          videoFile = await generateTestVideo(
            outPath:
                '${dir.path}${Platform.pathSeparator}background_resume_probe.mp4',
            duration: const Duration(seconds: 60),
          );
        }
        const String bookUid = 'video/itest-background-resume';
        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: const Value(bookUid),
          title: const Value('background resume probe'),
          videoPath: Value(videoFile.absolute.path),
        ));

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage(bookUid: bookUid, repo: repo),
        )));

        VideoFushiTestHooks? readHooks() {
          if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
          return tester.state<State<VideoFushiPage>>(
              find.byType(VideoFushiPage)) as VideoFushiTestHooks;
        }

        /// 真实时间等待（不驱动帧）：paused 期间帧调度被关掉，pump 会等不到 vsync。
        Future<void> waitReal(int ms) => tester
            .runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

        /// 按真机序列投递生命周期状态（与 embedder 发的是同一条通道消息）。
        Future<void> sendLifecycle(List<String> states) async {
          for (final String state in states) {
            tester.binding.channelBuffers.push(
              'flutter/lifecycle',
              const StringCodec().encodeMessage('AppLifecycleState.$state'),
              (ByteData? _) {},
            );
          }
          await waitReal(400);
        }

        // 页面 _applyLoad 传 autoPlay:true，等它真的播起来（位置在推进）。
        bool playing = false;
        for (int i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          final VideoFushiTestHooks? hooks = readHooks();
          if (hooks != null &&
              hooks.debugIsPlaying &&
              (hooks.debugPositionMs ?? 0) > 0) {
            playing = true;
            break;
          }
        }
        expect(playing, isTrue, reason: '视频应在打开后自动起播（本测试的前提，不是被测行为）');
        final int beforeBackgroundMs = readHooks()!.debugPositionMs!;

        // ── 切到后台 ─────────────────────────────────────────────────
        await sendLifecycle(<String>['inactive', 'hidden', 'paused']);
        await waitReal(400);
        final bool pausedState = readHooks()!.debugIsPlaying;
        final int pausedAtMs = readHooks()!.debugPositionMs!;
        await waitReal(1200);
        final int stillPausedAtMs = readHooks()!.debugPositionMs!;
        debugPrint('[bg-resume] before=$beforeBackgroundMs '
            'paused(playing=$pausedState)=$pausedAtMs → $stillPausedAtMs');

        expect(pausedState, isFalse, reason: '进真后台（paused）应暂停播放');
        expect(stillPausedAtMs - pausedAtMs, lessThan(_kPausedDriftToleranceMs),
            reason: '后台期间位置不该继续前进（暂停没落地）：'
                '$pausedAtMs → $stillPausedAtMs');

        // ── 切回前台 ─────────────────────────────────────────────────
        await sendLifecycle(<String>['hidden', 'inactive', 'resumed']);
        await waitReal(800);
        await tester.pump(const Duration(milliseconds: 200));
        final bool resumedState = readHooks()!.debugIsPlaying;
        final int resumedAtMs = readHooks()!.debugPositionMs!;
        await waitReal(1200);
        await tester.pump(const Duration(milliseconds: 200));
        final int advancedToMs = readHooks()!.debugPositionMs!;
        debugPrint('[bg-resume] resumed(playing=$resumedState)=$resumedAtMs '
            '→ $advancedToMs');

        expect(resumedState, isTrue,
            reason: '回前台应自动续播（BUG-2544：修复前停在暂停，这里为 false）');
        expect(advancedToMs - resumedAtMs, greaterThan(_kResumedAdvanceMs),
            reason: '回前台后位置应继续前进：$resumedAtMs → $advancedToMs');

        await navigator.maybePop();
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
        }
        debugPrint('[bg-resume] non-fatal framework errors=${caught.length}');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}
