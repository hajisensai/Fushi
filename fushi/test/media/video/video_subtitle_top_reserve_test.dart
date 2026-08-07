import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1069：视频顶部锚字幕（含强制置顶的副字幕）在控制条可见时盖住视频内嵌顶栏
/// （标题栏 + 右上角菜单）。修复：顶部锚字幕顶缘对 `controlsTopReserve` 取下限避让，
/// 与底部锚字幕避让进度条对称。
///
/// 分两层验证：
///  ① 纯几何函数 `videoSubtitleControlsTopReserve`（顶部 inset + 按钮行 + 呼吸间距）。
///  ② overlay 真行为：副字幕（强制置顶）的顶部 padding 在控制条可见时 = controlsTopReserve、
///     隐藏时落回用户基线 bottomPadding。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

void main() {
  test('① videoSubtitleControlsTopReserve = 顶部inset + 按钮行 + 呼吸间距', () {
    expect(
      videoSubtitleControlsTopReserve(
        buttonBarHeight: 56,
        topSystemInset: 20,
        subtitleBreathingGap: 8,
      ),
      84,
    );
    // 桌面（顶部无系统 inset）：仅一个按钮行高 + 呼吸间距。
    expect(
      videoSubtitleControlsTopReserve(
        buttonBarHeight: 56,
        topSystemInset: 0,
        subtitleBreathingGap: 0,
      ),
      56,
    );
  });

  testWidgets('② 副字幕（置顶）在控制条可见时顶部 padding 避让顶栏、隐藏时落回基线',
      (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setSecondaryCues(<AudioCue>[_cue('translation', 0, 6000)]);
    c.debugUpdateCueForPosition(1000);

    final ValueNotifier<bool> controlsVisible = ValueNotifier<bool>(false);
    addTearDown(controlsVisible.dispose);
    const double kBase = 12; // 用户基线（bottomPadding）
    const double kTopReserve = 300; // 顶栏避让高（远大于基线，便于断言）

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          controlsVisible: controlsVisible,
          controlsTopReserve: kTopReserve,
          bottomPadding: kBase,
        ),
      ),
    ));
    await tester.pump();

    double topPaddingOfSubtitle() {
      // 副字幕层只有一个 _anchoredPadded → 一个 AnimatedPadding（controlsVisible 非 null）。
      final Iterable<AnimatedPadding> pads =
          tester.widgetList<AnimatedPadding>(find.byType(AnimatedPadding));
      // 取最大 top（顶部锚点该层的目标 padding）。
      return pads
          .map((AnimatedPadding p) => p.padding.resolve(TextDirection.ltr).top)
          .fold<double>(0, (double a, double b) => b > a ? b : a);
    }

    // 控制条隐藏：顶部 padding = 用户基线。
    expect(topPaddingOfSubtitle(), kBase,
        reason: '控制条隐藏时顶部字幕落回用户基线（历史外观）');

    // 控制条可见：顶部 padding 抬到 controlsTopReserve（副字幕下移到顶栏下方）。
    controlsVisible.value = true;
    await tester.pump();
    expect(topPaddingOfSubtitle(), kTopReserve,
        reason: 'BUG-1069：控制条可见时顶部字幕避让顶栏、不再盖住标题栏/菜单');
  });
}
