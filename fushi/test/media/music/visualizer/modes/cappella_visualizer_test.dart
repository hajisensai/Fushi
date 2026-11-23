import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_avatar.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_messages.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_visualizer.dart';

import '../visualizer_test_helpers.dart';

List<CappellaLine> _wordLines() =>
    buildCappellaLines(LyricVisualizerRuntime(sampleWordTimeline()).lines);

/// 无演唱者、每句都长于短句上限的行级时间轴（[n] 句，每句 2s，紧挨着）。
LyricTimeline _plainTimeline(int n) => LyricTimeline(
  format: 'lrc',
  lines: <LyricLine>[
    for (int i = 0; i < n; i++)
      LyricLine(
        startMs: i * 2000,
        endMs: i * 2000 + 2000,
        syllables: <LyricSyllable>[
          LyricSyllable(
            text: 'This is a fairly long lyric line number $i',
            startMs: i * 2000,
            endMs: i * 2000 + 2000,
          ),
        ],
      ),
  ],
);

ui.Image _solidImage(Color color) {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
  final ui.Picture pic = rec.endRecording();
  final ui.Image img = pic.toImageSync(8, 8);
  pic.dispose();
  return img;
}

CappellaSceneConfig _sceneConfig(
  List<CappellaLine> lines, {
  bool motion = true,
  bool showEmo = true,
  CappellaAvatarSource avatarSource = CappellaAvatarSource.generated,
  CappellaImagePool? avatarPool,
  CappellaImagePool? emojiPool,
  FontWeight fontWeight = kCappellaBubbleFontWeight,
}) {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  );
  final CappellaIntensityConfig cfg = cappellaIntensityConfig(
    LyricVisualizerIntensity.normal,
  );
  return CappellaSceneConfig(
    lines: lines,
    messages: buildCappellaMessages(
      lines: lines,
      titleText: 'Song',
      sequencing: cfg.sequencing,
      showEmo: showEmo,
      stickerPoolSize: emojiPool?.length ?? kCappellaStickerCount,
    ),
    intensity: cfg,
    palette: LyricVisualizerPalette.fromScheme(scheme),
    avatarSource: avatarSource,
    seed: 7,
    fontScale: 1,
    motionEnabled: motion,
    initials: const <CappellaSender, String>{},
    avatarPool: avatarPool,
    emojiPool: emojiPool,
    fontWeight: fontWeight,
  );
}

