import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/android_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.fushi.reader/mihon');
  const MihonExtensionRef extension = MihonExtensionRef(
    packageName: 'fixture',
    apkPath: 'fixture.apk',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'concurrent native requests configure one authenticated policy endpoint first',
    () async {
      final List<String> calls = <String>[];
      int? port;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call.method);
            if (call.method == 'configureProxyPolicy') {
              final Map<Object?, Object?> args =
                  call.arguments as Map<Object?, Object?>;
              port = args['port']! as int;
              expect(port, inInclusiveRange(1, 65535));
              expect(
                args['token'],
                isA<String>().having(
                  (String s) => s.length,
                  'length',
                  greaterThanOrEqualTo(32),
                ),
              );
            } else if (call.method == 'invoke') {
              expect(calls.first, 'configureProxyPolicy');
            }
            return null;
          });
      final AndroidMihonRuntime runtime = AndroidMihonRuntime(channel: channel);
      await Future.wait(<Future<Object?>>[
        runtime.invokeBridge(extension, 'getDetailsManga', <String, Object?>{}),
        runtime.invokeBridge(extension, 'getChapterList', <String, Object?>{}),
      ]);
      expect(
        calls.where((String value) => value == 'configureProxyPolicy'),
        hasLength(1),
      );
      final Socket live = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port!,
      );
      live.destroy();
      await runtime.dispose();
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port!),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'failed configuration does not issue outbound operations and can be retried',
    () async {
      int attempts = 0;
      int invocations = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'configureProxyPolicy' && attempts++ == 0) {
              throw PlatformException(code: 'POLICY_UNAVAILABLE');
            }
            if (call.method == 'invoke') invocations++;
            return null;
          });
      final AndroidMihonRuntime runtime = AndroidMihonRuntime(channel: channel);
      await expectLater(
        runtime.invokeBridge(extension, 'getChapterList', <String, Object?>{}),
        throwsA(isA<MihonRuntimeException>()),
      );
      expect(invocations, 0);
      await runtime.invokeBridge(
        extension,
        'getChapterList',
        <String, Object?>{},
      );
      expect(invocations, 1);
      await runtime.dispose();
    },
  );
}
