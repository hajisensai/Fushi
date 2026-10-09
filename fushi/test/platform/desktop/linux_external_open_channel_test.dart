import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/desktop/linux_external_open_channel.dart';

/// BUG-3087 / BUG-3089：Dart → Linux runner 的两个通知走的是
/// `app.fushi/external_video` 本身，方法名与 runner 逐字一致；runner 没实现 /
/// 报错 / 不回时只记日志，不能把启动或退出链打断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.fushi/external_video');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('ready / exiting 发到 external_video 通道上', () async {
    final List<MethodCall> calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });

    await LinuxExternalOpenChannel.notifyHandlerReady(channel);
    await LinuxExternalOpenChannel.notifyExiting(channel);

    expect(calls.map((MethodCall c) => c.method), <String>[
      'externalOpenReady',
      'appExiting',
    ]);
    expect(calls.every((MethodCall c) => c.arguments == null), isTrue);
  });

  test('runner 没实现（MissingPlugin）不抛出', () async {
    await expectLater(
      LinuxExternalOpenChannel.notifyExiting(channel),
      completes,
    );
  });

  test('runner 报错（PlatformException）不抛出', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'boom');
    });
    await expectLater(
      LinuxExternalOpenChannel.notifyHandlerReady(channel),
      completes,
    );
  });

  test('runner 不回：到上界放行，不拖住退出链', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) {
      return Future<Object?>.delayed(const Duration(seconds: 3));
    });
    final Stopwatch watch = Stopwatch()..start();
    await LinuxExternalOpenChannel.notifyExiting(channel);
    expect(
      watch.elapsed,
      lessThan(
        LinuxExternalOpenChannel.notifyTimeout + const Duration(seconds: 1),
      ),
    );
  });
}
