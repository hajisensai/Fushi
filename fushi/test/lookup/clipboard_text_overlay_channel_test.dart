// 真透明剪切板文字窗 — 通道契约 + 背景色折算纯函数。native 后端不可测，这里钉
// Dart 侧契约：默认背景全透（0x00000000）、点字事件转发、单参 updateText。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/clipboard_text_overlay_controller.dart';
import 'package:fushi/src/platform/clipboard_text_overlay_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.fushi.reader/clipboard_text';
  const MethodCodec codec = StandardMethodCodec();

  setUp(() {
    ClipboardTextOverlayChannel.platformOverride = true;
  });

  Future<void> invokeFromNative(String method, [Object? arguments]) async {
    final ByteData data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    ClipboardTextOverlayChannel.clearEventHandlers();
    ClipboardTextOverlayChannel.platformOverride = null;
  });

  group('clipboardTextWindowBgColor（滑杆 0% = 真透明的核心契约）', () {
    test('0.0 → 完全透明背景 0x00000000', () {
      expect(clipboardTextWindowBgColor(0.0), 0x00000000);
    });

    test('1.0 → 全不透明纯黑 0xFF000000', () {
      expect(clipboardTextWindowBgColor(1.0), 0xFF000000);
    });

    test('0.5 → 半透明黑（alpha≈0x80）', () {
      expect(clipboardTextWindowBgColor(0.5), 0x80000000);
    });

    test('越界 clamp 到 [0,1]', () {
      expect(clipboardTextWindowBgColor(-3), 0x00000000);
      expect(clipboardTextWindowBgColor(5), 0xFF000000);
    });
  });

  group('toggledTextWindowBgOpacity（一键透明 0↔上一档）', () {
    test('有底色 → 切到 0', () {
      expect(
        toggledTextWindowBgOpacity(current: 0.35, lastNonZero: 0.35),
        0.0,
      );
    });

    test('已 0 → 恢复上一档非 0', () {
      expect(
        toggledTextWindowBgOpacity(current: 0.0, lastNonZero: 0.6),
        0.6,
      );
    });

    test('已 0 且从没设过 → 用 fallback', () {
      expect(
        toggledTextWindowBgOpacity(
            current: 0.0, lastNonZero: 0.0, fallback: 0.35),
        0.35,
      );
    });
  });

  group('ClipboardTextOverlayChannel native events', () {
    test('点字事件转发 text + index', () async {
      String? text;
      int? index;
      ClipboardTextOverlayChannel.setEventHandlers(
        onLookupText: (t, i) {
          text = t;
          index = i;
        },
      );

      await invokeFromNative('lookupText', <String, Object?>{
        'text': 'これは本だ',
        'index': 3,
      });

      expect(text, 'これは本だ');
      expect(index, 3);
    });

    test('空白文本不触发点字回调', () async {
      bool fired = false;
      ClipboardTextOverlayChannel.setEventHandlers(
        onLookupText: (_, __) => fired = true,
      );

      await invokeFromNative('lookupText', <String, Object?>{
        'text': '   ',
        'index': 0,
      });

      expect(fired, isFalse);
    });

    test('一键透明事件转发（顶栏透明按钮）', () async {
      int fired = 0;
      ClipboardTextOverlayChannel.setEventHandlers(
        onToggleTransparency: () => fired++,
      );

      await invokeFromNative('toggleTransparency');

      expect(fired, 1);
    });
  });

  group('ClipboardTextOverlayChannel outgoing calls', () {
    test('show 默认背景全透 + 白字', () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          captured = call;
          return true;
        },
      );

      final bool ok = await ClipboardTextOverlayChannel.show();

      expect(ok, isTrue);
      expect(captured?.method, 'show');
      expect(captured?.arguments, <String, Object?>{
        'fontSize': 20.0,
        'textColor': 0xFFFFFFFF,
        'bgColor': 0x00000000,
        'windowWidth': 0,
        'clickLookupEnabled': true,
        'windowTitle': '',
      });
    });

    test('updateText 单参 text（无 currentLine 语义）', () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          captured = call;
          return null;
        },
      );

      await ClipboardTextOverlayChannel.updateText('コピーした文');

      expect(captured?.method, 'updateText');
      expect(captured?.arguments, <String, Object?>{'text': 'コピーした文'});
    });

    test('非支持平台不发出调用', () async {
      ClipboardTextOverlayChannel.platformOverride = false;
      bool called = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          called = true;
          return null;
        },
      );

      await ClipboardTextOverlayChannel.updateText('x');
      await ClipboardTextOverlayChannel.setClickLookupEnabled(true);

      expect(called, isFalse);
    });
  });
}
