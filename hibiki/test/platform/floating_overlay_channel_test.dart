import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/floating_overlay_channel.dart';

class _TestFloatingChannel extends FloatingOverlayChannel {
  _TestFloatingChannel() : super(const MethodChannel('test/channel'));

  @override
  bool get isSupported => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FloatingOverlayChannel', () {
    late _TestFloatingChannel channel;

    setUp(() {
      channel = _TestFloatingChannel();
    });

    test('is a FloatingOverlayChannel', () {
      expect(channel, isA<FloatingOverlayChannel>());
    });

    test('canDrawOverlaysImpl returns false when channel returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.channel, (MethodCall call) async {
        if (call.method == 'canDrawOverlays') return null;
        return null;
      });

      final bool result = await channel.canDrawOverlaysImpl();
      expect(result, isFalse);
    });

    test('canDrawOverlaysImpl returns true when channel returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.channel, (MethodCall call) async {
        if (call.method == 'canDrawOverlays') return true;
        return null;
      });

      final bool result = await channel.canDrawOverlaysImpl();
      expect(result, isTrue);
    });

    test('showImpl returns false when channel returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.channel, (MethodCall call) async {
        if (call.method == 'show') return null;
        return null;
      });

      final bool result = await channel.showImpl();
      expect(result, isFalse);
    });

    test('showImpl returns true when channel returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.channel, (MethodCall call) async {
        if (call.method == 'show') return true;
        return null;
      });

      final bool result = await channel.showImpl();
      expect(result, isTrue);
    });

    test('isShowingImpl returns false when channel returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.channel, (MethodCall call) async {
        if (call.method == 'isShowing') return null;
        return null;
      });

      final bool result = await channel.isShowingImpl();
      expect(result, isFalse);
    });

    test('hideImpl completes without error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.channel, (MethodCall call) async {
        return null;
      });

      await expectLater(channel.hideImpl(), completes);
    });

    test('isSupported gates canDrawOverlaysImpl', () async {
      final _UnsupportedChannel unsupported = _UnsupportedChannel();
      final bool result = await unsupported.canDrawOverlaysImpl();
      expect(result, isFalse);
    });

    test('isSupported gates showImpl', () async {
      final _UnsupportedChannel unsupported = _UnsupportedChannel();
      final bool result = await unsupported.showImpl();
      expect(result, isFalse);
    });

    test('isSupported gates isShowingImpl', () async {
      final _UnsupportedChannel unsupported = _UnsupportedChannel();
      final bool result = await unsupported.isShowingImpl();
      expect(result, isFalse);
    });

    test('isSupported gates hideImpl', () async {
      final _UnsupportedChannel unsupported = _UnsupportedChannel();
      await expectLater(unsupported.hideImpl(), completes);
    });
  });
}

class _UnsupportedChannel extends FloatingOverlayChannel {
  _UnsupportedChannel() : super(const MethodChannel('test/unsupported'));

  @override
  bool get isSupported => false;
}
