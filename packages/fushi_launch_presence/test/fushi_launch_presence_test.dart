import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_launch_presence/fushi_launch_presence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test/launch_presence');

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('原生回答 hasUi=false → 无界面', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, kLaunchPresenceQueryMethod);
          return <String, Object?>{
            kLaunchPresenceHasUiKey: false,
            kLaunchPresenceDetailKey: 'activity=none importance=125',
          };
        });
    final LaunchPresence? p = await queryLaunchPresence(channel: channel);
    expect(p, isNotNull);
    expect(p!.hasUi, isFalse);
    expect(p.detail, 'activity=none importance=125');
  });

  test('引擎上没注册通道 → null（不知道），不抛', () async {
    expect(await queryLaunchPresence(channel: channel), isNull);
  });

  test('形状不对 → null', () {
    expect(LaunchPresence.fromMap(null), isNull);
    expect(
      LaunchPresence.fromMap(<Object?, Object?>{kLaunchPresenceHasUiKey: 1}),
      isNull,
    );
  });
}
