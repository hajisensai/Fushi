import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/window_caption_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.hibiki/window');
  final List<MethodCall> calls = <MethodCall>[];

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('setWindowIcon 在 Windows 上以 path 调 setWindowIcon 并回传 bool', () async {
    if (!Platform.isWindows) {
      return; // 该断言只在 Windows 宿主有意义；其它平台见下一条降级测试。
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return true;
    });

    final bool ok = await WindowCaptionChannel.setWindowIcon('C:/x/icon.png');

    expect(ok, isTrue);
    expect(calls.single.method, 'setWindowIcon');
    expect((calls.single.arguments as Map)['path'], 'C:/x/icon.png');
  });

  test('非 Windows 平台直接返回 false 且不触达 channel', () async {
    if (Platform.isWindows) {
      return;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return true;
    });

    final bool ok = await WindowCaptionChannel.setWindowIcon('/tmp/icon.png');

    expect(ok, isFalse);
    expect(calls, isEmpty);
  });
}
