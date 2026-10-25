import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_immersive_mode.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 沉浸锁定态「点画面显示字幕」（设计案
/// `docs/specs/2026-10-25-video-immersive-one-hand.md` §3.1）：判据纯函数 +
/// [VideoSubtitleRevealHandle] 驱动 overlay 显形 / 遮回。
///
/// 断言代理与 BUG-1068 测试相同：遮蔽态才建的 `Key('video-subtitle-reveal')` 热区
/// 存在 = 当前句被遮住，不存在 = 已显形。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

Finder get _revealHotZone => find.byKey(const Key('video-subtitle-reveal'));

Future<void> _pumpAt(
  WidgetTester tester,
  VideoPlayerController c,
  VideoSubtitleRevealHandle handle,
  int posMs, {
  bool hidden = true,
  bool revealOnInteraction = true,
}) async {
  c.debugUpdateCueForPosition(posMs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          subtitleHidden: hidden,
          obscureRevealOnInteraction: revealOnInteraction,
          revealHandle: handle,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('videoImmersiveTapRevealsSubtitle', () {
    bool reveals({
      bool locked = true,
      bool enabled = true,
      VideoSubtitleObscureMode mode = VideoSubtitleObscureMode.hide,
      bool revealOnInteraction = true,
    }) => videoImmersiveTapRevealsSubtitle(
      immersiveLocked: locked,
      tapRevealEnabled: enabled,
      obscureMode: mode,
      revealOnInteraction: revealOnInteraction,
    );

    test('沉浸锁定 + 开关开 + 遮蔽中 + 允许临时显形 → 生效（隐藏与模糊都算）', () {
      expect(reveals(), isTrue);
      expect(reveals(mode: VideoSubtitleObscureMode.blur), isTrue);
    });

    test('任一条件不满足都不生效', () {
      expect(reveals(locked: false), isFalse, reason: '没锁定：点画面照旧是控制条显隐');
      expect(reveals(enabled: false), isFalse, reason: '用户关了「沉浸时点画面显示字幕」');
      expect(
        reveals(mode: VideoSubtitleObscureMode.none),
        isFalse,
        reason: '字幕没遮蔽，没有什么可显示的',
      );
      expect(
        reveals(revealOnInteraction: false),
        isFalse,
        reason: 'BUG-2256：关了临时显形，任何来源都不得揭开遮蔽',
      );
    });
  });

  group('VideoSubtitleRevealHandle', () {
    testWidgets('句柄翻转显形：遮住 → 显示 → 遮回', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetIsPlayingForTesting(true);
      c.setCues(<AudioCue>[_cue('AAA', 0, 2000)]);
      final VideoSubtitleRevealHandle handle = VideoSubtitleRevealHandle();

      await _pumpAt(tester, c, handle, 1000);
      expect(_revealHotZone, findsOneWidget, reason: '播放中开隐藏，当前句应被遮住');

      expect(handle.toggleMainReveal(), isTrue);
      await tester.pump();
      expect(_revealHotZone, findsNothing, reason: '点画面后当前句显示');

      expect(handle.toggleMainReveal(), isTrue);
      await tester.pump();
      expect(_revealHotZone, findsOneWidget, reason: '再点一下遮回去（误点可撤销）');
    });

    testWidgets('换句后自动遮回（只对当前这一句临时豁免）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetIsPlayingForTesting(true);
      c.setCues(<AudioCue>[_cue('AAA', 0, 2000), _cue('BBB', 2000, 4000)]);
      final VideoSubtitleRevealHandle handle = VideoSubtitleRevealHandle();

      await _pumpAt(tester, c, handle, 1000);
      handle.toggleMainReveal();
      await tester.pump();
      expect(_revealHotZone, findsNothing);

      await _pumpAt(tester, c, handle, 3000);
      expect(_revealHotZone, findsOneWidget, reason: '下一句应重新遮住');
    });

    testWidgets('关了临时显形 / 没开遮蔽时句柄不生效', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetIsPlayingForTesting(true);
      c.setCues(<AudioCue>[_cue('AAA', 0, 2000)]);
      final VideoSubtitleRevealHandle handle = VideoSubtitleRevealHandle();

      await _pumpAt(tester, c, handle, 1000, revealOnInteraction: false);
      expect(handle.toggleMainReveal(), isFalse);
      await tester.pump();
      expect(_revealHotZone, findsOneWidget, reason: '遮蔽恒定生效');

      await _pumpAt(tester, c, handle, 1000, hidden: false);
      expect(handle.toggleMainReveal(), isFalse, reason: '没开遮蔽，句柄无事可做');
    });
  });
}