void main() {
  group('lines', () {
    test('render end reads the shared render hints', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      final List<CappellaLine> lines = buildCappellaLines(rt.lines);
      // 歌词行：直接用 runtime 的 renderEndMs。
      expect(lines[0].renderEndMs, rt.lines[0].renderEndMs);
      expect(cappellaRenderHintsOf(lines[0]), rt.lines[0].renderHints);
      // 间奏行：按同一公式现算（1s 行 → 1.24s，folia normal 过渡）。
      for (final CappellaLine l in lines.where(
        (CappellaLine l) => l.isInterlude,
      )) {
        expect(
          l.renderEndMs,
          LyricVisualizerRenderHints.of(
            startMs: l.startMs,
            endMs: l.endMs,
          ).renderEndMs,
        );
      }
      expect(
        LyricVisualizerRenderHints.of(startMs: 0, endMs: 1000).renderEndMs,
        1240,
      );
      expect(cappellaIsNormalTiming(lines[0]), isTrue);
    });

    test('long gaps get an interlude line, glyphs are trimmed', () {
      final List<CappellaLine> lines = _wordLines();
      expect(lines.map((CappellaLine l) => l.text).toList(), <String>[
        '夜空に光',
        'Hello bright world',
        kCappellaInterludeText,
        'また会おう',
      ]);
      expect(lines[2].isInterlude, isTrue);
      expect(lines[2].startMs, 4850);
      expect(lines[2].endMs, 11950);
      expect(lines[2].chars, hasLength(6));
      expect(lines[1].chars.length, 'Hello bright world'.length);
      expect(lines.map((CappellaLine l) => l.index), <int>[0, 1, 2, 3]);
    });

    test('a late first line gets a leading interlude', () {
      final List<CappellaLine> lines = buildCappellaLines(
        LyricVisualizerRuntime(
          const LyricTimeline(
            format: 'lrc',
            lines: <LyricLine>[
              LyricLine(
                startMs: 10000,
                endMs: 12000,
                syllables: <LyricSyllable>[
                  LyricSyllable(text: 'late', startMs: 10000, endMs: 12000),
                ],
              ),
            ],
          ),
        ).lines,
      );
      expect(lines, hasLength(2));
      expect(lines.first.isInterlude, isTrue);
      expect(lines.first.startMs, 500);
      expect(lines.first.endMs, 9500);
    });

    test('active line keeps the latest line until its render end', () {
      final List<CappellaLine> lines = _wordLines();
      expect(cappellaActiveLineIndexAt(lines, 500), -1);
      expect(cappellaActiveLineIndexAt(lines, 1100), 0);
      expect(cappellaActiveLineIndexAt(lines, 3600), 1);
      expect(cappellaActiveLineIndexAt(lines, 8000), 2);
      expect(cappellaActiveLineIndexAt(lines, 12300), 3);
      expect(cappellaActiveLineIndexAt(lines, 30000), -1);
      expect(cappellaVisibleLineIndexAt(lines, 30000), 3);
    });
  });

  group('messages', () {
    final CappellaSequencing seq = cappellaIntensityConfig(
      LyricVisualizerIntensity.normal,
    ).sequencing;

    test('TTML agents become stable senders: first agent on the right', () {
      final Map<int, CappellaSender>? senders = cappellaAgentSenders(
        _wordLines(),
      );
      expect(senders, isNotNull);
      expect(senders![0], const CappellaSender(right: true, avatarIndex: 8));
      expect(senders[1], const CappellaSender(right: false, avatarIndex: 0));

      final List<CappellaMessage> msgs = buildCappellaMessages(
        lines: _wordLines(),
        titleText: 'Song',
        sequencing: seq,
        showEmo: true,
        stickerPoolSize: kCappellaStickerCount,
      );
      expect(msgs.first.kind, CappellaMessageKind.title);
      final List<CappellaMessage> lyric = msgs
          .where((CappellaMessage m) => m.kind == CappellaMessageKind.lyric)
          .toList();
      expect(lyric.first.right, isTrue);
      expect(lyric[1].right, isFalse);
    });

    test('interludes become stickers only when stickers are on', () {
      List<CappellaMessage> build(bool emo) => buildCappellaMessages(
        lines: _wordLines(),
        titleText: 'Song',
        sequencing: seq,
        showEmo: emo,
        stickerPoolSize: kCappellaStickerCount,
      );
      final CappellaMessage withEmo = build(
        true,
      ).firstWhere((CappellaMessage m) => m.line?.isInterlude ?? false);
      expect(withEmo.kind, CappellaMessageKind.emo);
      expect(withEmo.activationStartMs, 4850);
      expect(withEmo.activationEndMs, greaterThan(4850));
      final CappellaMessage without = build(
        false,
      ).firstWhere((CappellaMessage m) => m.line?.isInterlude ?? false);
      expect(without.kind, CappellaMessageKind.lyric);
      expect(without.displayText, kCappellaInterludeText);
    });

    test('sequencing is deterministic and forces the right side', () {
      final List<CappellaLine> lines = buildCappellaLines(
        LyricVisualizerRuntime(_plainTimeline(12)).lines,
      );
      List<CappellaMessage> build() => buildCappellaMessages(
        lines: lines,
        titleText: 'Song',
        sequencing: seq,
        showEmo: false,
        stickerPoolSize: kCappellaStickerCount,
      );
      final List<CappellaMessage> a = build();
      final List<CappellaMessage> b = build();
      expect(
        a.map((CappellaMessage m) => (m.id, m.sender)).toList(),
        b.map((CappellaMessage m) => (m.id, m.sender)).toList(),
      );
      // 每 5 句强制一句右侧（下标 4、9）。
      expect(
        a[1 + 4].sender,
        const CappellaSender(right: true, avatarIndex: 8),
      );
      expect(
        a[1 + 9].sender,
        const CappellaSender(right: true, avatarIndex: 8),
      );
      // 左侧发送者头像下标依次递增。
      final List<int> leftAvatars = <int>[
        for (final CappellaMessage m in a)
          if (m.kind == CappellaMessageKind.lyric && !m.right)
            m.sender.avatarIndex,
      ];
      for (int i = 1; i < leftAvatars.length; i++) {
        expect(leftAvatars[i], greaterThanOrEqualTo(leftAvatars[i - 1]));
      }
    });

    test('random reactions respect the cap', () {
      final List<CappellaLine> lines = buildCappellaLines(
        LyricVisualizerRuntime(_plainTimeline(48)).lines,
      );
      final CappellaSequencing chaotic = cappellaIntensityConfig(
        LyricVisualizerIntensity.chaotic,
      ).sequencing;
      final List<CappellaMessage> msgs = buildCappellaMessages(
        lines: lines,
        titleText: 'Song',
        sequencing: chaotic,
        showEmo: true,
        stickerPoolSize: kCappellaStickerCount,
      );
      final int reactions = msgs
          .where((CappellaMessage m) => m.id.startsWith('emo-reaction'))
          .length;
      expect(reactions, lessThanOrEqualTo((48 / 6).floor()));
      for (final CappellaMessage m in msgs.where(
        (CappellaMessage m) => m.id.startsWith('emo-reaction'),
      )) {
        expect(m.activationStartMs, m.line!.endMs);
      }
      // 平静档不插表情回复。
      final List<CappellaMessage> calm = buildCappellaMessages(
        lines: lines,
        titleText: 'Song',
        sequencing: cappellaIntensityConfig(
          LyricVisualizerIntensity.calm,
        ).sequencing,
        showEmo: true,
        stickerPoolSize: kCappellaStickerCount,
      );
      expect(
        calm.where((CappellaMessage m) => m.kind == CappellaMessageKind.emo),
        isEmpty,
      );
    });

    test('no lyrics: title plus a sticker', () {
      final List<CappellaMessage> msgs = buildCappellaMessages(
        lines: const <CappellaLine>[],
        titleText: 'Song',
        sequencing: seq,
        showEmo: true,
        stickerPoolSize: kCappellaStickerCount,
      );
      expect(msgs.map((CappellaMessage m) => m.kind), <CappellaMessageKind>[
        CappellaMessageKind.title,
        CappellaMessageKind.emo,
      ]);
    });

    test('message state and sent filtering', () {
      final List<CappellaLine> lines = _wordLines();
      final List<CappellaMessage> msgs = buildCappellaMessages(
        lines: lines,
        titleText: 'Song',
        sequencing: seq,
        showEmo: true,
        stickerPoolSize: kCappellaStickerCount,
      );
      final CappellaMessage first = msgs[1];
      expect(cappellaMessageState(first, 1100, 0), CappellaMessageState.active);
      expect(cappellaMessageState(first, 3600, 1), CappellaMessageState.passed);
      expect(
        cappellaMessageState(msgs.first, 3600, 1),
        CappellaMessageState.idle,
      );
      expect(cappellaSentMessages(msgs, 500, -1), hasLength(1));
      expect(cappellaSentMessages(msgs, 3600, 1), hasLength(3));
    });

    test('fit keeps the newest messages within the height budget', () {
      final List<CappellaMessage> msgs = <CappellaMessage>[
        for (int i = 0; i < 30; i++)
          CappellaMessage(
            id: '$i',
            kind: CappellaMessageKind.title,
            text: '$i',
            sender: const CappellaSender(right: true, avatarIndex: 8),
          ),
      ];
      // 可用高度 = 720 - 240 = 480；每条 100 → 4 条。
      final List<CappellaMessage> fit = cappellaFitMessages(
        msgs,
        720,
        (_) => 100,
      );
      expect(fit.map((CappellaMessage m) => m.id), <String>[
        '26',
        '27',
        '28',
        '29',
      ]);
      // 再高也至少两条。
      expect(cappellaFitMessages(msgs, 720, (_) => 1000), hasLength(2));
      // 最多 20 条。
      expect(cappellaFitMessages(msgs, 100000, (_) => 1), hasLength(20));
    });
  });

  group('reveal', () {
    test('per-character reveal, lookahead and timestamp readiness', () {
      final CappellaLine line = _wordLines().first; // 夜 空 に 光
      final CappellaRevealPlan plan = cappellaRevealPlan(line);
      expect(plan.characters, <String>['夜', '空', 'に', '光']);
      expect(plan.revealMs, <int>[1000, 1300, 1600, 1800]);
      expect(plan.fadeMs, <int>[300, 300, 200, 1400]);
      expect(plan.bubbleTargetMs, <int>[800, 1100, 1400, 1600]);
      expect(plan.timestampReadyMs, 3200);
      expect(cappellaCharCountAt(plan.revealMs, 999), 0);
      expect(cappellaCharCountAt(plan.revealMs, 1000), 1);
      expect(cappellaCharCountAt(plan.revealMs, 1700), 3);
      expect(cappellaCharCountAt(plan.revealMs, 99999), 4);
    });

    test('line-level lyrics are interpolated evenly', () {
      final CappellaLine line = buildCappellaLines(
        LyricVisualizerRuntime(sampleLineTimeline()).lines,
      ).first;
      final CappellaRevealPlan plan = cappellaRevealPlan(line);
      expect(plan.characters.length, 7);
      for (int i = 1; i < plan.revealMs.length; i++) {
        expect(plan.revealMs[i], greaterThan(plan.revealMs[i - 1]));
      }
      expect(plan.revealMs.first, 500);
    });

    test('timestamp format', () {
      expect(cappellaFormatTimestamp(0), '0:00');
      expect(cappellaFormatTimestamp(65400), '1:05');
      expect(cappellaFormatTimestamp(-5), '0:00');
    });
  });

  group('layout', () {
    test('viewport sizing follows folia breakpoints', () {
      final CappellaViewport narrow = CappellaViewport.of(
        const Size(390, 844),
        1,
      );
      expect(narrow.padX, 16);
      expect(narrow.maxTextWidth, 223);
      expect(narrow.baseFontSize, 18);
      final CappellaViewport wide = CappellaViewport.of(
        const Size(1280, 720),
        2,
      );
      expect(wide.padX, 56);
      expect(wide.panelWidth, 896);
      expect(wide.maxTextWidth, 553);
      expect(wide.baseFontSize, 26);
    });

    testWidgets('prefix bubble sizes grow and wrap within the max width', (
      WidgetTester tester,
    ) async {
      final CappellaMeasureCache cache = CappellaMeasureCache();
      final CappellaLine line = buildCappellaLines(
        LyricVisualizerRuntime(sampleLineTimeline()).lines,
      )[1];
      final CappellaMotion motion = cappellaIntensityConfig(
        LyricVisualizerIntensity.normal,
      ).motion;
      final CappellaBubbleStyle style = CappellaBubbleStyle.of(
        message: CappellaMessage(
          id: 'x',
          kind: CappellaMessageKind.lyric,
          sender: const CappellaSender(right: false, avatarIndex: 0),
          line: line,
        ),
        active: true,
        baseFontSize: 18,
        motion: motion,
      );
      final CappellaBubbleMetrics m = cache.metricsFor(line, style, 223);
      expect(m.sizes, hasLength(line.chars.length + 1));
      expect(identical(cache.metricsFor(line, style, 223), m), isTrue);
      final double maxW = 223 + style.padX * 2 + 2;
      for (final Size s in m.sizes) {
        expect(s.width, lessThanOrEqualTo(maxW + 1));
      }
      expect(m.full.height, greaterThan(m.sizes[1].height));
      expect(m.targetAt(0), m.sizes.first);
      expect(m.targetAt(999999), m.full);
    });

    test('bubble colors keep readable text', () {
      final LyricVisualizerPalette p = LyricVisualizerPalette.fromScheme(
        ColorScheme.fromSeed(
          seedColor: const Color(0xFFFFEB3B),
          brightness: Brightness.light,
        ),
      );
      for (final CappellaSender s in const <CappellaSender>[
        CappellaSender(right: true, avatarIndex: 8),
        CappellaSender(right: false, avatarIndex: 0),
        CappellaSender(right: false, avatarIndex: 4),
      ]) {
        final CappellaBubbleColors c = cappellaBubbleColors(s, p);
        expect(c.text, isNot(c.background));
      }
    });

    test('generated avatars: left senders never reuse the right avatar', () {
      for (int seed = 0; seed < 20; seed++) {
        final int right = cappellaGeneratedAvatarIndex(
          const CappellaSender(right: true, avatarIndex: 8),
          seed,
        );
        for (int i = 0; i < 12; i++) {
          final int left = cappellaGeneratedAvatarIndex(
            CappellaSender(right: false, avatarIndex: i),
            seed,
          );
          expect(left, isNot(right));
          expect(left, inInclusiveRange(0, kCappellaGeneratedAvatarCount - 1));
        }
      }
      expect(
        cappellaCoverCell(const CappellaSender(right: false, avatarIndex: 6)),
        3,
      );
      expect(cappellaAvatarInitial(' alice '), 'A');
      expect(cappellaAvatarInitial(''), isNull);
    });

    test('spring settles on its target', () {
      final CappellaSpringValue s = CappellaSpringValue(1);
      const CappellaSpring spring = CappellaSpring(
        stiffness: 340,
        damping: 28,
        mass: 0.72,
      );
      for (int i = 0; i < 120; i++) {
        s.step(1.12, 1 / 60, spring);
      }
      expect(s.x, closeTo(1.12, 1e-3));
      final CappellaTweenValue tw = CappellaTweenValue(10);
      tw.retarget(20, 0, 0.2);
      expect(tw.valueAt(0), 10);
      expect(tw.valueAt(0.1), inExclusiveRange(10, 20));
      expect(tw.valueAt(0.2), 20);
    });
  });

  group('custom packs', () {
    test('stable pool pick: right fixed, left rotates over the rest', () {
      const CappellaSender right = CappellaSender(
        right: true,
        avatarIndex: kCappellaRightAvatarIndex,
      );
      final int r = cappellaStablePoolIndex(5, right, 7);
      expect(r, inInclusiveRange(0, 4));
      final Set<int> left = <int>{
        for (int i = 0; i < 4; i++)
          cappellaStablePoolIndex(
            5,
            CappellaSender(right: false, avatarIndex: i),
            7,
          ),
      };
      expect(left, isNot(contains(r)));
      expect(left, hasLength(4));
      expect(cappellaStablePoolIndex(1, right, 7), 0);
      expect(
        cappellaGeneratedAvatarIndex(right, 7),
        cappellaStablePoolIndex(kCappellaGeneratedAvatarCount, right, 7),
      );
    });

    test('custom sources fall back when the pack is empty', () {
      final LyricVisualizerTuning custom =
          LyricVisualizerTuning(cappellaTunings, const <String, Object?>{
            kCappellaTuningAvatarSource: 'custom',
            kCappellaTuningEmojiSource: 'custom',
          });
      expect(
        cappellaEffectiveAvatarSource(custom, 0),
        CappellaAvatarSource.cover,
      );
      expect(
        cappellaEffectiveAvatarSource(custom, 3),
        CappellaAvatarSource.custom,
      );
      expect(cappellaUsesCustomEmoji(custom, 0), isFalse);
      expect(cappellaUsesCustomEmoji(custom, 2), isTrue);
      final LyricVisualizerTuning defaults = LyricVisualizerTuning.defaults(
        cappellaTunings,
      );
      expect(cappellaUsesCustomEmoji(defaults, 5), isFalse);
      // 素材包参数只在选了自定义时显示。
      final LyricVisualizerTuningSpec pack = cappellaTunings.firstWhere(
        (LyricVisualizerTuningSpec s) => s.key == kCappellaTuningEmojiPack,
      );
      expect(pack, isA<LyricVisualizerAssetPackSpec>());
      expect(pack.visibleWhen!(defaults), isFalse);
      expect(pack.visibleWhen!(custom), isTrue);
      expect(
        cappellaTunings.map((LyricVisualizerTuningSpec s) => s.key),
        isNot(contains('intensity')),
      );
      expect(
        cappellaVisualizerEntry.backgroundFor(defaults),
        LyricVisualizerBackgroundRequest.selected,
      );
    });

    testWidgets('scene paints custom avatars, custom emoji and theme weight', (
      WidgetTester tester,
    ) async {
      final ui.Image a = _solidImage(const Color(0xFFFF0000));
      final ui.Image b = _solidImage(const Color(0xFF00FF00));
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final CappellaScene scene = CappellaScene(
        _sceneConfig(
          _wordLines(),
          avatarSource: CappellaAvatarSource.custom,
          avatarPool: CappellaFixedImagePool(<ui.Image?>[a, null]),
          emojiPool: CappellaFixedImagePool(<ui.Image?>[b]),
          fontWeight: FontWeight.w700,
        ),
      );
      addTearDown(scene.dispose);
      for (final int t in <int>[0, 1500, 3600, 8000, 12500]) {
        final LyricVisualizerTick tick = LyricVisualizerTick(
          timeMs: t,
          elapsed: t / 1000,
        );
        scene.advance(const Size(1280, 720), tick);
        final ui.PictureRecorder rec = ui.PictureRecorder();
        scene.paint(Canvas(rec), const Size(1280, 720), tick);
        rec.endRecording().dispose();
      }
      expect(scene.visibleIds, isNotEmpty);
    });

    testWidgets('asset pack lists and decodes images from the store', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory.systemTemp.createTempSync('cappella_');
      addTearDown(() => root.deleteSync(recursive: true));
      final CappellaAssetPack pack = CappellaAssetPack(
        openStore: () async => LyricVisualizerAssetStore(root),
      );
      addTearDown(pack.dispose);
      await tester.runAsync(() async {
        final ui.Image img = _solidImage(const Color(0xFF0000FF));
        final ByteData? png = await img.toByteData(
          format: ui.ImageByteFormat.png,
        );
        img.dispose();
        final Directory dir = Directory('${root.path}/cappella/emoji')
          ..createSync(recursive: true);
        File(
          '${dir.path}/0000_smile.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
        pack.load('emoji');
        for (int i = 0; i < 100 && pack.imageAt(0) == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(pack.length, 1);
      expect(pack.imageAt(0), isNotNull);
      pack.load(null);
      expect(pack.length, 0);
    });
  });

  group('scene', () {
    testWidgets('visible messages follow the song and old rows scroll off', (
      WidgetTester tester,
    ) async {
      final CappellaScene scene = CappellaScene(
        _sceneConfig(
          buildCappellaLines(LyricVisualizerRuntime(_plainTimeline(30)).lines),
          showEmo: false,
        ),
      );
      addTearDown(scene.dispose);
      const Size size = Size(390, 844);
      scene.advance(size, const LyricVisualizerTick(timeMs: 0, elapsed: 0));
      expect(scene.visibleIds.first, 'title');
      expect(scene.visibleIds, hasLength(2));
      scene.advance(
        size,
        const LyricVisualizerTick(timeMs: 50000, elapsed: 0.5),
      );
      expect(scene.visibleIds, isNot(contains('title')));
      expect(scene.visibleIds.last, 'line-50000-25');
      expect(scene.visibleIds.length, greaterThanOrEqualTo(2));
    });
  });

  group('widget', () {
    testWidgets('default tuning', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, cappellaVisualizerEntry);
    });

    testWidgets('color avatars, no stickers, chaotic', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        intensity: LyricVisualizerIntensity.chaotic,
        tuning: const <String, Object?>{
          kCappellaTuningAvatarSource: 'color',
          kCappellaTuningShowEmo: false,
        },
      );
    });

    testWidgets('generated avatars, calm', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        intensity: LyricVisualizerIntensity.calm,
        tuning: const <String, Object?>{kCappellaTuningAvatarSource: 'builtin'},
      );
    });

    testWidgets('custom packs selected (no store in tests) + theme + audio', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        tuning: const <String, Object?>{
          kCappellaTuningAvatarSource: 'custom',
          kCappellaTuningEmojiSource: 'custom',
        },
        theme: const LyricVisualizerTheme(
          fontWeight: FontWeight.w700,
          intensity: LyricVisualizerIntensity.chaotic,
        ),
        audio: SyntheticVisualizerAudio(),
      );
    });

    testWidgets('line-level timeline', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 1500, 3100, 4500, 5900, 7000],
      );
    });

    testWidgets('motion off', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('narrow phone', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    testWidgets('long song on a narrow phone, seeking backwards', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        cappellaVisualizerEntry,
        timeline: _plainTimeline(40),
        size: const Size(390, 844),
        timesMs: const <int>[0, 30000, 60000, 79000, 10000, 2000],
      );
    });
  });
}
