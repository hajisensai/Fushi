import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/system_transparency.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(SystemTransparency.channelName);
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> pushFromNative(Object? value) async {
    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      MethodCall('reduceTransparencyChanged', value),
    );
    await messenger.handlePlatformMessage(
      SystemTransparency.channelName,
      message,
      (_) {},
    );
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SystemTransparency.debugReset();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SystemTransparency.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  test('读到的原生值写入 notifier', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'getReduceTransparency');
      return true;
    });

    await SystemTransparency.initialize();

    expect(SystemTransparency.reduceTransparency.value, isTrue);
  });

  test('原生推送 reduceTransparencyChanged 更新 notifier', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    await SystemTransparency.initialize();
    expect(SystemTransparency.reduceTransparency.value, isFalse);

    await pushFromNative(true);
    expect(SystemTransparency.reduceTransparency.value, isTrue);

    await pushFromNative(false);
    expect(SystemTransparency.reduceTransparency.value, isFalse);

    // 非 bool 载荷忽略。
    await pushFromNative('yes');
    expect(SystemTransparency.reduceTransparency.value, isFalse);
  });

  test('PlatformException 保持 false', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'boom');
    });

    await SystemTransparency.initialize();

    expect(SystemTransparency.reduceTransparency.value, isFalse);
  });

  test('原生未注册（MissingPluginException）保持 false', () async {
    await SystemTransparency.initialize();

    expect(SystemTransparency.reduceTransparency.value, isFalse);
  });

  test('Android / Linux 不调用通道', () async {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.linux,
    ]) {
      SystemTransparency.debugReset();
      debugDefaultTargetPlatformOverride = platform;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return true;
      });

      await SystemTransparency.initialize();

      expect(calls, 0);
      expect(SystemTransparency.reduceTransparency.value, isFalse);
    }
  });
}
