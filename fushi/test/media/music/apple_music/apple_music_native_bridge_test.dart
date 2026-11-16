import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(kAppleMusicNativeChannel);
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          final Object? args = call.arguments;
          final bool refresh = args is Map && args['refresh'] == true;
          return <String, Object?>{
            'developerToken': 'dev',
            'userToken': refresh ? 'fresh' : 'cached',
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // 反馈 caI0UrhA6-：Swift 侧只有收到 refresh 才用 .ignoreCache 重新生成 user token。
  test('userCredentials sends the refresh flag over the channel', () async {
    final AppleMusicNativeBridge bridge = AppleMusicNativeBridge();
    final AppleMusicUserCredentials? cached = await bridge.userCredentials();
    final AppleMusicUserCredentials? fresh = await bridge.userCredentials(
      refresh: true,
    );
    expect(cached?.userToken, 'cached');
    expect(fresh?.userToken, 'fresh');
    expect(calls.map((MethodCall c) => c.method), <String>[
      'userCredentials',
      'userCredentials',
    ]);
    expect(calls.map((MethodCall c) => c.arguments), <Object?>[
      <String, Object?>{'refresh': false},
      <String, Object?>{'refresh': true},
    ]);
  });
}
