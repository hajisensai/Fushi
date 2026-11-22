/// 背景测试的共享素材：挂载一个背景跨时间推帧、把一个场景直接画成像素比较。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/background_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

import '../visualizer_test_helpers.dart';

/// 背景测试用的空样式（只为借 `visualizerContextFor` 造 context）。
final LyricVisualizerEntry kBackgroundHostEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.defaultMode,
  label: () => 'host',
  icon: FushiIcons.image,
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  builder: (LyricVisualizerContext _) => const SizedBox.expand(),
);

/// 造一个背景用的 context。
LyricVisualizerContext backgroundContext({
  FakeVisualizerClock? clock,
  bool motion = true,
  bool playing = true,
  LyricVisualizerAudio? audio,
  Brightness brightness = Brightness.dark,
}) {
  final LyricVisualizerContext c = visualizerContextFor(
    kBackgroundHostEntry,
    clock: clock ?? FakeVisualizerClock(),
    motion: motion,
    playing: playing,
    audio: audio,
  );
  if (brightness == Brightness.dark) return c;
  return c.copyWith(
    palette: LyricVisualizerPalette.fromScheme(
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.light,
      ),
    ),
  );
}

/// 挂载 [entry] 在 [timesMs] 各时间点推帧（与样式的 `pumpVisualizerAcross` 同形），断言不抛、卸载干净。
Future<void> pumpBackgroundAcross(
  WidgetTester tester,
  LyricVisualizerBackgroundEntry entry, {
  Map<String, Object?> tuning = const <String, Object?>{},
  bool motion = true,
  bool playing = true,
  LyricVisualizerAudio? audio,
  Brightness brightness = Brightness.dark,
  Size size = const Size(1280, 720),
  List<int> timesMs = const <int>[0, 1100, 3600, 8000, 14500, 30000],
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FakeVisualizerClock clock = FakeVisualizerClock();
  final LyricVisualizerContext c = backgroundContext(
    clock: clock,
    motion: motion,
    playing: playing,
    audio: audio,
    brightness: brightness,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: !motion),
        child: SizedBox.expand(
          child: entry.builder(c, LyricVisualizerTuning(entry.tunings, tuning)),
        ),
      ),
    ),
  );
  for (final int t in timesMs) {
    clock.positionMs = t;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '${entry.id} @ ${t}ms');
  }
  await tester.pumpWidget(const SizedBox.shrink());
  expect(tester.takeException(), isNull);
}

/// 直接驱动一个场景：配置、按 [steps] 推进（每步 [dt] 秒、歌词时间同步前进），画成 RGBA 像素。
/// 在 `tester.runAsync` 外读像素会卡住，所以整个过程放在 runAsync 里。
Future<Uint8List> renderScene(
  WidgetTester tester,
  LyricVisualizerBackgroundScene scene,
  LyricVisualizerContext context,
  LyricVisualizerTuning tuning, {
  Size size = const Size(160, 90),
  int steps = 30,
  double dt = 1 / 30,
  int startMs = 1000,
}) async {
  scene.configure(context, tuning, 1);
  double elapsed = 0;
  for (int i = 0; i < steps; i++) {
    elapsed += dt;
    scene.advance(
      LyricVisualizerTick(
        timeMs: startMs + (elapsed * 1000).round(),
        elapsed: elapsed,
        dt: dt,
      ),
    );
  }
  final ui.PictureRecorder rec = ui.PictureRecorder();
  scene.paint(Canvas(rec), size);
  final ui.Picture picture = rec.endRecording();
  final ui.Image image = picture.toImageSync(
    size.width.toInt(),
    size.height.toInt(),
  );
  picture.dispose();
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(),
  );
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 两帧像素有多少个字节不同。
int pixelDifference(Uint8List a, Uint8List b) {
  int n = 0;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) n++;
  }
  return n;
}

/// 一张小图（左右渐变 + 上下渐变），给需要源图的效果用。
Future<ui.Image> gradientImage(WidgetTester tester, {int w = 64, int h = 48}) {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec);
  final Rect r = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  canvas.drawRect(
    r,
    Paint()
      ..shader = ui.Gradient.linear(r.topLeft, r.topRight, const <Color>[
        Color(0xFF102040),
        Color(0xFFF0C080),
      ]),
  );
  canvas.drawRect(
    r,
    Paint()
      ..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter, const <Color>[
        Color(0x00000000),
        Color(0x8000FF00),
      ]),
  );
  final ui.Picture p = rec.endRecording();
  final ui.Image img = p.toImageSync(w, h);
  p.dispose();
  return Future<ui.Image>.value(img);
}

/// RGBA 像素（runAsync 里读）。
Future<Uint8List> pixelsOf(WidgetTester tester, ui.Image image) async {
  final ByteData? d = await tester.runAsync<ByteData?>(
    () => image.toByteData(),
  );
  return d!.buffer.asUint8List();
}
