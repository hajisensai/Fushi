import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/still/still_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// 挂载并停在 [timeMs]，可指定字号倍数（共享 harness 不带 fontScale）。
Future<FakeVisualizerClock> _mountAt(
  WidgetTester tester, {
  required int timeMs,
  double fontScale = 1,
  bool playing = false,
  Size size = const Size(1280, 720),
  LyricVisualizerTheme? theme,
  LyricVisualizerSubtitleSettings subtitle =
      LyricVisualizerSubtitleSettings.defaults,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FakeVisualizerClock clock = FakeVisualizerClock(timeMs);
  final LyricVisualizerContext base = visualizerContextFor(
    stillVisualizerEntry,
    clock: clock,
    playing: playing,
    theme: theme,
  );
  final LyricVisualizerContext c = LyricVisualizerContext(
    timeline: base.timeline,
    runtime: base.runtime,
    clock: clock,
    offsetMs: 0,
    playing: playing,
    palette: base.palette,
    tuning: base.tuning,
    seed: base.seed,
    motion: base.motion,
    fontScale: fontScale,
    theme: theme,
    subtitle: subtitle,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(child: stillVisualizerEntry.builder(c)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
  return clock;
}

void main() {
  group('still 排版规则', () {
    final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );

    test('effectiveIndex：开头取第 0 句、唱时取当前句、间奏停在上一句', () {
      expect(resolveStillEffectiveIndex(rt, 0), 0);
      expect(resolveStillEffectiveIndex(rt, 1500), 0);
      expect(resolveStillEffectiveIndex(rt, 3600), 1);
      expect(resolveStillEffectiveIndex(rt, 8000), 1);
      expect(resolveStillEffectiveIndex(rt, 12300), 2);
      expect(resolveStillEffectiveIndex(rt, 60000), 2);
    });

    test('空时间轴为 -1', () {
      final LyricVisualizerRuntime empty = LyricVisualizerRuntime(
        const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
      );
      expect(resolveStillEffectiveIndex(empty, 1000), -1);
      expect(stillSlotIndices(-1, 0), <int?>[null, null, null]);
    });

    test('三个槽位越界为空', () {
      expect(stillSlotIndices(0, 3), <int?>[null, 0, 1]);
      expect(stillSlotIndices(1, 3), <int?>[0, 1, 2]);
      expect(stillSlotIndices(2, 3), <int?>[1, 2, null]);
      expect(stillSlotIndices(0, 1), <int?>[null, 0, null]);
    });

    test('当前句取句尾离场窗口里的那句（folia currentLineIndex）', () {
      final LyricVisualizerLine l0 = rt.lines[0];
      expect(l0.renderEndMs, greaterThan(l0.endMs));
      expect(resolveStillEffectiveIndex(rt, l0.endMs + 1), 0);
    });

    test('译文色：主题给了次色直接用，只有封面取色时往正文色靠', () {
      const LyricVisualizerPalette p = LyricVisualizerPalette(
        background: Color(0xFF000000),
        primary: Color(0xFF112233),
        secondary: Color(0xFF445566),
        accent: Color(0xFF778899),
        text: Color(0xFFFFFFFF),
        dimText: Color(0x73FFFFFF),
        brightness: Brightness.dark,
      );
      expect(
        stillTranslationColor(p, null),
        Color.lerp(p.text, p.secondary, 0.35),
      );
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        palette: LyricVisualizerPaletteOverride(secondary: Color(0xFFABCDEF)),
      );
      final LyricVisualizerPalette themed = p.applyOverride(theme.palette);
      expect(stillTranslationColor(themed, theme), const Color(0xFFABCDEF));
    });

    test('当前句比上下句大且不透明', () {
      expect(
        StillSlotStyle.current.fontSize,
        greaterThan(StillSlotStyle.side.fontSize),
      );
      expect(StillSlotStyle.current.opacity, 1);
      expect(StillSlotStyle.side.opacity, closeTo(0.3, 1e-9));
    });
  });

  group('still 组件', () {
    testWidgets('注册项：不用共享背景与共享字幕', (WidgetTester tester) async {
      expect(stillVisualizerEntry.mode, LyricVisualizerMode.still);
      expect(
        stillVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(stillVisualizerEntry.tunings),
        ),
        LyricVisualizerBackgroundRequest.none,
      );
      expect(stillVisualizerEntry.sharedSubtitle, isFalse);
      expect(stillVisualizerEntry.tunings, isEmpty);
    });

    testWidgets('画上一句 / 当前句 / 下一句与译文，换句时更新', (WidgetTester tester) async {
      await _mountAt(tester, timeMs: 1500);
      expect(find.text('夜空に光'), findsOneWidget);
      expect(find.text('夜空中的光'), findsOneWidget);
      expect(find.text('Hello bright world'), findsOneWidget);
      expect(find.text('また会おう'), findsNothing);

      await _mountAt(tester, timeMs: 12300);
      expect(find.text('また会おう'), findsOneWidget);
      expect(find.text('Hello bright world'), findsOneWidget);
      expect(find.text('夜空に光'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('主题字重与字体套到原文和译文上', (WidgetTester tester) async {
      await _mountAt(
        tester,
        timeMs: 1500,
        theme: const LyricVisualizerTheme(
          fontWeight: FontWeight.w300,
          fontFamily: 'serif',
        ),
      );
      for (final String s in <String>['夜空に光', '夜空中的光']) {
        final Text text = tester.widget<Text>(find.text(s));
        expect(text.style?.fontWeight, FontWeight.w300);
        expect(text.style?.fontFamily, 'serif');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('全局字幕偏好：隐藏、字号倍数、单独字体', (WidgetTester tester) async {
      await _mountAt(tester, timeMs: 1500);
      final double base = tester
          .widget<Text>(find.text('夜空中的光'))
          .style!
          .fontSize!;
      await _mountAt(
        tester,
        timeMs: 1500,
        subtitle: const LyricVisualizerSubtitleSettings(
          fontScale: 1.5,
          font: LyricVisualizerSubtitleFont.mono,
        ),
      );
      final Text big = tester.widget<Text>(find.text('夜空中的光'));
      expect(big.style!.fontSize, closeTo(base * 1.5, 1e-9));
      expect(big.style!.fontFamily, 'monospace');
      // 原文不受字幕偏好影响。
      expect(tester.widget<Text>(find.text('夜空に光')).style!.fontFamily, isNull);
      await _mountAt(
        tester,
        timeMs: 1500,
        subtitle: const LyricVisualizerSubtitleSettings(hideTranslation: true),
      );
      expect(find.text('夜空中的光'), findsNothing);
      expect(find.text('夜空に光'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('播放中只在换句时重建', (WidgetTester tester) async {
      final FakeVisualizerClock clock = await _mountAt(
        tester,
        timeMs: 1100,
        playing: true,
      );
      expect(find.text('夜空に光'), findsOneWidget);
      clock.positionMs = 3600;
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('你好，明亮的世界'), findsOneWidget);
      // 间奏：停在上一句。
      clock.positionMs = 8000;
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Hello bright world'), findsOneWidget);
      expect(find.text('また会おう'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, stillVisualizerEntry);
    });

    testWidgets('无效 tuning 被忽略', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        stillVisualizerEntry,
        tuning: const <String, Object?>{'unknown': 3},
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        stillVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态效果 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        stillVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        stillVisualizerEntry,
        size: const Size(390, 844),
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('窄屏大字号不溢出', (WidgetTester tester) async {
      await _mountAt(
        tester,
        timeMs: 3600,
        fontScale: 2.5,
        size: const Size(390, 844),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
