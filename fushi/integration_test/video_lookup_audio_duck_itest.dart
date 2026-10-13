// Android 真机 / 模拟器探针：视频播放中查词自动发音，视频音量会不会被 duck（反馈
// #D5hTCEYMmT）。本测试只负责「开视频 → 查词 → 走生产自动发音入口出声 → 停留」，
// 系统侧的音频焦点栈 / 播放器 duck 状态由宿主并行轮询 `adb shell dumpsys audio` 取证
// （见 docs/bugs/BUG-3311），测试内打印带毫秒时间戳的 `[duck]` 标记供对齐。修复后
// 「Events log: focus commands」里在 `[duck]` 时刻不应再出现 app.fushi.reader 的
// `AudioFocusDelegate ... req=3`，发音走 `type:android.media.MediaPlayer`。
//
// API 36 x86_64 模拟器在视频页请求横屏时 system_server 会因 GPU 仿真断言
// （hasReadColorBufferDma）崩溃，先 `adb shell wm set-ignore-orientation-request true`，
// 测完改回 false。
//
// 运行（素材必须在**安装之后**推，`flutter test -d` 重装会清空 app 外部文件目录；
// 测试会等素材最多 2 分钟）：
//   ffmpeg -f lavfi -i testsrc=size=320x240:rate=10 -f lavfi -i sine=frequency=440 \
//          -t 90 -c:v mpeg4 -c:a aac -shortest duck_probe.mp4
//   ffmpeg -f lavfi -i sine=frequency=880 -t 1.5 -c:a libmp3lame word.mp3
//   adb push duck_probe.mp4 word.mp3 /sdcard/Android/data/app.fushi.reader/files/
//   flutter test integration_test/video_lookup_audio_duck_itest.dart -d <device> --no-pub
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

const String _kDir = '/sdcard/Android/data/app.fushi.reader/files';

void _mark(String what) =>
    debugPrint('[duck] ${DateTime.now().toIso8601String()} $what');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lookup word audio while video plays', (
    WidgetTester tester,
  ) async {
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    try {
      app.main(const <String>[]);
      expect(await waitForHome(tester), isTrue);
      FlutterError.onError = oldHandler;
      await tester.pump(const Duration(seconds: 2));
      expect(await seedDictionary(tester), isTrue);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final File video = File('$_kDir/duck_probe.mp4');
      final File word = File('$_kDir/word.mp3');
      // 宿主在 app 装好后才能推素材（重装清空外部文件目录），这里等它到位。
      for (
        int i = 0;
        i < 240 && !(video.existsSync() && word.existsSync());
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        video.existsSync() && word.existsSync(),
        isTrue,
        reason: '先 adb push duck_probe.mp4 / word.mp3（见文件头）',
      );
      const String bookUid = 'video/itest-lookup-audio-duck';
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>(bookUid),
          title: const Value<String>('lookup audio duck probe'),
          videoPath: Value<String>(video.absolute.path),
        ),
      );
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: bookUid, repo: repo),
          ),
        ),
      );

      VideoFushiTestHooks? hooks() {
        if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
            as VideoFushiTestHooks;
      }

      bool playing = false;
      for (int i = 0; i < 150 && !playing; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        final VideoFushiTestHooks? h = hooks();
        playing = h != null && h.debugIsPlaying && (h.debugPositionMs ?? 0) > 0;
      }
      expect(playing, isTrue, reason: '视频应自动起播（前提）');

      await hooks()!.debugLookupAt('testword', 0);
      final Finder popup = find.byWidgetPredicate(
        (Widget w) =>
            w is DictionaryPopupWebView && w.result.entries.isNotEmpty,
      );
      for (int i = 0; i < 60 && popup.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(popup, findsOneWidget);
      // 查词可能按设置暂停视频；探针要的是「视频在播时发音」。
      await hooks()!.debugPlay();
      await tester.pump(const Duration(seconds: 3));
      final DictionaryPopupWebViewState state = tester.state(popup);
      final String? url = await audioRefToWebViewUrl(word.path);
      expect(url, isNotNull);

      for (int round = 1; round <= 2; round++) {
        _mark('round$round play start');
        // 生产自动发音入口：autoReadWordUnified → popup.playWordAudioUrl。
        final bool ok = await state.playWordAudioUrl(url!);
        _mark(
          'round$round play reported ok=$ok '
          'videoPlaying=${hooks()!.debugIsPlaying} vol=${hooks()!.debugVolume}',
        );
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        _mark('round$round +10s videoPlaying=${hooks()!.debugIsPlaying}');
      }
      _mark('done');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
