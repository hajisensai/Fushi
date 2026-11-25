import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// vendored media_kit_video 的三份 `VideoOutput.swift`（iOS 实际编译的是
/// `ios/Classes/plugin/common`，另两份保持逐字节一致）。
const List<String> kVideoOutputSwiftCopies = <String>[
  '../third_party/media_kit_video/ios/Classes/plugin/common/VideoOutput.swift',
  '../third_party/media_kit_video/common/darwin/Classes/plugin/VideoOutput.swift',
  '../third_party/media_kit_video/macos/Classes/plugin/common/VideoOutput.swift',
];

const String kControllerPath =
    'lib/src/media/video/video_player_controller.dart';

/// 拍板台 42UUu_kcwD：视频设置「后台继续播放声音」（默认关）。
///
/// 开着时手机 / 平板进真后台（`paused`）不暂停，只把视频轨挂起（`vid=no`），回前台
/// 还原；关着时维持 BUG-2544 的「进后台暂停、回前台续播」。iOS 不许 app 进后台后再
/// 提交 OpenGL ES 命令，vendored `VideoOutput.swift` 另有一道原生闸。
///
/// media_kit/libmpv 在测试宿主起不来（与 `video_background_resume_guard_test.dart`
/// 同一理由），这里测纯判据真值表 + 接线 / 原生补丁的源码守卫。
void main() {
  group('shouldKeepAudioInBackground', () {
    test('开关开 + 移动端 → 后台继续放声音', () {
      expect(
        VideoFushiPage.shouldKeepAudioInBackground(
          backgroundPlayEnabled: true,
          isMobile: true,
        ),
        isTrue,
      );
    });

    test('开关关（默认）→ 照 BUG-2544 暂停', () {
      expect(
        VideoFushiPage.shouldKeepAudioInBackground(
          backgroundPlayEnabled: false,
          isMobile: true,
        ),
        isFalse,
      );
    });

    test('桌面 → 不受开关影响', () {
      expect(
        VideoFushiPage.shouldKeepAudioInBackground(
          backgroundPlayEnabled: true,
          isMobile: false,
        ),
        isFalse,
      );
      expect(
        VideoFushiPage.shouldKeepAudioInBackground(
          backgroundPlayEnabled: false,
          isMobile: false,
        ),
        isFalse,
      );
    });
  });

  group('backgroundVideoRestoreTarget', () {
    test('同一部 → 还原挂起前的轨号', () {
      expect(
        VideoPlayerController.backgroundVideoRestoreTarget(
          suspendedVid: '2',
          sameLoad: true,
        ),
        '2',
      );
      expect(
        VideoPlayerController.backgroundVideoRestoreTarget(
          suspendedVid: 'auto',
          sameLoad: true,
        ),
        'auto',
      );
    });

    test('挂起前本就没有视频轨 → 不动', () {
      expect(
        VideoPlayerController.backgroundVideoRestoreTarget(
          suspendedVid: 'no',
          sameLoad: true,
        ),
        isNull,
      );
    });

    test('后台期间换了片 → auto（旧轨号对新片无意义）', () {
      expect(
        VideoPlayerController.backgroundVideoRestoreTarget(
          suspendedVid: '2',
          sameLoad: false,
        ),
        'auto',
      );
      expect(
        VideoPlayerController.backgroundVideoRestoreTarget(
          suspendedVid: 'no',
          sameLoad: false,
        ),
        'auto',
      );
    });
  });

  group('页面接线', () {
    final String src = readVideoFushiSource();
    final String code = maskCommentsAndScriptLines(src);

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
      final int end = src.indexOf(endSig, start + startSig.length);
      expect(end, greaterThan(start), reason: 'missing $endSig');
      return code.substring(start, end);
    }

    test('开着开关时挂起视频轨而不是暂停，且不置续播标记', () {
      final String body = region(
        'void _pauseForBackground() {',
        'void _resumeAfterBackgroundIfNeeded() {',
      );
      final int takeover = body.indexOf(
        'VideoFushiPage.shouldPauseForBackground(',
      );
      final int keep = body.indexOf(
        'VideoFushiPage.shouldKeepAudioInBackground(',
      );
      final int suspend = body.indexOf('suspendVideoForBackground()');
      final int mark = body.indexOf('_pausedForBackground = true');
      final int pause = body.indexOf('controller.pause()');
      expect(takeover, greaterThanOrEqualTo(0));
      // 只有「正在播」才谈得上后台继续放；用户自己暂停后切走的仍是暂停。
      expect(keep, greaterThan(takeover), reason: '先判是否接管，再判后台放声音');
      expect(suspend, greaterThan(keep));
      expect(body.contains('appModel.videoBackgroundPlay'), isTrue);
      // 挂起分支必须在置标记 / 暂停之前 return，否则回前台会被当成「我们停的」再 play。
      expect(mark, greaterThan(suspend));
      expect(pause, greaterThan(suspend));
      final String keepBranch = body.substring(suspend, mark);
      expect(keepBranch.contains('return;'), isTrue);
    });

    test('回前台先还原视频轨，再刷解码链', () {
      final String body = region(
        'case AppLifecycleState.resumed:',
        'case AppLifecycleState.detached:',
      );
      final int restore = body.indexOf('resumeVideoAfterBackground()');
      final int refresh = body.indexOf('_refreshDecodeAfterResumeIfNeeded()');
      expect(restore, greaterThanOrEqualTo(0), reason: '挂起的视频轨必须在回前台还原');
      expect(refresh, greaterThan(restore), reason: '轨还关着时原地 seek 重建不了画面');
    });

    test('挂起只在 paused 触发（hidden 不碰）', () {
      final String body = region(
        'void didChangeAppLifecycleState(AppLifecycleState state) {',
        'case AppLifecycleState.resumed:',
      );
      expect(body.contains('suspendVideoForBackground'), isFalse);
      expect(
        body.contains(
          'if (state == AppLifecycleState.paused) _pauseForBackground();',
        ),
        isTrue,
      );
    });

    test('后台放声音时挂进系统媒体会话，回前台让出（拍板台 42UUu_kcwD-media）', () {
      final String pauseBody = region(
        'void _pauseForBackground() {',
        'void _resumeAfterBackgroundIfNeeded() {',
      );
      final int suspend = pauseBody.indexOf('suspendVideoForBackground()');
      final int enter = pauseBody.indexOf('_enterBackgroundAudio(controller)');
      final int mark = pauseBody.indexOf('_pausedForBackground = true');
      expect(enter, greaterThan(suspend));
      expect(mark, greaterThan(enter), reason: '只在后台放声音分支里认领会话');
      final String resumed = region(
        'case AppLifecycleState.resumed:',
        'case AppLifecycleState.detached:',
      );
      final int leave = resumed.indexOf('_leaveBackgroundAudio()');
      final int restart = resumed.indexOf('_watchTracker?.start()');
      expect(leave, greaterThanOrEqualTo(0));
      expect(restart, greaterThan(leave), reason: '先恢复前台口径再续表');
      final String enterBody = region(
        'void _enterBackgroundAudio(VideoPlayerController controller) {',
        'void _leaveBackgroundAudio() {',
      );
      expect(enterBody.contains('MediaSessionOwner.video'), isTrue);
      expect(enterBody.contains('countSubtitleChars = false'), isTrue);
      expect(enterBody.contains('setLifecycleStopped(false)'), isTrue);
      expect(code.contains('_backgroundMediaSession?.dispose()'), isTrue);
    });

    test('判据不在页面里另写一份', () {
      expect(
        code.contains('VideoFushiPage.shouldKeepAudioInBackground('),
        isTrue,
      );
    });
  });

  group('控制器', () {
    final String src = File(kControllerPath).readAsStringSync();
    final String code = maskCommentsAndScriptLines(
      src.replaceAll('\r\n', '\n'),
    );

    test('还原时挂起标记在第一个 return 之前无条件清掉', () {
      final int start = code.indexOf(
        'Future<void> resumeVideoAfterBackground() async {',
      );
      expect(start, greaterThanOrEqualTo(0));
      final int end = code.indexOf(
        'static String? backgroundVideoRestoreTarget(',
        start,
      );
      expect(end, greaterThan(start));
      final String body = code.substring(start, end);
      final int clear = body.indexOf('_backgroundVideoSuspend = null');
      expect(clear, greaterThanOrEqualTo(0));
      expect(body.indexOf('return'), greaterThan(clear));
      expect(body.contains('backgroundVideoRestoreTarget('), isTrue);
    });

    test('挂起把 vid 设成 no', () {
      final int start = code.indexOf(
        'Future<void> suspendVideoForBackground() async {',
      );
      expect(start, greaterThanOrEqualTo(0));
      final int end = code.indexOf(
        'Future<void> resumeVideoAfterBackground() async {',
        start,
      );
      final String body = code.substring(start, end);
      expect(body.contains("setProperty('vid', 'no')"), isTrue);
    });
  });

  group('设置项', () {
    test('视频设置里有开关，默认关、只在移动端显示', () {
      final String schema = maskCommentsAndScriptLines(
        File(
          'lib/src/settings/settings_schema_video.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      final int start = schema.indexOf("id: 'video.playback.background_play'");
      expect(start, greaterThanOrEqualTo(0));
      final int end = schema.indexOf('SettingsSwitchItem(', start);
      final String item = schema.substring(start, end);
      expect(item.contains('visible: (_) => isMobilePlatform'), isTrue);
      expect(item.contains('defaultValue: false'), isTrue);
      expect(item.contains('setVideoBackgroundPlay('), isTrue);

      final String prefs = File(
        'lib/src/models/preferences_repository.dart',
      ).readAsStringSync();
      expect(
        prefs.contains("getPref('video_background_play', defaultValue: false)"),
        isTrue,
      );
    });
  });

  group('vendored VideoOutput.swift：iOS 后台不碰 GPU', () {
    test('三份拷贝逐字节一致', () {
      final List<String> texts = kVideoOutputSwiftCopies
          .map((String p) => File(p).readAsStringSync())
          .toList();
      for (final String t in texts.skip(1)) {
        expect(t, texts.first);
      }
    });

    final String swift = File(
      kVideoOutputSwiftCopies.first,
    ).readAsStringSync().replaceAll('\r\n', '\n');

    test('进后台的通知把 GL 工作挂起，回前台恢复并补画', () {
      final int enter = swift.indexOf(
        'UIApplication.didEnterBackgroundNotification',
      );
      final int fore = swift.indexOf(
        'UIApplication.willEnterForegroundNotification',
      );
      expect(enter, greaterThanOrEqualTo(0));
      expect(fore, greaterThan(enter));
      expect(
        swift.substring(enter, fore).contains('that.gpuSuspended = true'),
        isTrue,
      );
      final String foreBody = swift.substring(fore, fore + 600);
      expect(foreBody.contains('that.gpuSuspended = false'), isTrue);
      expect(foreBody.contains('that.updateCallback()'), isTrue);
    });

    test('resize / render 都包在 beginGpuWork…endGpuWork 里，且锁内不跳主线程', () {
      final int start = swift.indexOf('private func _updateCallback() {');
      expect(start, greaterThanOrEqualTo(0));
      final int end = swift.indexOf('private var videoSize: CGSize', start);
      final String body = swift.substring(start, end);
      for (final String call in <String>[
        'texture.resize(size)',
        'texture.render(size)',
      ]) {
        final int at = body.indexOf(call);
        expect(at, greaterThanOrEqualTo(0), reason: call);
        final int begin = body.lastIndexOf('beginGpuWork()', at);
        final int finish = body.indexOf('endGpuWork()', at);
        expect(begin, greaterThanOrEqualTo(0), reason: '$call 前要 beginGpuWork');
        expect(finish, greaterThan(at), reason: '$call 后要 endGpuWork');
        // 锁跨过 DispatchQueue.main.sync 会与主线程通知里的拿锁互等。
        expect(
          body.substring(begin, finish).contains('DispatchQueue.main.sync'),
          isFalse,
          reason: '$call 的 GPU 锁区间内不能跳主线程',
        );
      }
    });
  });
}
