import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';

/// TODO-1162 外部窗口挖矿 M0：`WindowCaptureChannel` 的 MethodChannel 契约（mock native）。
///
/// native WGC 单帧捕获仅 Windows 真机可验；此处只钉 Dart 侧「方法名/参数/结果解析/
/// 降级」契约（native 缺失 -> MissingPluginException -> 空列表 / error 结果）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('app.fushi.reader/window_capture');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('listWindows', () {
    test('解析 native 返回的窗口列表（跳过无 hwnd 项）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'listWindows');
        return <Object?>[
          <Object?, Object?>{'hwnd': 111, 'title': 'ゲーム'},
          <Object?, Object?>{'hwnd': 222, 'title': 'Browser'},
          <Object?, Object?>{'title': 'no-handle'}, // 无 hwnd -> 跳过
        ];
      });
      final windows = await WindowCaptureChannel.listWindows();
      expect(windows.length, 2);
      expect(windows[0].hwnd, 111);
      expect(windows[0].title, 'ゲーム');
      expect(windows[1].hwnd, 222);
    });

    test('native 缺失（MissingPluginException）-> 空列表（降级不崩）', () async {
      // 不注册 handler -> MissingPluginException。
      final windows = await WindowCaptureChannel.listWindows();
      expect(windows, isEmpty);
    });

    test('native 返回 null -> 空列表', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return null;
      });
      final windows = await WindowCaptureChannel.listWindows();
      expect(windows, isEmpty);
    });
  });

  group('captureWindow', () {
    test('成功返回 pngBytes -> ok 为 true', () async {
      final Uint8List png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'captureWindow');
        expect((call.arguments as Map)['hwnd'], 999);
        return <Object?, Object?>{'pngBytes': png};
      });
      final res = await WindowCaptureChannel.captureWindow(999);
      expect(res.ok, true);
      expect(res.pngBytes, png);
      expect(res.error, isNull);
    });

    test('native 返回 error -> ok 为 false 带原因', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <Object?, Object?>{'error': 'window closed'};
      });
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, false);
      expect(res.error, 'window closed');
      expect(res.pngBytes, isNull);
    });

    test('PlatformException -> 收敛为 error 结果（不抛）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'capture_failed', message: 'WGC failed');
      });
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, false);
      expect(res.error, 'WGC failed');
    });

    test('native 缺失（MissingPluginException）-> error 结果', () async {
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, false);
      expect(res.error, 'window_capture unavailable');
    });

    test('空 pngBytes -> ok 为 false（空字节不算成功）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <Object?, Object?>{'pngBytes': Uint8List(0)};
      });
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, false);
    });

    // BUG-1096：native 的成功路径诊断（WGC 光标抑制是否真的生效 / 捕获目标是否被从
    // Magpie 缩放窗重定向）。它与 error 正交——有诊断不代表这一帧失败了。
    test('diagnostics 与 error 正交：带诊断的成功结果仍然是 ok', () async {
      final Uint8List png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <Object?, Object?>{
          'pngBytes': png,
          'diagnostics': 'capture target redirected: Magpie scaling window -> '
              'source window (Magpie.SrcHWND)',
        };
      });
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, true);
      expect(res.error, isNull);
      expect(res.diagnostics, contains('Magpie.SrcHWND'));
    });

    test('失败结果也能带诊断（光标抑制未生效这类事实不因失败而丢）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <Object?, Object?>{
          'error': 'capture timed out',
          'diagnostics': 'IGraphicsCaptureSession2 unavailable (needs Windows '
              '10 build 19041+); WGC cursor NOT suppressed hr=0x80004002',
        };
      });
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, false);
      expect(res.error, 'capture timed out');
      expect(res.diagnostics, contains('cursor NOT suppressed'));
    });

    test('native 不带 diagnostics 时为 null（无话可说 = 一切如预期）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <Object?, Object?>{
          'pngBytes': Uint8List.fromList([1, 2, 3, 4]),
        };
      });
      final res = await WindowCaptureChannel.captureWindow(1);
      expect(res.ok, true);
      expect(res.diagnostics, isNull);
    });
  });
}
