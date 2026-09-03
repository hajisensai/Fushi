import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:path/path.dart' as p;

/// BUG-2069 审查 B3/B4 守卫：**生产采样循环**本身（不是纯函数 [galAnimatedFrameBudget]）
/// 必须真的消费整句时长预算，并且**落进 ffmpeg 的帧数**必须等于最终预算。
///
/// 此前只有纯函数有测试，采样循环整段换成无条件 `break` 也全绿；而循环里 budget 只
/// 决定何时停止、不裁剪已落盘的帧，`pending` 期间抓的 30~60 帧会原样进编码器——文档
/// 说的「null 退回 frames 帧的旧行为」根本不成立。这两条都在这里钉住。
///
/// 捕获走真实的 `window_capture` MethodChannel（mock 掉 native 侧），编码走
/// [setFfmpegBackendForTesting] 注入的假后端：它在编码时数目录里真实存在的帧文件，
/// 这就是「交给 ffmpeg 的帧数」的直接观测，不是对源码的间接推断。
class _RecordingFfmpegBackend implements FfmpegBackend {
  int? framesHandedToEncoder;
  List<String>? lastArgs;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    lastArgs = args;
    final int inputIndex = args.indexOf('-i');
    final String pattern = args[inputIndex + 1];
    final Directory dir = Directory(p.dirname(pattern));
    framesHandedToEncoder = dir
        .listSync()
        .whereType<File>()
        .where((File f) => p.basename(f.path).startsWith('frame_'))
        .length;
    // 输出必须非空，否则 [captureWindowGifBytes] 判编码失败并降级重试。
    final String outputPath = args.last;
    await File(outputPath).writeAsBytes(<int>[1, 2, 3]);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('app.fushi.reader/window_capture');
  late _RecordingFfmpegBackend backend;
  late int captureCalls;

  /// 每帧回一段非空「PNG」字节；内容不重要（编码器是假的），只要 `ok` 为真。
  void installCaptureMock({void Function(int call)? onCall}) {
    captureCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method != 'captureWindow') return null;
      captureCalls++;
      onCall?.call(captureCalls);
      return <Object?, Object?>{
        'pngBytes': Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]),
      };
    });
  }

  setUp(() {
    backend = _RecordingFfmpegBackend();
    setFfmpegBackendForTesting(backend);
  });

  tearDown(() {
    setFfmpegBackendForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('没有整句时长时只抓基线帧数（旧行为逐字等价）', () async {
    installCaptureMock();
    final GalWindowAnimatedCapture? out = await captureWindowGifBytes(
      hwnd: 1,
      frames: 4,
      intervalMs: 0,
      fps: 8,
    );

    expect(out, isNotNull);
    expect(captureCalls, 4);
    expect(backend.framesHandedToEncoder, 4);
  });

  test('时长未定期间继续采样，定下来后按预算收口并把落盘帧裁到预算', () async {
    // 3190 ms @ 8 fps → ceil(3190*8/1000) = 26 帧。
    final Completer<Duration?> target = Completer<Duration?>();
    installCaptureMock(onCall: (int call) {
      // 远超 frames=4 之后才给出时长：此前预算是 8 s 上限（64 帧）。
      if (call == 12 && !target.isCompleted) {
        target.complete(const Duration(milliseconds: 3190));
      }
    });

    final GalWindowAnimatedCapture? out = await captureWindowGifBytes(
      hwnd: 1,
      frames: 4,
      intervalMs: 0,
      fps: 8,
      targetDuration: target.future,
    );

    expect(out, isNotNull);
    // 采样没有停在 frames=4：时长未定时循环必须继续（语音还在播）。
    expect(captureCalls, greaterThan(4));
    expect(captureCalls, 26);
    expect(backend.framesHandedToEncoder, 26);
  });

  test('时长解析为 null 时，已多抓的帧必须被裁回基线帧数', () async {
    final Completer<Duration?> target = Completer<Duration?>();
    installCaptureMock(onCall: (int call) {
      // 第 12 帧才知道「读不出时长」：此时已经比基线多抓了 8 帧。
      if (call == 12 && !target.isCompleted) target.complete(null);
    });

    final GalWindowAnimatedCapture? out = await captureWindowGifBytes(
      hwnd: 1,
      frames: 4,
      intervalMs: 0,
      fps: 8,
      targetDuration: target.future,
    );

    expect(out, isNotNull);
    expect(captureCalls, greaterThan(4)); // pending 期间确实多抓了
    // 但交给编码器的必须是基线帧数——这就是文档说的「退回 frames 帧的旧行为」。
    expect(backend.framesHandedToEncoder, 4);
  });

  test('trimSurplusAnimationFrames 只删尾部超额帧并返回保留数', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('fushi_trim_test_');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    for (int i = 0; i < 7; i++) {
      await File(p.join(dir.path, galAnimationFrameName(i)))
          .writeAsBytes(<int>[i]);
    }

    final int kept = await trimSurplusAnimationFrames(
      directory: dir,
      captured: 7,
      budget: 3,
    );

    expect(kept, 3);
    expect(
      dir.listSync().whereType<File>().map((File f) => p.basename(f.path)),
      <String>['frame_000.png', 'frame_001.png', 'frame_002.png'],
    );
    // 预算没收缩时一帧都不删。
    expect(
      await trimSurplusAnimationFrames(
        directory: dir,
        captured: 3,
        budget: 10,
      ),
      3,
    );
    expect(dir.listSync().whereType<File>().length, 3);
  });
}
