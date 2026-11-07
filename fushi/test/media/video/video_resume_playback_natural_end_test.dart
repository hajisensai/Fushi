// BUG-4131 / 反馈 ji9GSMzD4E：未开单视频循环，视频播完、等「N 秒后播放下一集」倒计时的这几秒里，
// 当前视频会自己从头重播。
//
// 机制：media_kit 的 `Player.play()` 在 `state.completed` 态会先 seek 回 0 再播（「播完
// 再按播放 = 重看」）；视频页的自动续播路径（查词浮层关闭 / 选词光标退出 / 回前台 /
// 编辑对话框关闭）此前直接调 [VideoPlayerController.play]，和用户显式播放共用一条路。
// 暂停是 fire-and-forget 的，片尾最后一刻起的查词「暂停没落地 EOF 先到」，回头的续播
// 就在 completed 态把视频播回开头。
//
// 修复把两种语义分开：[VideoPlayerController.play] 仍是用户显式播放；自动续播统一走
// [VideoPlayerController.resumePlayback]，媒体停在自然播完处时不执行。这里测两层：
// 控制器在真 `Player`（网页后端，`completed` 由页面上报推导）上的行为，以及视频页的自动
// 续播点全部改走新入口的接线守卫（视频页依赖 libmpv，无法 headless 起，见
// video_background_resume_guard_test.dart 同一理由）。

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_platform_player.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

const String _kPlayJs = 'window.__fushiWebVideo.play()';

WebVideoPlaybackState _state({required int pos, required bool paused}) =>
    parseWebVideoStatePayload(<String, Object?>{
      'type': 'state',
      'href': 'https://www.netflix.com/watch/1',
      'videoKey': 'nf-1',
      'hasVideo': true,
      't': pos,
      'paused': paused,
      'dur': 600000,
      'vw': 1920,
      'vh': 1080,
      'rate': 1,
      'fs': false,
      'title': 't',
    })!;

Future<
  ({
    VideoPlayerController controller,
    WebVideoPlatformPlayer platform,
    List<String> js,
  })
>
_openWeb() async {
  final List<String> js = <String>[];
  final WebVideoPlatformPlayer platform = WebVideoPlatformPlayer(
    evaluate: (String s) async => js.add(s),
  );
  final VideoPlayerController controller = VideoPlayerController();
  await controller.loadWeb(
    platform: platform,
    bookUid: 'video/stream/nf:1',
    pageUrl: 'https://www.netflix.com/watch/1',
  );
  return (controller: controller, platform: platform, js: js);
}

Future<void> _disposeWeb(
  WidgetTester tester,
  VideoPlayerController controller,
) async {
  controller.dispose();
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('VideoPlayerController.resumePlayback（自动续播）', () {
    testWidgets('媒体停在自然播完处：不下发播放，不把视频播回开头', (WidgetTester tester) async {
      final (:controller, :platform, :js) = await _openWeb();
      platform.applySnapshot(_state(pos: 600000, paused: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.isAtNaturalEnd, isTrue);
      js.clear();

      final bool resumed = await controller.resumePlayback();

      expect(resumed, isFalse);
      expect(
        js,
        isNot(contains(_kPlayJs)),
        reason: '播完后的自动续播会被底层 play() 变成「seek 回 0 重播」（ji9GSMzD4E）',
      );
      expect(controller.isPlaying, isFalse);
      await _disposeWeb(tester, controller);
    });

    testWidgets('片中被临时暂停：照常续播', (WidgetTester tester) async {
      final (:controller, :platform, :js) = await _openWeb();
      platform.applySnapshot(_state(pos: 120000, paused: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.isAtNaturalEnd, isFalse);
      js.clear();

      final bool resumed = await controller.resumePlayback();

      expect(resumed, isTrue);
      expect(js, contains(_kPlayJs));
      await _disposeWeb(tester, controller);
    });

    testWidgets('播完后用户 seek 回片中：不再算播完，续播照常', (WidgetTester tester) async {
      final (:controller, :platform, :js) = await _openWeb();
      platform.applySnapshot(_state(pos: 600000, paused: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.isAtNaturalEnd, isTrue);

      platform.applySnapshot(_state(pos: 300000, paused: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.isAtNaturalEnd, isFalse);
      js.clear();

      expect(await controller.resumePlayback(), isTrue);
      expect(js, contains(_kPlayJs));
      await _disposeWeb(tester, controller);
    });

    testWidgets('用户显式播放（play）在播完处照常下发：「播完再按播放 = 重看」不变', (
      WidgetTester tester,
    ) async {
      final (:controller, :platform, :js) = await _openWeb();
      platform.applySnapshot(_state(pos: 600000, paused: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.isAtNaturalEnd, isTrue);
      js.clear();

      await controller.play();

      expect(js, contains(_kPlayJs));
      await _disposeWeb(tester, controller);
    });

    test('未 load：no-op 且返回 false', () async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      expect(controller.isAtNaturalEnd, isFalse);
      expect(await controller.resumePlayback(), isFalse);
    });
  });

  group('视频页自动续播点只走 resumePlayback（接线守卫）', () {
    final String corpus = readVideoFushiSource();

    /// 「非用户发起的续播」全集：页内替某个临时暂停把播放续上的地方。新增这类路径必须
    /// 进这张表并走 [VideoPlayerController.resumePlayback]。
    const Map<String, String> autoResumeSites = <String, String>{
      'void _popNestedPopupAt(': '查词浮层整栈关闭（含悬停离开自动关）',
      'void _finishSubtitleCaretSession(': '选词光标会话结束',
      'void _resumeAfterBackgroundIfNeeded()': '回前台续播',
      'Future<void> _editCueText(': '编辑字幕对话框关闭',
    };

    for (final MapEntry<String, String> site in autoResumeSites.entries) {
      test('${site.value}：调 resumePlayback，不直接 play', () {
        final String body = maskCommentsAndStrings(
          methodBody(corpus, site.key),
        );
        expect(
          body,
          contains('.resumePlayback()'),
          reason: '${site.value} 是自动续播，必须走播完即不执行的入口',
        );
        expect(
          RegExp(r'\.play\(\)').hasMatch(body),
          isFalse,
          reason: '${site.value} 直调 play()：媒体播完时会把视频从头重播（ji9GSMzD4E）',
        );
      });
    }
  });
}
