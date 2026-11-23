// 镜台的 Flutter GPU 渲染器：真像素断言。
//
// 要 `flutter test --enable-impeller --enable-flutter-gpu`（CI 的「Flutter GPU tests」一步就这么跑，
// 并设 FUSHI_REQUIRE_FLUTTER_GPU=1，拿不到 GPU 上下文时判红而不是跳过）。不带开关的普通全量里
// 这个文件自行跳过：GPU 不可用时样式走 Canvas 后备实现，那条路由 diorama_visualizer_test.dart 覆盖。
@Tags(<String>['flutter-gpu'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_gpu.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_render_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_visualizer.dart';

import '../visualizer_test_helpers.dart';

bool _gpuContextAvailable() {
  try {
    gpu.gpuContext;
    return true;
  } on Exception {
    return false;
  }
}

const int _w = 640;
const int _h = 360;

/// 某像素附近 [r] 半径内最大的 alpha。
int _maxAlphaNear(Uint8List rgba, double x, double y, int r) {
  int best = 0;
  final int cx = x.round(), cy = y.round();
  for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
      final int px = cx + dx, py = cy + dy;
      if (px < 0 || py < 0 || px >= _w || py >= _h) continue;
      best = math.max(best, rgba[(py * _w + px) * 4 + 3]);
    }
  }
  return best;
}

/// 矩形里最大的 alpha。
int _maxAlphaIn(Uint8List rgba, double x0, double y0, double x1, double y1) {
  int best = 0;
  for (int y = math.max(0, y0.floor()); y <= math.min(_h - 1, y1.ceil()); y++) {
    for (
      int x = math.max(0, x0.floor());
      x <= math.min(_w - 1, x1.ceil());
      x++
    ) {
      best = math.max(best, rgba[(y * _w + x) * 4 + 3]);
    }
  }
  return best;
}

/// FUSHI_DIORAMA_GPU_DUMP=<目录> 时把渲染结果存成 PNG（排障用）。
Future<void> _dump(ui.Image image, String name) async {
  final String? dir = Platform.environment['FUSHI_DIORAMA_GPU_DUMP'];
  if (dir == null || dir.isEmpty) return;
  final ByteData png = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  File('$dir/$name.png').writeAsBytesSync(png.buffer.asUint8List());
}

Future<Uint8List> _pixels(ui.Image image) async {
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  ))!;
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// 让 `Picture.toImage` → `Texture.fromImage` 的异步回调落地。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

