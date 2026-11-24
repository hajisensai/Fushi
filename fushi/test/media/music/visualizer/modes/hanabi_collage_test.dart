import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_ambient.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage_decor.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage_plan.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_timeline.dart';

const HanabiTheme _theme = HanabiTheme(
  primary: 0xff7a8a,
  accent: 0xff7a8a,
  secondary: 0x7ad0ff,
  background: 0x0b0d24,
);

HanabiPalette _palette() =>
    resolveHanabiPalette(PaletteRole.kawaii, _theme, HanabiColorMode.theme);

HanabiLine _line(String text) {
  final List<String> chars = text.split('');
  return HanabiLine(
    chars: chars,
    charStart: <double>[for (int i = 0; i < chars.length; i++) 1 + i * 0.1],
    charEnd: <double>[for (int i = 0; i < chars.length; i++) 1.1 + i * 0.1],
    startTime: 1,
    endTime: 1 + chars.length * 0.1,
  );
}

CollagePlanInput _input({
  required String family,
  bool isBridge = false,
  double amount = 1,
  CollageOpening? opening,
  CollageRecipe? previous,
}) => CollagePlanInput(
  seed: 'song:p0:s1',
  family: family,
  mood: HanabiMood.neutral,
  isBridge: isBridge,
  block: BlockStyle.band,
  shotNumber: 2,
  bounds: const CollageRect(-200, -60, 400, 120),
  screen: const CollageRect(-640, -360, 1280, 720),
  unit: 720,
  palette: _palette(),
  enterAt: 1,
  exitAt: 4,
  exitDuration: 0.5,
  start: 0.8,
  end: 4.6,
  keyword: 'HANABI',
  motifs: hanabiCollageMotifs('Song'),
  bursts: const <CollageBurst>[
    CollageBurst(x: 100, y: -200, at: 1, main: true, radius: 120),
    CollageBurst(x: -300, y: -150, at: 2, main: true, radius: 100),
    CollageBurst(x: 0, y: 0, at: 1.5, main: false, radius: 40),
  ],
  launches: const <CollageLaunch>[
    CollageLaunch(
      fromX: 100,
      fromY: 400,
      toX: 100,
      toY: -200,
      at: 0.55,
      duration: 0.45,
    ),
  ],
  amount: amount,
  previous: previous,
  opening: opening,
);

String _describe(CollagePlan plan) => <String>[
  plan.recipe?.name ?? '-',
  for (final CollageItem item in plan.items)
    switch (item) {
      StripItem() => 'strip:${item.style.name}:${item.y.toStringAsFixed(3)}',
      EchoItem() => 'echo:${item.text}:${item.vertical}',
      StickerItem() =>
        'sticker:${item.shape.name}:${item.x.toStringAsFixed(3)}',
      TapeItem() => 'tape:${item.pattern.name}',
      PatchItem() => 'patch:${item.pattern.name}',
      WindowItem() => 'window:${item.title}',
      LabelItem() => 'label:${item.text}',
      HeadlineItem() => 'headline:${item.text}',
      PopItem() => 'pop:${item.icon}:${item.x.toStringAsFixed(3)}',
      WhooshItem() => 'whoosh:${item.icon}',
      FloaterItem() =>
        'floater:${item.shape.name}:${item.at.toStringAsFixed(3)}',
    },
].join('|');

