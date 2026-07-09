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
      MethodChannel('app.hibiki.reader/window_capture');
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
  });
}
