import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'widget_test_helpers.dart';

AudioCue _cue(String t, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = t
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

/// BUG-553：字幕盒只在**命中字符**时赢手势竞技场；点字幕盒内**字符间空白**（超容差）
/// 的 tap 必须 fall-through 到盖在其下的层（生产里是 media_kit 控制条 onTap → 唤出/
/// 隐藏控制条）。旧的整片 [HitTestBehavior.translucent] 会无条件吞掉这类 tap，移动端
/// （无 hover 兜底）表现为「有字幕在屏时点画面唤不出控制条」。
///
/// 用 [Stack] 在字幕 overlay 之下垫一个铺满的 opaque [GestureDetector] 计数器模拟
/// media_kit 控制条 tap 层：命中字符 → 查词触发且**不**穿透（计数为 0，保留「点字幕
/// 文字只查词不顺手 toggle」）；命中空白 → **不**查词且穿透到下层（计数 +1）。
void main() {
  Future<void> pumpOverlayOverCounter(
    WidgetTester tester, {
    required VideoPlayerController controller,
    required void Function(String sentence, int graphemeIndex, Rect rect)
        onCharTap,
    required VoidCallback onUnderlyingTap,
  }) async {
    await tester.pumpWidget(buildTestApp(Stack(
      children: <Widget>[
        // 下层：铺满的 opaque tap 计数器（模拟 media_kit 控制条的全覆盖 onTap 层）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onUnderlyingTap,
          ),
        ),
        // 上层：字幕 overlay（Positioned.fill，几何与视频页一致）。
        Positioned.fill(
          child: VideoSubtitleOverlay(
            controller: controller,
            // 小字号：命中容差落在下限 10px（测试字体每字形约 1em 方块，fontSize/2
            // < 10 时容差取下限），空白点距字符矩形 dist^2=146 > 10^2=100，稳落空白区。
            fontSize: 20,
            onCharTap: onCharTap,
          ),
        ),
      ],
    )));
  }

  testWidgets('点字符 → 查词触发且不穿透到下层控制条 tap', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('l', 0, 1000)]);

    String? tappedSentence;
    int underlyingTaps = 0;
    await pumpOverlayOverCounter(
      tester,
      controller: c,
      onCharTap: (String s, int i, Rect r) => tappedSentence = s,
      onUnderlyingTap: () => underlyingTaps++,
    );

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 点字符 'l' 的中心 → 命中字符矩形 → 字幕盒赢竞技场 → 查词。
    await tester.tapAt(tester.getCenter(find.text('l').first));
    await tester.pump();

    expect(tappedSentence, 'l', reason: '命中字符必须触发查词');
    expect(underlyingTaps, 0,
        reason: '命中字符时字幕盒赢竞技场，tap 不穿透到下层（不顺手 toggle 控制条）');
  });

  testWidgets('点字幕盒内空白 → 不查词且穿透到下层控制条 tap（BUG-553）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('l', 0, 1000)]);

    String? tappedSentence;
    int underlyingTaps = 0;
    await pumpOverlayOverCounter(
      tester,
      controller: c,
      onCharTap: (String s, int i, Rect r) => tappedSentence = s,
      onUnderlyingTap: () => underlyingTaps++,
    );

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 字幕盒有 12px 水平 / 6px 垂直 padding：字符矩形左上角在盒内 (12,6)。取字符矩形
    // 左上角向盒角方向偏 (11,5) 的点 → 落在盒内 padding 空白（距字符矩形 dx=11,dy=5，
    // 距离² = 146 > 命中容差²（下限 10² = 100）→ 超容差、判为空白）。
    final Offset charTopLeft = tester.getTopLeft(find.text('l').first);
    final Offset blank = charTopLeft - const Offset(11, 5);
    await tester.tapAt(blank);
    await tester.pump();

    expect(tappedSentence, isNull, reason: '字符间空白不应查词');
    expect(underlyingTaps, 1, reason: '字幕盒空白 tap 必须穿透到下层控制条 tap（唤出/隐藏控制条）');
  });
}
