import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_gpu.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_visualizer.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/media/music/visualizer/visualizer_test_helpers.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 回归测试（2026-11-23 镜台整机卡死）：上游 3.50.0 引擎的 Flutter GPU `Texture.fromImage` 在 UI
/// 线程现造 `ContentContext`，其 GLES 提交永不完成，卡死 `GpuSubmissionTracker`，之后真渲染器
/// 每帧 `HostBuffer::Reset` 都退役整格 arena 再新分配——进程私有提交每 300 帧涨约 900 MB，且与
/// Flutter GPU 是否还在用无关。修复在 `ci/patches/flutter-engine/3.50.0/engine-gpu-texture-from-image.patch`。
///
/// 逐段（`toImageSync` / 异步 `toImage` / `fromImage` / 镜台 CPU 场景 step）各推 300 帧，再在空闲帧上
/// 量增长；结果同时追加到 `%TEMP%/stage-probe.log`。只在装了补丁引擎的 SDK 上会绿。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Texture.fromImage 之后空闲帧不再持续涨私有提交', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));

    Future<void> frames(int n) async {
      for (int i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    final List<String> report = <String>[];
    final Map<String, double> idleGrowthMb = <String, double>{};
    // 结果同时追加到文件：换了引擎 dll 后可脱离 flutter test 直接跑 exe 取数。
    final File out = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}stage-probe.log',
    );
    void log(String line) {
      debugPrint(line);
      report.add(line);
      out.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    }

    Future<void> measure(String label) async {
      await frames(60);
      final int before = _privateBytes();
      await frames(300);
      final double mb = (_privateBytes() - before) / (1024 * 1024);
      idleGrowthMb[label] = mb;
      log(
        '[stage-probe] $label delta=${mb.toStringAsFixed(1)}MB '
        'private=${(_privateBytes() / (1024 * 1024)).toStringAsFixed(0)}MB',
      );
    }

    await measure('idle-baseline');
    await measure('idle-baseline-2');

    await tester.runAsync<DioramaGpuPipelines?>(DioramaGpu.load);
    ui.Picture pic() {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas c = Canvas(rec);
      c.drawRect(
        const Rect.fromLTWH(0, 0, 256, 128),
        Paint()..color = const Color(0xFF3366CC),
      );
      final TextPainter tp = TextPainter(
        text: const TextSpan(
          text: '夜空に光る星',
          style: TextStyle(fontSize: 40, color: Color(0xFFFFFFFF)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset.zero);
      tp.dispose();
      return rec.endRecording();
    }

    // S1：toImageSync，图立即 dispose。
    int before = _privateBytes();
    for (int i = 0; i < 300; i++) {
      final ui.Picture p = pic();
      final ui.Image img = p.toImageSync(256, 128);
      p.dispose();
      img.dispose();
      await tester.pump(const Duration(milliseconds: 16));
    }
    log(
      '[stage-probe] S1-toImageSync-during delta='
      '${((_privateBytes() - before) / 1048576).toStringAsFixed(1)}MB',
    );
    await measure('after-S1-idle');

    // S2：异步 toImage，图立即 dispose。
    before = _privateBytes();
    for (int i = 0; i < 300; i++) {
      final ui.Picture p = pic();
      final ui.Image? img = await tester.runAsync<ui.Image>(
        () => p.toImage(256, 128),
      );
      p.dispose();
      img?.dispose();
      await tester.pump(const Duration(milliseconds: 16));
    }
    log(
      '[stage-probe] S2-toImage-during delta='
      '${((_privateBytes() - before) / 1048576).toStringAsFixed(1)}MB',
    );
    await measure('after-S2-idle');

    // S3：异步 toImage + gpu.Texture.fromImage。
    before = _privateBytes();
    for (int i = 0; i < 300; i++) {
      final ui.Picture p = pic();
      final ui.Image? img = await tester.runAsync<ui.Image>(
        () => p.toImage(256, 128),
      );
      p.dispose();
      final gpu.Texture t = gpu.Texture.fromImage(gpu.gpuContext, img!);
      expect(t.width, 256);
      img.dispose();
      await tester.pump(const Duration(milliseconds: 16));
    }
    log(
      '[stage-probe] S3-fromImage-during delta='
      '${((_privateBytes() - before) / 1048576).toStringAsFixed(1)}MB',
    );
    await measure('after-S3-idle');

    // S4：Canvas 版场景（forGpu:false）step。
    const Size size = Size(1280, 720);
    final FakeVisualizerClock clock = FakeVisualizerClock(1000);
    final DioramaScene scene = DioramaScene(forGpu: false)
      ..pixelRatio = 1
      ..update(visualizerContextFor(dioramaVisualizerEntry, clock: clock));
    before = _privateBytes();
    for (int i = 0; i < 300; i++) {
      clock.positionMs = 1000 + i * 16;
      scene.step(
        size,
        LyricVisualizerTick(timeMs: clock.positionMs, elapsed: i / 60),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    log(
      '[stage-probe] S4-cpu-scene-step-during delta='
      '${((_privateBytes() - before) / 1048576).toStringAsFixed(1)}MB',
    );
    scene.dispose();
    await measure('after-S4-idle');
    log('[stage-probe] DONE');
    // 原版引擎：after-S3-idle / after-S4-idle 各约 +900 MB；补丁引擎在 ±15 MB。
    for (final String label in <String>['after-S3-idle', 'after-S4-idle']) {
      expect(
        idleGrowthMb[label],
        lessThan(150),
        reason:
            '$label：fromImage 之后空闲 300 帧私有提交涨了 '
            '${idleGrowthMb[label]?.toStringAsFixed(1)} MB（引擎补丁丢了？）',
      );
    }
    debugPrint('[stage-probe] SUMMARY\n${report.join('\n')}');
  });
}

int _privateBytes() {
  if (!Platform.isWindows) return ProcessInfo.currentRss;
  final DynamicLibrary k32 = DynamicLibrary.open('kernel32.dll');
  final int Function() currentProcess = k32
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final int Function(int, Pointer<Uint8>, int) getInfo = k32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Uint8>, int)
      >('K32GetProcessMemoryInfo');
  final Pointer<Uint8> buf = calloc<Uint8>(80);
  try {
    buf.cast<Uint32>().value = 80;
    if (getInfo(currentProcess(), buf, 80) == 0) return -1;
    return (buf + 72).cast<Uint64>().value;
  } finally {
    calloc.free(buf);
  }
}
