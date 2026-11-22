import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_audio_overlay.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_lyrics_model.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_rail.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_visualizer.dart';

import '../visualizer_test_helpers.dart';

void main() {
  group('版面尺寸', () {
    test('超宽屏才整体放大', () {
      expect(monetLargeScreenScale(1280), 1);
      expect(monetLargeScreenScale(1536), 1);
      expect(monetLargeScreenScale(2200), closeTo(1.16, 1e-9));
      expect(monetLargeScreenScale(4000), closeTo(1.16, 1e-9));
    });

    test('clamp 字号：窄屏取下限、宽屏取上限', () {
      expect(monetClampFontPx(1.34, 2.75, 2.28, 390), closeTo(21.44, 1e-9));
      expect(monetClampFontPx(1.34, 2.75, 2.28, 1280), closeTo(35.2, 1e-9));
      expect(monetClampFontPx(1.34, 2.75, 2.28, 1500), closeTo(36.48, 1e-9));
      expect(monetLyricFontPx(1280, 1.2), closeTo(35.2 * 1.2, 1e-9));
    });

    test('歌词栏高度与断点', () {
      expect(monetRailHeightPx(720, 35, 1), closeTo(374.4, 1e-9));
      expect(monetRailHeightPx(300, 35, 1), 280);
      expect(monetTextPadX(390), 20);
      expect(monetTextPadX(1280), 56);
      expect(monetShowsPortrait(390), isFalse);
      expect(monetShowsPortrait(1280), isTrue);
    });
  });

  group('可见窗口与行状态', () {
    final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );

    test('唱第一句时：锚点是当前行，后面两句未唱', () {
      final List<MonetVisibleEntry> e = buildMonetVisibleEntries(rt, 1100);
      expect(e.map((MonetVisibleEntry x) => x.index), <int>[0, 1, 2]);
      expect(e.map((MonetVisibleEntry x) => x.status), <MonetLineStatus>[
        MonetLineStatus.active,
        MonetLineStatus.waiting,
        MonetLineStatus.waiting,
      ]);
      expect(e.first.offset, 0);
    });

    test('间奏：锚点是下一句，之前的都唱完了', () {
      final List<MonetVisibleEntry> e = buildMonetVisibleEntries(rt, 8000);
      expect(e.map((MonetVisibleEntry x) => x.offset), <int>[-2, -1, 0]);
      expect(e.last.status, MonetLineStatus.waiting);
      expect(e.first.status, MonetLineStatus.passed);
    });

    test('唱完：锚点停在最后一句', () {
      final List<MonetVisibleEntry> e = buildMonetVisibleEntries(rt, 30000);
      expect(e.last.offset, 0);
      expect(e.last.status, MonetLineStatus.passed);
    });

    test('开唱前：锚点是第一句', () {
      final List<MonetVisibleEntry> e = buildMonetVisibleEntries(rt, 0);
      expect(e.first.index, 0);
      expect(e.first.offset, 0);
      expect(e.first.status, MonetLineStatus.waiting);
    });
  });

  group('色调与排布', () {
    test('当前句全亮；离得越远越小越淡越糊，未唱比已唱亮', () {
      final MonetLineTone a = monetLineTone(MonetLineStatus.active, 0, 0.8);
      expect(a.opacity, 1);
      expect(a.scale, 1);
      expect(a.blurPx, 0);
      final MonetLineTone w1 = monetLineTone(MonetLineStatus.waiting, 1, 0.8);
      final MonetLineTone w2 = monetLineTone(MonetLineStatus.waiting, 2, 0.8);
      final MonetLineTone p1 = monetLineTone(MonetLineStatus.passed, -1, 0.8);
      expect(w1.opacity, closeTo(0.72, 1e-9));
      expect(w2.opacity, closeTo(0.54, 1e-9));
      expect(p1.opacity, closeTo(0.52, 1e-9));
      expect(w1.scale, closeTo(0.8, 1e-9));
      expect(w2.scale, closeTo(0.72, 1e-9));
      expect(w1.blurPx, closeTo(0.7, 1e-9));
      expect(w2.blurPx, closeTo(1.8, 1e-9));
      expect(p1.blurPx, closeTo(1.1, 1e-9));
    });

    test('锚点中心落在栏高 46%，上下依次堆叠', () {
      const List<MonetVisibleEntry> e = <MonetVisibleEntry>[
        MonetVisibleEntry(index: 0, offset: -1, status: MonetLineStatus.passed),
        MonetVisibleEntry(index: 1, offset: 0, status: MonetLineStatus.active),
        MonetVisibleEntry(index: 2, offset: 1, status: MonetLineStatus.waiting),
      ];
      final List<double> y = monetStackPositions(
        e,
        <double>[50, 100, 40],
        400,
        36,
      );
      expect(y[1], closeTo(400 * 0.46 - 50, 1e-9));
      final double gap = monetLineGap(
        MonetLineStatus.active,
        MonetLineStatus.waiting,
        36,
      );
      expect(y[2], closeTo(y[1] + 100 + gap, 1e-9));
      expect(y[0], closeTo(y[1] - 50 - gap, 1e-9));
    });

    test('非当前句最多保留两行', () {
      final double two = monetTextBoxHeight(
        fontPx: 30,
        lineCount: 2,
        active: false,
      );
      final double five = monetTextBoxHeight(
        fontPx: 30,
        lineCount: 5,
        active: false,
      );
      final double fiveActive = monetTextBoxHeight(
        fontPx: 30,
        lineCount: 5,
        active: true,
      );
      expect(five, two);
      expect(fiveActive, greaterThan(five));
      expect(monetTranslationBoxHeight(16, 0), 0);
      expect(monetIsReadableSubtitle('●●●'), isFalse);
      expect(monetIsReadableSubtitle('你好'), isTrue);
    });
  });

  group('扫字与发光', () {
    test('发光：起唱前 0，峰值 1，行尾之后淡到 0', () {
      expect(monetGlow(900, 1000, 1300, 3000), 0);
      expect(monetGlow(1354, 1000, 1300, 3000), closeTo(1, 1e-6));
      expect(monetGlow(2000, 1000, 1300, 3000), greaterThan(0.5));
      expect(monetGlow(3001, 1000, 1300, 3000), 0);
    });

    test('填充宽度按字形时间插值', () {
      const List<double> offsets = <double>[0, 10, 30];
      const List<(int, int)> timings = <(int, int)>[(0, 100), (100, 300)];
      expect(monetFillWidth(0, 0, 300, offsets, timings), 0);
      expect(monetFillWidth(50, 0, 300, offsets, timings), closeTo(5, 1e-9));
      expect(monetFillWidth(200, 0, 300, offsets, timings), closeTo(20, 1e-9));
      expect(monetFillWidth(300, 0, 300, offsets, timings), 30);
      // 没有字形时间：按整词均分。
      expect(monetFillWidth(150, 0, 300, offsets, const <(int, int)>[]), 10);
    });

    test('遮罩：前沿之前实心、之后透明，色标位置单调', () {
      const double full = 100;
      final double edge = monetSweepEdgeSoftness(36);
      final double end = monetSweepEnd(50, full, edge);
      expect(monetSweepMaskAlpha(0, end, edge, full), 1);
      expect(monetSweepMaskAlpha(end + 1, end, edge, full), 0);
      final List<(double, double)> stops = monetSweepMaskStops(
        0,
        full,
        end,
        edge,
        full,
      );
      expect(stops.first.$1, 0);
      expect(stops.last.$1, 1);
      for (int i = 1; i < stops.length; i++) {
        expect(stops[i].$1, greaterThan(stops[i - 1].$1));
      }
      expect(monetSweepEnd(0, 0, edge), 0);
    });
  });

  group('频谱', () {
    test('轮廓在 0–1，静态图案中间高两头低', () {
      final List<double> bands = monetSyntheticBands(1, 3);
      for (int i = 0; i <= 20; i++) {
        final double v = monetSpectrumProfile(bands, i / 20);
        expect(v, inInclusiveRange(0, 1));
      }
      double level(int i) => monetAudioLevel(
        index: i,
        line: false,
        still: true,
        bands: bands,
        energy: 0,
        ms: 0,
      );
      expect(level(0), closeTo(0.02, 1e-9));
      expect(level(36), greaterThan(level(2)));
      expect(monetSyntheticBands(0, 5), everyElement(0));
    });
  });

  group('动画通道', () {
    test('弹簧收敛到目标，中途换目标保速度', () {
      final MonetChannel c = MonetChannel(0)
        ..springTo(100, 0, kMonetScrollSpring);
      expect(c.value(0), 0);
      expect(c.value(3), closeTo(100, 0.5));
      c.springTo(50, 3, kMonetScrollSpring);
      expect(c.value(6), closeTo(50, 0.5));
    });

    test('缓动按时长到位', () {
      final MonetChannel c = MonetChannel(1)..tweenTo(0, 10, 0.2);
      expect(c.value(10), 1);
      expect(c.value(10.2), closeTo(0, 1e-6));
      expect(c.settled(10.3), isTrue);
    });
  });

  group('排版缓存', () {
    test('逐字句：每个词有累计宽度与段；行级句估出逐字时间', () {
      final LyricVisualizerRuntime word = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      final MonetLineText a = MonetLineText.layout(
        line: word.lines[1],
        fontPx: 30,
        translationFontPx: 16,
        contentWidth: 600,
        alignEnd: false,
        trackColor: const Color(0xFFFFFFFF),
      );
      expect(a.words, hasLength(3));
      for (final MonetWordGeom g in a.words) {
        expect(g.runs, isNotEmpty);
        expect(g.offsets.first, 0);
        expect(g.offsets.last, greaterThan(0));
      }
      expect(a.track, isNotNull);
      a.dispose();

      final LyricVisualizerRuntime lrc = LyricVisualizerRuntime(
        sampleLineTimeline(),
      );
      final MonetLineText b = MonetLineText.layout(
        line: lrc.lines[1],
        fontPx: 30,
        translationFontPx: 16,
        contentWidth: 240,
        alignEnd: true,
        trackColor: const Color(0xFFFFFFFF),
      );
      expect(b.lineCount, greaterThan(1));
      expect(b.words.length, greaterThan(5));
      expect(b.words.first.startMs, 3000);
      expect(b.track, isNull);
      expect(
        b.visualHeight(30, 16, false),
        monetTextBoxHeight(fontPx: 30, lineCount: 2, active: false),
      );
      b.dispose();
    });
  });

  group('参数', () {
    test('默认值与 folia 一致', () {
      final MonetConfig c = MonetConfig.from(
        LyricVisualizerTuningFixture.defaults(),
      );
      expect(c.fontScale, 1.2);
      expect(c.descriptionVisibility, 'auto');
      expect(c.showAudio, isTrue);
      expect(c.audioLine, isFalse);
      expect(c.showPortrait, isTrue);
      expect(c.squarePortrait, isTrue);
      expect(c.mirrored, isFalse);
    });

    test('背景交给共享背景「莫奈」', () {
      expect(
        monetVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(monetVisualizerEntry.tunings),
        ),
        const LyricVisualizerBackgroundRequest.specific('monet'),
      );
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, monetVisualizerEntry);
    });

    testWidgets('镜像 + 长方形 + 线条频谱 + 常显描述', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        tuning: const <String, Object?>{
          MonetTuningKeys.mirrorLayout: true,
          MonetTuningKeys.portraitStyle: 'rectangular',
          MonetTuningKeys.portraitOffsetX: -120.0,
          MonetTuningKeys.audioStyle: 'line',
          MonetTuningKeys.descriptionVisibility: 'always',
          MonetTuningKeys.fontScale: 1.5,
        },
      );
    });

    testWidgets('关肖像、关频谱、隐藏描述', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        tuning: const <String, Object?>{
          MonetTuningKeys.portraitSource: 'none',
          MonetTuningKeys.showAudioVisualization: false,
          MonetTuningKeys.descriptionVisibility: 'hidden',
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 2000, 3100, 4500, 5900, 9000],
      );
    });

    testWidgets('减弱动态效果', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏手机', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    testWidgets('超宽屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        size: const Size(2400, 1350),
      );
    });

    testWidgets('画出标题、歌手、专辑', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FakeVisualizerClock clock = FakeVisualizerClock(1500);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: monetVisualizerEntry.builder(
                visualizerContextFor(monetVisualizerEntry, clock: clock),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Test title'), findsOneWidget);
      expect(find.text('Test artist'), findsOneWidget);
      expect(find.text('TEST ALBUM'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

/// 用注册项的声明造一份全默认参数。
abstract final class LyricVisualizerTuningFixture {
  static LyricVisualizerTuning defaults() =>
      LyricVisualizerTuning.defaults(monetVisualizerEntry.tunings);
}
