// TODO-1059 子问题1：字幕背景在浅色主题下泛白（跟随 `surface` 近白），且设置面板
// 缺背景色控件。本测试锁定「方案A」的根因修复：字幕盒默认底色（backgroundColor==null）
// 是固定半透明黑 [kDefaultSubtitleBackgroundColor]，**不**跟随浅色主题的 `surface`。
//
// 撤回方案A（把默认色改回 `Theme.of(context).colorScheme.surface`）→ 浅色主题下断言
// 的期望色（黑×opacity）与实际（近白 surface×opacity）不符 → 红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

VideoPlayerController _controllerWithCue() {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'ch'
      ..sentenceIndex = 0
      ..textFragmentId = '#s1'
      ..text = 'A'
      ..startMs = 0
      ..endMs = 5000
      ..audioFileIndex = 0,
  ]);
  c.debugUpdateCueForPosition(100);
  return c;
}

/// 找到字幕盒那层 [DecoratedBox]（圆角 6 的 [BoxDecoration]），返回其解析后的底色。
Color? _subtitleBoxColor(WidgetTester tester) {
  final Iterable<DecoratedBox> boxes =
      tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
  for (final DecoratedBox b in boxes) {
    final Decoration d = b.decoration;
    if (d is BoxDecoration &&
        d.borderRadius == BorderRadius.circular(6) &&
        d.color != null) {
      return d.color;
    }
  }
  return null;
}

Future<void> _pumpLight(
  WidgetTester tester,
  VideoPlayerController controller, {
  Color? backgroundColor,
  required double opacity,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // 明确浅色主题：`surface` 近白，最能暴露「背景跟随 surface 泛白」的根因。
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(),
      ),
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: controller,
          backgroundColor: backgroundColor,
          backgroundOpacity: opacity,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('TODO-1059 子1：字幕背景默认固定半透明黑，不跟随浅色主题 surface（方案A）', () {
    testWidgets(
        'backgroundColor==null + opacity>0 + 浅色主题：底色=固定黑×opacity（不是 surface）',
        (tester) async {
      const double opacity = 0.5;
      final VideoPlayerController c = _controllerWithCue();
      addTearDown(c.dispose);
      await _pumpLight(tester, c, opacity: opacity);

      final Color? boxColor = _subtitleBoxColor(tester);
      expect(boxColor, isNotNull, reason: '未找到字幕盒 DecoratedBox');

      final Color expected =
          kDefaultSubtitleBackgroundColor.withValues(alpha: opacity);
      expect(boxColor, expected,
          reason: '字幕盒默认底色必须是固定 [kDefaultSubtitleBackgroundColor]×opacity，'
              '不是浅色主题的 surface（方案A 根因）');

      // 明确排除「跟随浅色 surface」的回归：浅色 surface 近白，其 alpha=opacity 的结果
      // 明显比固定黑亮得多。
      final Color surfaceFallback =
          const ColorScheme.light().surface.withValues(alpha: opacity);
      expect(boxColor, isNot(surfaceFallback),
          reason: '字幕盒底色不得再跟随浅色主题 surface（泛白根因）');
    });

    testWidgets('用户显式选过背景色（非 null）仍逐字尊重，不被默认黑覆盖', (tester) async {
      const double opacity = 0.6;
      const Color userColor = Color(0xFF1976D2); // 用户显式选的蓝。
      final VideoPlayerController c = _controllerWithCue();
      addTearDown(c.dispose);
      await _pumpLight(tester, c, backgroundColor: userColor, opacity: opacity);

      final Color? boxColor = _subtitleBoxColor(tester);
      expect(boxColor, userColor.withValues(alpha: opacity),
          reason: '显式设过的背景色必须逐字尊重（Never break userspace）');
    });

    testWidgets('opacity==0：完全透明（无背景），与颜色默认无关', (tester) async {
      final VideoPlayerController c = _controllerWithCue();
      addTearDown(c.dispose);
      await _pumpLight(tester, c, opacity: 0);
      final Color? boxColor = _subtitleBoxColor(tester);
      expect(boxColor, Colors.transparent, reason: 'opacity==0 时字幕盒完全透明（无背景）');
    });
  });
}