DioramaPlane _movedPlane(DioramaPlane p, DioramaVec world) => DioramaPlane(
  raster: p.raster,
  layer: p.layer,
  src: p.src,
  dst: p.dst,
  anchor: p.anchor,
  world: world,
  right: p.right,
  up: p.up,
  scale: p.scale,
  color: const Color(0xFFFFFFFF),
  alpha: 1,
  additive: false,
  depthTest: false,
  cpuFog: false,
  renderOrder: p.renderOrder,
  sortDepth: p.sortDepth,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bool require = Platform.environment['FUSHI_REQUIRE_FLUTTER_GPU'] == '1';
  final bool available = _gpuContextAvailable();
  final String? skip = available || require
      ? null
      : 'Flutter GPU unavailable: run with --enable-impeller --enable-flutter-gpu';

  test('真 3D：文字平面与点云按透视投影落在画面上', () async {
    final DioramaGpuPipelines? pipelines = await DioramaGpu.load();
    expect(pipelines, isNotNull, reason: 'Flutter GPU 管线应建好');
    final DioramaScene scene = DioramaScene(forGpu: true)
      ..pixelRatio = 1
      ..update(
        visualizerContextFor(
          dioramaVisualizerEntry,
          clock: FakeVisualizerClock(),
          tuning: const <String, Object?>{
            DioramaTuningKeys.soulEnabled: true,
            DioramaTuningKeys.soulActiveEnabled: true,
          },
        ),
      );
    final DioramaGpuRenderer renderer = DioramaGpuRenderer(pipelines!);
    DioramaRenderFrame? frame;
    // 推几十帧：相机落位、逐单元图集异步变成 GPU 纹理。
    for (int i = 0; i < 80; i++) {
      frame = scene.step(
        const Size(_w + 0.0, _h + 0.0),
        LyricVisualizerTick(timeMs: 1000 + i * 10, elapsed: i / 60),
      );
      renderer.render(frame!, _w, _h)?.dispose();
      await _settle();
      final bool ready = frame.planes
          .where(
            (DioramaPlane p) => p.renderOrder == DioramaRenderOrder.unitBase,
          )
          .every((DioramaPlane p) => p.raster.unitTexture != null);
      if (ready && i > 40) break;
    }
    final DioramaRenderFrame f = frame!;
    final ui.Image image = renderer.render(f, _w, _h)!;
    expect(image.width, _w);
    expect(image.height, _h);
    final Uint8List rgba = await _pixels(image);
    await _dump(image, 'diorama_gpu_scene');
    image.dispose();

    final List<DioramaPlane> units = f.planes
        .where((DioramaPlane p) => p.renderOrder == DioramaRenderOrder.unitBase)
        .toList();
    expect(units.length, 4, reason: '「夜空に光」四个字各一块平面');
    expect(renderer.debugPlaneCount, greaterThanOrEqualTo(units.length));
    expect(renderer.debugParticleCount, greaterThan(0));
    // 每个字的平面四角投影到屏幕上，框里必须真的有字的像素（测试字体里 CJK 是空心豆腐块，
    // 所以看整块而不是只看中心）。
    for (final DioramaPlane p in units) {
      final (double sx, double sy, double d) = f.camera.project(p.world);
      expect(d, greaterThan(DioramaCamera.near));
      final double hu = p.src.width / 2 * p.scale;
      final double hv = p.src.height / 2 * p.scale;
      double x0 = double.infinity, y0 = double.infinity;
      double x1 = -double.infinity, y1 = -double.infinity;
      for (final (double a, double b) in const <(double, double)>[
        (-1, -1),
        (1, -1),
        (1, 1),
        (-1, 1),
      ]) {
        final (double cx, double cy, _) = f.camera.project(
          p.world + p.right * (a * hu) + p.up * (b * hv),
        );
        x0 = math.min(x0, cx);
        y0 = math.min(y0, cy);
        x1 = math.max(x1, cx);
        y1 = math.max(y1, cy);
      }
      expect(x1 - x0, greaterThan(4), reason: '平面有透视尺寸');
      expect(sx, inInclusiveRange(x0, x1));
      expect(sy, inInclusiveRange(y0, y1));
      expect(
        _maxAlphaIn(rgba, x0, y0, x1, y1),
        greaterThan(60),
        reason: 'unit in ($x0, $y0)-($x1, $y1) should be drawn',
      );
    }
    // 不是整屏糊满：大部分像素仍透明（下面是宿主的流体背景）。
    int covered = 0;
    for (int i = 3; i < rgba.length; i += 4) {
      if (rgba[i] > 8) covered++;
    }
    expect(covered, greaterThan(200));
    expect(covered / (_w * _h), lessThan(0.6));

    // 方向：把一个字挪到画面左上，像素必须出现在左上而不是镜像位置。
    final DioramaPlane probe = units.first;
    final DioramaVec moved =
        f.camera.position +
        f.camera.back * -8 +
        f.camera.right * -3.2 +
        f.camera.up * 1.6;
    final DioramaRenderFrame only = DioramaRenderFrame(
      camera: f.camera,
      fogColor: f.fogColor,
      motes: null,
      particles: null,
      planes: <DioramaPlane>[_movedPlane(probe, moved)],
    );
    final ui.Image oriented = renderer.render(only, _w, _h)!;
    final Uint8List o = await _pixels(oriented);
    await _dump(oriented, 'diorama_gpu_orientation');
    oriented.dispose();
    final (double ox, double oy, _) = f.camera.project(moved);
    expect(ox, lessThan(_w / 2));
    expect(oy, lessThan(_h / 2));
    expect(_maxAlphaNear(o, ox, oy, 3), greaterThan(60));
    expect(_maxAlphaNear(o, ox, _h - oy, 3), 0, reason: '没有上下颠倒');
    expect(_maxAlphaNear(o, _w - ox, oy, 3), 0, reason: '没有左右颠倒');

    renderer.dispose();
    scene.dispose();
  }, skip: skip);

  testWidgets('GPU 路径挂载冒烟（默认参数 / 长廊 / 窄屏）', (WidgetTester tester) async {
    await tester.runAsync(DioramaGpu.load);
    expect(DioramaGpu.pipelines, isNotNull);
    await pumpVisualizerAcross(tester, dioramaVisualizerEntry);
    await pumpVisualizerAcross(
      tester,
      dioramaVisualizerEntry,
      tuning: const <String, Object?>{
        DioramaTuningKeys.geometryMode: 'corridor',
      },
    );
    await pumpVisualizerAcross(
      tester,
      dioramaVisualizerEntry,
      size: const Size(390, 844),
      motion: false,
    );
  }, skip: skip != null);
}
