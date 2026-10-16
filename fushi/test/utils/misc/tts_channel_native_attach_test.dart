import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

/// BUG-3439：Android 原生 `TtsChannelHandler` 随 Activity 新建 / 销毁，引擎却被
/// audio_service 缓存复用。Activity 重建后新 handler 的本地音频库列表是空的，而
/// Dart 只在 `initialise()` 推过一次配置 → 查词静默没有本地音频，重启才好。修法：
/// 原生 handler 挂上后发 `nativeHandlerAttached`，Dart 收到就重推配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> sendFromPlatform(String method) async {
    final ByteData message = FushiChannels.tts.codec.encodeMethodCall(
      MethodCall(method),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(FushiChannels.tts.name, message, (_) {});
  }

  tearDown(() => FushiChannels.tts.setMethodCallHandler(null));

  test('原生 handler 每次挂上都触发一次重绑', () async {
    int rebinds = 0;
    TtsChannel.onNativeHandlerAttached(() async => rebinds++);

    await sendFromPlatform(TtsChannel.nativeHandlerAttachedMethod);
    expect(rebinds, 1);
    // Activity 再重建一次：新 handler 又是空库，必须再推一次。
    await sendFromPlatform(TtsChannel.nativeHandlerAttachedMethod);
    expect(rebinds, 2);
  });

  test('其它平台侧调用不触发重绑', () async {
    int rebinds = 0;
    TtsChannel.onNativeHandlerAttached(() async => rebinds++);
    await sendFromPlatform('somethingElse');
    expect(rebinds, 0);
  });

  group('接线守卫', () {
    // 测试 CWD = fushi/。
    String read(String path) => File(path).readAsStringSync();

    test('原生 TtsChannelHandler.register 挂上后通知 Dart', () {
      final String src = read(
        'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
      );
      final int start = src.indexOf('public void register(');
      final int end = src.indexOf('public void destroy()', start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      expect(
        src.substring(start, end),
        contains(
          'invokeMethod("${TtsChannel.nativeHandlerAttachedMethod}", null)',
        ),
      );
    });

    test('main() 在 initialise() 之前装上重绑回调', () {
      final String src = read('lib/main.dart');
      final int hook = src.indexOf('TtsChannel.onNativeHandlerAttached(');
      expect(
        src.substring(hook, hook + 120),
        contains('appModel.rebindLocalAudioForNativeHandler'),
      );
      final int init = src.indexOf('await appModel.initialise();');
      expect(hook, isNonNegative);
      expect(init, greaterThan(hook));
    });
  });
}
