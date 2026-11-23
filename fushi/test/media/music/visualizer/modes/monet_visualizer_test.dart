import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_audio_overlay.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_floating_decor.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_lyrics_model.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_rail.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// 两行，第一行来源标成副歌。
LyricTimeline _chorusTimeline() => const LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.word,
  lines: <LyricLine>[
    LyricLine(
      startMs: 1000,
      endMs: 3000,
      songPart: 'Chorus',
      syllables: <LyricSyllable>[
        LyricSyllable(text: 'Hello ', startMs: 1000, endMs: 1600),
        LyricSyllable(text: 'bright ', startMs: 1600, endMs: 2200),
        LyricSyllable(text: 'world', startMs: 2200, endMs: 3000),
      ],
    ),
    LyricLine(
      startMs: 4000,
      endMs: 6000,
      songPart: 'Verse',
      syllables: <LyricSyllable>[
        LyricSyllable(text: 'ま', startMs: 4000, endMs: 5000),
        LyricSyllable(text: 'た', startMs: 5000, endMs: 6000),
      ],
    ),
  ],
);

void main() {
  late Directory assetRoot;
  setUp(() {
    assetRoot = Directory.systemTemp.createTempSync('monet_assets');
    monetAssetStoreOpener = () async => LyricVisualizerAssetStore(assetRoot);
  });
  tearDown(() {
    monetAssetStoreOpener = LyricVisualizerAssetStore.open;
    try {
      assetRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶有句柄未释放，临时目录留给系统清。
    }
  });

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
    test('音频帧映射成 folia 五段频带', () {
      const LyricVisualizerAudioFrame f = LyricVisualizerAudioFrame(
        power: 0.5,
        low: 0.8,
        mid: 0.4,
        high: 0.2,
        vocal: 0.6,
        onset: 0,
        beatImpact: 0,
        downbeatImpact: 0,
        drumImpact: 0,
      );
      // 没有分段数据：lowMid / mid 都回落到合并中频。
      expect(monetAudioBands(f), <Object>[0.8, 0.4, 0.4, 0.6, 0.2]);
      const LyricVisualizerAudioFrame split = LyricVisualizerAudioFrame(
        power: 0.5,
        low: 0.8,
        mid: 0.4,
        lowMid: 0.7,
        upperMid: 0.3,
        high: 0.2,
        vocal: 0.6,
        onset: 0,
        beatImpact: 0,
        downbeatImpact: 0,
        drumImpact: 0,
      );
      expect(monetAudioBands(split), <Object>[0.8, 0.7, 0.3, 0.6, 0.2]);
      expect(
        monetAudioBands(LyricVisualizerAudioFrame.silent),
        everyElement(0),
      );
    });

    test('轮廓在 0–1，静态图案中间高两头低', () {
      final List<double> bands = <double>[0.9, 0.7, 0.6, 0.8, 0.5];
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
      expect(a.tracks, hasLength(1));
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
      expect(b.tracks, isEmpty);
      expect(
        b.visualHeight(30, false),
        monetTextBoxHeight(fontPx: 30, lineCount: 2, active: false),
      );
      b.dispose();
    });

    test('主题按词着色：命中的词记上颜色；副歌行带标记', () {
      const Color red = Color(0xFFFF0000);
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        _chorusTimeline(),
      );
      final MonetLineText a = MonetLineText.layout(
        line: rt.lines[0],
        fontPx: 30,
        translationFontPx: 16,
        contentWidth: 600,
        alignEnd: false,
        trackColor: const Color(0xFFFFFFFF),
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'bright': red},
        ),
      );
      expect(a.isChorus, isTrue);
      expect(a.words.map((MonetWordGeom w) => w.color), <Color?>[
        null,
        red,
        null,
      ]);
      // 光晕留到句尾离场窗口（render hints），不早于行尾。
      expect(a.lineEndMs, rt.lines[0].renderEndMs);
      expect(a.lineEndMs, greaterThanOrEqualTo(3000));
      a.dispose();
      final MonetLineText b = MonetLineText.layout(
        line: rt.lines[1],
        fontPx: 30,
        translationFontPx: 16,
        contentWidth: 600,
        alignEnd: false,
        trackColor: const Color(0xFFFFFFFF),
      );
      expect(b.isChorus, isFalse);
      expect(b.words.every((MonetWordGeom w) => w.color == null), isTrue);
      b.dispose();
    });
  });

  group('肖像', () {
    test('来源：自定义优先素材图、封面优先封面，各自回落', () {
      expect(
        monetPortraitPath(source: 'custom', cover: 'c.jpg', custom: 'p.png'),
        'p.png',
      );
      expect(
        monetPortraitPath(source: 'custom', cover: 'c.jpg', custom: null),
        'c.jpg',
      );
      expect(
        monetPortraitPath(source: 'cover', cover: 'c.jpg', custom: 'p.png'),
        'c.jpg',
      );
      expect(
        monetPortraitPath(source: 'cover', cover: '', custom: 'p.png'),
        'p.png',
      );
      expect(
        monetPortraitPath(source: 'cover', cover: null, custom: null),
        isNull,
      );
    });

    test('chaotic 晃动：9 秒一圈，首圈延后 0.2 秒', () {
      expect(monetChaoticShake(0), (0.0, 0.0, 0.0));
      final (double x, double y, double r) = monetChaoticShake(0.2 + 2.25);
      expect(x, closeTo(-9, 1e-9));
      expect(y, closeTo(-18, 1e-9));
      expect(r, closeTo(1.2, 1e-9));
      final (double x2, double y2, double r2) = monetChaoticShake(
        0.2 + 9 + 6.75,
      );
      expect(x2, closeTo(9, 1e-9));
      expect(y2, closeTo(18, 1e-9));
      expect(r2, closeTo(-1.2, 1e-9));
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
      expect(c.keywordColoring, isTrue);
      expect(c.customDescription, '');
      expect(c.portraitSource, 'cover');
      expect(c.portraitPack, 'default');
    });

    test('自定义描述截到 120 字；素材包参数只在选自定义时显示', () {
      final LyricVisualizerTuning tu = LyricVisualizerTuning(
        monetVisualizerEntry.tunings,
        <String, Object?>{'customDescription': '  ${'x' * 200}'},
      );
      expect(MonetConfig.from(tu).customDescription.length, lessThan(121));
      final LyricVisualizerTuningSpec pack = monetVisualizerEntry.tunings
          .firstWhere((LyricVisualizerTuningSpec s) => s.key == 'portraitPack');
      expect(
        pack.visibleWhen!(LyricVisualizerTuningFixture.defaults()),
        isFalse,
      );
      expect(
        pack.visibleWhen!(
          LyricVisualizerTuning(
            monetVisualizerEntry.tunings,
            const <String, Object?>{'portraitSource': 'custom'},
          ),
        ),
        isTrue,
      );
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

  group('主题与字幕偏好', () {
    test('胶囊文字：自定义 → 主题描述 → 主题名 → 样式名', () {
      const LyricVisualizerTheme both = LyricVisualizerTheme(
        name: '夜航',
        description: ' 深夜的海 ',
      );
      expect(
        monetCapsuleLabel(custom: '  ', theme: both, fallback: 'Monet'),
        '深夜的海',
      );
      expect(
        monetCapsuleLabel(custom: '我的', theme: both, fallback: 'Monet'),
        '我的',
      );
      expect(
        monetCapsuleLabel(
          custom: '',
          theme: const LyricVisualizerTheme(name: '夜航'),
          fallback: 'Monet',
        ),
        '夜航',
      );
      expect(
        monetCapsuleLabel(custom: '', theme: null, fallback: 'Monet'),
        'Monet',
      );
    });

    test('浮动装饰：没图标不画；粒子按下标确定，关键帧首尾相接', () {
      expect(buildMonetDecorParticles(const <IconData>[]), isEmpty);
      final List<MonetDecorParticle> ps = buildMonetDecorParticles(
        const <IconData>[FushiIcons.star, FushiIcons.cloud],
      );
      // folia：(i*37+11)%100 > 20 的槽位才有粒子（i = 0、8 空着）。
      expect(ps.map((MonetDecorParticle p) => p.id), <int>[
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        9,
      ]);
      expect(ps.first.icon, FushiIcons.cloud);
      for (final MonetDecorParticle p in ps) {
        expect(p.opacity, inInclusiveRange(0.06, 0.17));
        final ({double dx, double dy, double rotation, double opacity}) start =
            monetDecorPose(p, 0);
        final ({double dx, double dy, double rotation, double opacity}) end =
            monetDecorPose(p, p.delay + p.duration - 1e-6);
        expect(end.dx, closeTo(start.dx, 1e-3));
        expect(end.dy, closeTo(start.dy, 1e-3));
        expect(start.dy, p.reverse ? -40 : 40);
      }
    });

    test('双行字幕：罗马音在前、译文退一级；隐藏时没有副字幕', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        LyricTimeline(
          format: 'ttml',
          timingQuality: LyricTimingQuality.line,
          lines: <LyricLine>[
            const LyricLine(
              startMs: 0,
              endMs: 2000,
              syllables: <LyricSyllable>[
                LyricSyllable(text: '夜空', startMs: 0, endMs: 2000),
              ],
              romanization: 'yozora',
              translations: <LyricTranslation>[LyricTranslation('zh', '夜空中的光')],
            ),
          ],
        ),
      );
      MonetLineText lay(LyricVisualizerSubtitleSettings s) =>
          MonetLineText.layout(
            line: rt.lines[0],
            fontPx: 30,
            translationFontPx: 20,
            contentWidth: 600,
            alignEnd: false,
            trackColor: const Color(0xFFFFFFFF),
            subtitle: s,
          );
      final MonetLineText both = lay(
        const LyricVisualizerSubtitleSettings(
          content: LyricVisualizerSubtitleContent.both,
        ),
      );
      expect(both.tracks, hasLength(2));
      expect(both.tracks[0].fontPx, 20);
      expect(both.tracks[1].fontPx, closeTo(17.6, 1e-9));
      expect(both.tracks[1].paddingTop, closeTo(4.4, 1e-9));
      expect((both.tracks[0].painter.text! as TextSpan).text, 'yozora');
      expect(
        both.visualHeight(30, true),
        closeTo(
          monetTextBoxHeight(fontPx: 30, lineCount: 1, active: true) +
              both.tracks[0].height +
              both.tracks[1].height,
          1e-9,
        ),
      );
      final MonetLineText single = lay(
        LyricVisualizerSubtitleSettings.defaults,
      );
      expect(single.tracks, hasLength(1));
      expect((single.tracks[0].painter.text! as TextSpan).text, '夜空中的光');
      final MonetLineText hidden = lay(
        const LyricVisualizerSubtitleSettings(hideTranslation: true),
      );
      expect(hidden.tracks, isEmpty);
      both.dispose();
      single.dispose();
      hidden.dispose();
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, monetVisualizerEntry);
    });

    testWidgets('主题图标浮动装饰 + 双行字幕 + 字幕字号 / 字体', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        theme: const LyricVisualizerTheme(
          name: '夜航',
          lyricsIcons: <LyricVisualizerThemeIcon>[
            LyricVisualizerThemeIcon.moon,
            LyricVisualizerThemeIcon.flower,
          ],
        ),
        subtitle: const LyricVisualizerSubtitleSettings(
          content: LyricVisualizerSubtitleContent.both,
          fontScale: 1.4,
          font: LyricVisualizerSubtitleFont.serif,
        ),
      );
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

    testWidgets('真音频 + 副歌 + 主题着色 + chaotic + 自定义肖像', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        timeline: _chorusTimeline(),
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'bright': Color(0xFFFF0000)},
          fontWeight: FontWeight.w300,
        ),
        tuning: const <String, Object?>{
          'portraitSource': 'custom',
          'descriptionVisibility': 'always',
          'audioStyle': 'line',
        },
      );
    });

    testWidgets('关键字着色关掉也照常画', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        monetVisualizerEntry,
        timeline: _chorusTimeline(),
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'bright': Color(0xFFFF0000)},
        ),
        tuning: const <String, Object?>{'keywordColoringEnabled': false},
      );
    });

    testWidgets('描述胶囊显示自定义描述', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FakeVisualizerClock clock = FakeVisualizerClock(1500);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: monetVisualizerEntry.builder(
                visualizerContextFor(
                  monetVisualizerEntry,
                  clock: clock,
                  tuning: const <String, Object?>{
                    'descriptionVisibility': 'always',
                    'customDescription': ' Rainy day ',
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('RAINY DAY'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
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