void main() {
  group('collage plan (folia collagePlan.ts)', () {
    test('same input → same plan; amount 0 → empty', () {
      for (final String family in <String>[
        'uchiage',
        'kiku',
        'botan',
        'yanagi',
        'hoshikuzu',
        'senko',
      ]) {
        final CollagePlan a = planShotCollage(_input(family: family));
        final CollagePlan b = planShotCollage(_input(family: family));
        expect(_describe(a), _describe(b));
        expect(a.items, isNotEmpty);
      }
      expect(planShotCollage(_input(family: 'kiku', amount: 0)).items, isEmpty);
    });

    test('recipe comes from the family preference and avoids previous', () {
      for (int k = 0; k < 20; k++) {
        final CollageRecipe r = chooseCollageRecipe(
          'yanagi',
          false,
          CollageRecipe.quiet,
          () => k / 20,
        );
        expect(r, CollageRecipe.echo);
      }
      expect(
        chooseCollageRecipe('kiku', true, null, () => 0.5),
        CollageRecipe.bridge,
      );
    });

    test('bridge = film strip + rising floaters; opening = title card', () {
      final CollagePlan bridge = planShotCollage(
        _input(family: 'kiku', isBridge: true),
      );
      expect(bridge.recipe, CollageRecipe.bridge);
      final StripItem film = bridge.items.whereType<StripItem>().single;
      expect(film.style, StripStyle.film);
      expect(film.at, closeTo(0.9, 1e-9));
      expect(bridge.items.whereType<FloaterItem>().length, 7);

      final CollagePlan opening = planShotCollage(
        _input(
          family: 'kiku',
          isBridge: true,
          opening: const CollageOpening('Song', 'Artist'),
        ),
      );
      expect(opening.recipe, CollageRecipe.opening);
      expect(
        opening.items.whereType<WindowItem>().single.title,
        '♪ now playing',
      );
      expect(opening.items.whereType<HeadlineItem>().single.text, 'Song');
      expect(opening.items.whereType<LabelItem>().single.text, 'Artist');
      // 开场标题卡那个镜头不放开花图标。
      expect(opening.items.whereType<PopItem>(), isEmpty);
    });

    test(
      'keyword: short line whole (latin upper-cased), else longest word',
      () {
        expect(pickCollageKeyword(_line('hello')), 'HELLO');
        expect(pickCollageKeyword(_line('花火')), '花火');
        expect(pickCollageKeyword(null), isNull);
        expect(pickCollageKeyword(_line('a')), isNull);
      },
    );
  });

  group('ambient (folia mg/ambient.ts)', () {
    test('distant bursts are pure functions of seed / k', () {
      final HanabiDistantBurst a = hanabiDistantBurstAt(
        's',
        3,
        0.2,
        10,
        1280,
        1238,
      );
      final HanabiDistantBurst b = hanabiDistantBurstAt(
        's',
        3,
        0.2,
        10,
        1280,
        1238,
      );
      expect(a.at, b.at);
      expect(a.x, b.x);
      expect(a.event.spec.count, inInclusiveRange(26, 45));
      expect(a.at, greaterThanOrEqualTo(10 + 3.1 / 0.2));
      final (int first, int last) = hanabiDistantRange(30, 0.2, 10, 60);
      expect(first, 2);
      expect(last, 4);
      expect(hanabiDistantRange(30, 0, 10, 60), (0, -1));
    });

    test('parallax wraps inside [-margin, height + margin)', () {
      for (double rise = 0; rise < 5000; rise += 137) {
        final double y = hanabiParallaxY(100, rise, 0.42, -3, 720, 259);
        expect(y, greaterThanOrEqualTo(-259));
        expect(y, lessThan(720 + 259));
      }
    });
  });

  testWidgets('unit decor, collage textures and overlay paint without error', (
    WidgetTester tester,
  ) async {
    const Size size = Size(1280, 720);
    final HanabiProfile profile = hanabiProfiles.first;
    final ShotTiming timing =
        ShotTiming(
            start: 0,
            end: 5,
            worldY: 0,
            launchAt: 0.55,
            enterAt: 1,
            punchAt: 1,
            riseFrom: null,
            riseTo: null,
            drift: 0,
            spin: 0,
            spinDrift: 0,
          )
          ..exitAt = 4
          ..exitDuration = 0.5;
    final HanabiUnitDecor decor = HanabiUnitDecor(
      unitSeed: 'song:p0',
      size: size,
      shots: <HanabiDecorShot>[
        for (final bool bridge in <bool>[true, false])
          HanabiDecorShot(
            id: bridge ? 'b' : 's',
            profile: profile,
            isBridge: bridge,
            timing: timing,
            palette: _palette(),
            line: bridge ? null : _line('花火の夜'),
            textBounds: null,
            mains: const <BurstEvent>[],
            launches: const <LaunchEvent>[],
          ),
      ],
      rise: (double t) => -t * 40,
      startTime: 0,
      endTime: 30,
      ambientDensity: 1,
      collageAmount: 1,
      motifs: hanabiCollageMotifs('Song'),
      opening: const CollageOpening('Song', 'Artist'),
    );
    final HanabiSprites sprites = HanabiSprites.create();
    final HanabiOverlay overlay = HanabiOverlay();
    expect(decor.ambient, isNotNull);
    expect(decor.unitCollage, isNotNull);
    expect(decor.plans.first.recipe, CollageRecipe.opening);
    expect(decor.shotLifeEnd(0), greaterThan(4));
    for (double t = 0; t < 8; t += 0.37) {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      decor.paintBack(canvas, sprites, t, -t * 40);
      decor.paintShotBack(canvas, 0, t);
      decor.paintShotBack(canvas, 1, t);
      decor.paintShotFront(canvas, 0, t);
      decor.paintShotFront(canvas, 1, t);
      decor.paintFront(canvas, sprites, t, -t * 40);
      overlay.paint(canvas, size, _palette(), const TextStyle(), 1);
      recorder.endRecording().dispose();
    }
    final HanabiCollageCache cache = decor.cache!;
    expect(cache.length, greaterThan(0));
    // 片尾卡复用的装饰带：三种样式都能画。
    for (final StripStyle style in StripStyle.values) {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      paintCollageStrip(
        ui.Canvas(recorder),
        cache,
        StripItem(
          style: style,
          x: 640,
          y: 360,
          length: 1800,
          thickness: 40,
          rotation: 0.1,
          color: kCollageCandy[0],
          speed: 60,
          from: -1,
          at: 0,
          exitAt: 3,
          exitDuration: 0.5,
        ),
        0.6,
      );
      recorder.endRecording().dispose();
    }
    decor.dispose();
    overlay.dispose();
    sprites.dispose();
  });
}
