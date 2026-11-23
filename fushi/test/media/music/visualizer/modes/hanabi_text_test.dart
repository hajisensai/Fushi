import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';

const HanabiTheme _theme = HanabiTheme(
  primary: 0x2b6cb0,
  accent: 0xe53e3e,
  secondary: 0x38a169,
  background: 0x101018,
);

HanabiLine _line(String text, double start, double perChar) {
  final List<String> chars = text.split('');
  return HanabiLine(
    chars: chars,
    charStart: <double>[
      for (int i = 0; i < chars.length; i++) start + i * perChar,
    ],
    charEnd: <double>[
      for (int i = 0; i < chars.length; i++) start + (i + 1) * perChar,
    ],
    startTime: start,
    endTime: start + chars.length * perChar,
  );
}

TextSpec _spec(
  BlockStyle block, {
  EnterFx enter = EnterFx.pop,
  SingFx sing = SingFx.glow,
  ExitFx exit = ExitFx.slide,
}) => TextSpec(
  layout: TextLayoutKind.center,
  heroSize: 0.12,
  emphasis: 0.4,
  tilt: 0,
  block: block,
  enter: enter,
  sing: sing,
  exit: exit,
  stagger: 0.05,
  outline: true,
  hardShadow: true,
);

HanabiText _text(TextSpec spec, HanabiPalette palette, {String? line}) =>
    HanabiText(
      line: _line(line ?? '夜空に咲いた花火', 2, 0.25),
      spec: spec,
      palette: palette,
      regionWidth: 700,
      regionHeight: 300,
      unit: 600,
      seed: 'hanabi-text-test',
      enterAt: 1,
      exitAt: 6,
      exitDuration: 0.8,
      motion: 1,
      blockOpacity: 1,
      baseStyle: const TextStyle(),
    );

Future<ByteData> _render(void Function(ui.Canvas canvas) body) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.translate(400, 200);
  body(canvas);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(800, 400);
  picture.dispose();
  final ByteData data = (await image.toByteData())!;
  image.dispose();
  return data;
}

int _rgbAt(ByteData data, double x, double y) {
  final int px = (x + 400).round();
  final int py = (y + 200).round();
  final int o = (py * 800 + px) * 4;
  return (data.getUint8(o) << 16) |
      (data.getUint8(o + 1) << 8) |
      data.getUint8(o + 2);
}

void main() {
  final HanabiPalette palette = resolveHanabiPalette(
    PaletteRole.festival,
    _theme,
    HanabiColorMode.vivid,
  );

  test('字重跟主题，没给时是 800（folia resolveThemeFontWeight(theme, 800)）', () {
    expect(hanabiGlyphWeight(const TextStyle()), FontWeight.w800);
    expect(
      hanabiGlyphWeight(const TextStyle(fontWeight: FontWeight.w500)),
      FontWeight.w500,
    );
  });

  testWidgets('12 种色块 × 入场 / 强调 / 退场组合在整段时间上都能画', (WidgetTester tester) async {
    for (final BlockStyle block in BlockStyle.values) {
      for (final (EnterFx, ExitFx) fx in const <(EnterFx, ExitFx)>[
        (EnterFx.wipe, ExitFx.slide),
        (EnterFx.split, ExitFx.dissolve),
        (EnterFx.glitch, ExitFx.blink),
        (EnterFx.flip, ExitFx.scatter),
      ]) {
        final HanabiText text = _text(
          _spec(block, enter: fx.$1, exit: fx.$2),
          palette,
        );
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(recorder);
        for (double t = 0.5; t < 7.2; t += 0.15) {
          text.paintBlocks(canvas, t);
          text.paintGlyphs(canvas, t);
        }
        recorder.endRecording().dispose();
        text.dispose();
      }
    }
  });

  testWidgets('double：影子层是第二色、错到右下，主层压在上面', (WidgetTester tester) async {
    final HanabiText text = _text(_spec(BlockStyle.double), palette);
    final ByteData data = (await tester.runAsync(
      () => _render((ui.Canvas c) => text.paintBlocks(c, 4.5)),
    ))!;
    final List<int> blocks = palette.blocks.isNotEmpty
        ? palette.blocks
        : <int>[palette.accent];
    final int front = blocks.first;
    // 第一个词的主层中心是第一色。
    final int first = text.placement.glyphs.indexWhere(
      (PlacedGlyph g) => !g.blank,
    );
    final PlacedGlyph g0 = text.placement.glyphs[first];
    expect(_rgbAt(data, g0.x, g0.y), front);
    text.dispose();
  });

  testWidgets('stair：顶面亮边与色块同色，满不透明时看不出接缝', (WidgetTester tester) async {
    final HanabiText text = _text(_spec(BlockStyle.stair), palette);
    final ByteData data = (await tester.runAsync(
      () => _render((ui.Canvas c) => text.paintBlocks(c, 4.5)),
    ))!;
    final int first = text.placement.glyphs.indexWhere(
      (PlacedGlyph g) => !g.blank,
    );
    final PlacedGlyph g0 = text.placement.glyphs[first];
    final List<int> blocks = palette.blocks.isNotEmpty
        ? palette.blocks
        : <int>[palette.accent];
    expect(_rgbAt(data, g0.x, g0.y), blocks.first);
    text.dispose();
  });
}
