import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';

/// galgame 视频卡片：`WindowCaptureChannel` 滚动录制四方法的 MethodChannel 契约
/// （mock native）。native WGC 持久会话仅 Windows 真机可验；此处只钉 Dart 侧
/// 「方法名 / 参数名 / 结果解析 / 降级」——ffmpeg 合成侧按这份契约编码。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'app.fushi.reader/window_capture',
  );
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => WindowCaptureChannel.debugPlatformSupportedOverride = true);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    WindowCaptureChannel.debugPlatformSupportedOverride = null;
  });

  group('startWindowRecording', () {
    test('按契约传 hwnd/fps/maxSeconds/maxWidth，native true -> true', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        seen = call;
        return true;
      });
      final bool started = await WindowCaptureChannel.startWindowRecording(
        hwnd: 4242,
        fps: 8,
        maxSeconds: 30,
        maxWidth: 800,
      );
      expect(started, true);
      expect(seen!.method, 'startWindowRecording');
      expect(seen!.arguments, <String, Object?>{
        'hwnd': 4242,
        'fps': 8,
        'maxSeconds': 30,
        'maxWidth': 800,
      });
    });

    test('默认参数 5fps / 20s / 640 宽', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        seen = call;
        return true;
      });
      await WindowCaptureChannel.startWindowRecording(hwnd: 1);
      expect((seen!.arguments as Map)['fps'], 5);
      expect((seen!.arguments as Map)['maxSeconds'], 20);
      expect((seen!.arguments as Map)['maxWidth'], 640);
    });

    test('native false / null / 异常 / 缺失 -> 全部 false 不抛', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return false;
      });
      expect(await WindowCaptureChannel.startWindowRecording(hwnd: 1), false);
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return null;
      });
      expect(await WindowCaptureChannel.startWindowRecording(hwnd: 1), false);
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await WindowCaptureChannel.startWindowRecording(hwnd: 1), false);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await WindowCaptureChannel.startWindowRecording(hwnd: 1), false);
    });

    test('非 Windows：不碰 channel 直接 false', () async {
      WindowCaptureChannel.debugPlatformSupportedOverride = false;
      bool invoked = false;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        invoked = true;
        return true;
      });
      expect(await WindowCaptureChannel.startWindowRecording(hwnd: 1), false);
      expect(invoked, false);
    });
  });

  group('stopWindowRecording / isWindowRecording', () {
    test('stop 调 stopWindowRecording，异常与缺失都吞掉', () async {
      final List<String> methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        methods.add(call.method);
        return null;
      });
      await WindowCaptureChannel.stopWindowRecording();
      expect(methods, <String>['stopWindowRecording']);
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'boom');
      });
      await WindowCaptureChannel.stopWindowRecording();
      messenger.setMockMethodCallHandler(channel, null);
      await WindowCaptureChannel.stopWindowRecording();
    });

    test('非 Windows：stop 不碰 channel', () async {
      WindowCaptureChannel.debugPlatformSupportedOverride = false;
      bool invoked = false;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        invoked = true;
        return null;
      });
      await WindowCaptureChannel.stopWindowRecording();
      expect(invoked, false);
    });

    test('isWindowRecording 透传 bool，缺失 / 非 Windows 为 false', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'isWindowRecording');
        return true;
      });
      expect(await WindowCaptureChannel.isWindowRecording, true);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await WindowCaptureChannel.isWindowRecording, false);
      WindowCaptureChannel.debugPlatformSupportedOverride = false;
      expect(await WindowCaptureChannel.isWindowRecording, false);
    });
  });

  group('exportWindowRecording', () {
    test('按契约传 fromTickMs/toTickMs/directory，解析帧列表并按 tick 升序', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        seen = call;
        return <Object?, Object?>{
          'frames': <Object?>[
            <Object?, Object?>{
              'path': r'C:\tmp\frame_00001.jpg',
              'tickMs': 1200,
            },
            <Object?, Object?>{
              'path': r'C:\tmp\frame_00000.jpg',
              'tickMs': 1000,
            },
            <Object?, Object?>{'tickMs': 1400}, // 无 path -> 跳过
            <Object?, Object?>{'path': r'C:\tmp\x.jpg'}, // 无 tick -> 跳过
          ],
          'nowTickMs': 5000,
        };
      });
      final WindowRecordingExport res =
          await WindowCaptureChannel.exportWindowRecording(
            fromTickMs: 1000,
            toTickMs: 0,
            directory: r'C:\tmp',
          );
      expect(seen!.method, 'exportWindowRecording');
      expect(seen!.arguments, <String, Object?>{
        'fromTickMs': 1000,
        'toTickMs': 0,
        'directory': r'C:\tmp',
      });
      expect(res.ok, true);
      expect(res.error, isNull);
      expect(res.nowTickMs, 5000);
      expect(res.frames, const <WindowRecordingFrame>[
        WindowRecordingFrame(path: r'C:\tmp\frame_00000.jpg', tickMs: 1000),
        WindowRecordingFrame(path: r'C:\tmp\frame_00001.jpg', tickMs: 1200),
      ]);
    });

    test('native error（not_recording / no_frames）-> ok false 带原因', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <Object?, Object?>{
          'frames': <Object?>[],
          'nowTickMs': 77,
          'error': 'no_frames',
        };
      });
      final WindowRecordingExport res =
          await WindowCaptureChannel.exportWindowRecording(
            fromTickMs: 1,
            toTickMs: 2,
            directory: 'd',
          );
      expect(res.ok, false);
      expect(res.error, 'no_frames');
      expect(res.frames, isEmpty);
      expect(res.nowTickMs, 77);
    });

    test('PlatformException -> error 结果（不抛）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'export_failed', message: 'disk full');
      });
      final WindowRecordingExport res =
          await WindowCaptureChannel.exportWindowRecording(
            fromTickMs: 1,
            toTickMs: 0,
            directory: 'd',
          );
      expect(res.ok, false);
      expect(res.error, 'disk full');
    });

    test('native 缺失（MissingPluginException）-> error 结果', () async {
      final WindowRecordingExport res =
          await WindowCaptureChannel.exportWindowRecording(
            fromTickMs: 1,
            toTickMs: 0,
            directory: 'd',
          );
      expect(res.ok, false);
      expect(res.error, 'window_capture unavailable');
    });

    test('非 Windows：不碰 channel，返回 unsupported', () async {
      WindowCaptureChannel.debugPlatformSupportedOverride = false;
      bool invoked = false;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        invoked = true;
        return <Object?, Object?>{'frames': <Object?>[], 'nowTickMs': 1};
      });
      final WindowRecordingExport res =
          await WindowCaptureChannel.exportWindowRecording(
            fromTickMs: 1,
            toTickMs: 0,
            directory: 'd',
          );
      expect(invoked, false);
      expect(res.ok, false);
      expect(res.error, 'unsupported');
      expect(res.frames, isEmpty);
      expect(res.nowTickMs, 0);
    });

    test('native 返回 null / 空 map -> ok 但零帧（调用方按空处理）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return null;
      });
      final WindowRecordingExport res =
          await WindowCaptureChannel.exportWindowRecording(
            fromTickMs: 1,
            toTickMs: 0,
            directory: 'd',
          );
      expect(res.error, isNull);
      expect(res.frames, isEmpty);
      expect(res.nowTickMs, 0);
    });
  });
}
