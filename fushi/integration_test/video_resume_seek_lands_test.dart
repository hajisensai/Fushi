// 真机/模拟器集成测试：打开有断点的视频后，恢复 seek 必须**落地并保持**。
//
// 复现用户报告（Android）：「点进去一瞬间还能看到我原本进度的一帧，然后踢回开头」。
// 症状是恢复 seek 已经生效（画面跳到断点帧）但随后位置被重置回 0 —— 与 BUG-179
// 记录的「seek 落不了地」是同一根因的两种表现（那次只补了守护宽限，没修 seek 本身）。
//
// 本测试跑真实 libmpv：造一段 90s 视频 → seed `lastPositionMs=45000` 的 VideoBook →
// 打开 [VideoFushiPage] → 密集采样 8s 位置序列 → 断言
//   ① 恢复 seek 至少落地过一次（出现过 >=40s 的位置）；
//   ② 落地之后位置**不得**回落到开头（<5s）。
// ② 正是用户症状：seek 落地后被 media_kit `open()` 尾部的 `playlist-pos` 重载踢回 0。
//
// 运行（Android 模拟器 / 真机）——素材必须在**安装之后**推，`flutter test -d` 在 APK
// 变更时会卸载重装、清空 app 外部文件目录：
//   ffmpeg -y -f lavfi -i testsrc=size=320x240:rate=10 -f lavfi -i anullsrc=r=44100:cl=mono \
//          -t 90 -c:v mpeg4 -c:a aac resume_probe.mp4
//   flutter build apk --debug --target-platform android-x64 --no-pub
//   adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
//   adb push resume_probe.mp4 /sdcard/Android/data/app.fushi.reader/files/resume_probe.mp4
//   flutter test integration_test/video_resume_seek_lands_test.dart -d emulator-5556 --no-pub
// 运行（Windows 离屏，素材由 ffmpeg 现造，无需预置）：
//   .\fushi\tool\run_windows_itest.ps1 integration_test\video_resume_seek_lands_test.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/media_fixtures.dart';
import 'test_helpers.dart';

/// 断点位置：距片头足够远，回落到开头无法与「seek 未落地」混淆。
const int _kResumeMs = 45000;

/// 判定「seek 已落地」的阈值（略低于断点，容忍解码对齐到关键帧的回退）。
const int _kLandedMs = 40000;

/// 判定「被踢回开头」的阈值。
const int _kRewoundMs = 5000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'resume seek lands and is not rewound to the start',
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

        // 90s 测试视频：断点 45s 处在片中，seek 目标明确。
        //
        // Android 模拟器（x86_64）没有 FFmpegKit native 库，[generateTestVideo] 必失败，
        // 故优先用外部预置素材（`adb push` 到 app 外部文件目录，无需存储权限即可读）：
        //   adb push resume_probe.mp4 \
        //     /sdcard/Android/data/app.fushi.reader/files/resume_probe.mp4
        // 桌面/有 ffmpeg 的环境仍走 [generateTestVideo] 自给自足。
        const String prepushed =
            '/sdcard/Android/data/app.fushi.reader/files/resume_probe.mp4';
        final File videoFile;
        if (Platform.isAndroid) {
          // Android 上**只**认预置素材：FFmpegKit 在模拟器必失败，落回
          // [generateTestVideo] 只会抛出与本 bug 无关的异常，把「素材没准备好」
          // 伪装成「修复失效」。缺素材时明确 fail 并给出准备命令，不误导判绿。
          //
          // 注意 `flutter test -d` 在 APK 变更时会卸载重装，app 外部文件目录随之
          // 清空 —— 素材必须在**安装之后**推：
          //   adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
          //   adb push resume_probe.mp4 $prepushed
          expect(File(prepushed).existsSync(), isTrue,
              reason: '缺测试素材 $prepushed。先 adb install 再 adb push（重装会清空该目录）；'
                  '素材 = 90s testsrc mp4，见本文件头部注释。');
          videoFile = File(prepushed);
        } else {
          final Directory dir =
              await Directory.systemTemp.createTemp('hibiki_resume_seek_');
          videoFile = await generateTestVideo(
            outPath: '${dir.path}${Platform.pathSeparator}resume_probe.mp4',
            duration: const Duration(seconds: 90),
          );
        }
        const String bookUid = 'video/itest-resume-seek-lands';
        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: const Value(bookUid),
          title: const Value('resume seek probe'),
          videoPath: Value(videoFile.absolute.path),
          lastPositionMs: const Value(_kResumeMs),
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

        bool ready = false;
        for (int i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (readHooks()?.debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        expect(ready, isTrue, reason: '控制器应在 load 后就绪');

        // 密集采样 8s（覆盖 _waitUntilSeekable 5s 上限 + seek 落地 + 起播）。
        // 页面 _applyLoad 传 autoPlay:true，无需手动 play。
        final List<int> samples = <int>[];
        for (int i = 0; i < 64; i++) {
          await tester.pump(const Duration(milliseconds: 125));
          final int? pos = readHooks()?.debugPositionMs;
          if (pos != null) samples.add(pos);
        }
        debugPrint('[resume-seek] duration=${readHooks()?.debugDurationMs} '
            'samples=$samples');

        final int landedAt = samples.indexWhere((int p) => p >= _kLandedMs);
        expect(landedAt, greaterThanOrEqualTo(0),
            reason: '恢复 seek 从未落地（位置从未到达 ${_kLandedMs}ms）。samples=$samples');

        final List<int> afterLanding = samples.sublist(landedAt);
        final int rewoundAt =
            afterLanding.indexWhere((int p) => p < _kRewoundMs);
        expect(rewoundAt, -1,
            reason: 'seek 落地后位置被踢回开头（第 $rewoundAt 个采样 = '
                '${rewoundAt >= 0 ? afterLanding[rewoundAt] : -1}ms）。'
                'samples=$samples');

        await navigator.maybePop();
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
        }
        debugPrint('[resume-seek] non-fatal framework errors=${caught.length}');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}
