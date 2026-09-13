import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/source_url_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('source routing excludes unrelated callbacks and malformed URLs', () {
    expect(SourceUrlChannel.isSourceUrl('fushi://source?v=1'), isTrue);
    expect(SourceUrlChannel.isSourceUrl('FUSHI://SOURCE?v=1'), isTrue);
    for (final String value in <String>[
      'fushi://ankiFetch',
      'fushi://auth/dropbox',
      'fushi://lookup?text=source',
      'https://source?v=1',
      'fushi://source.evil?v=1',
      'fushi://[',
    ]) {
      expect(SourceUrlChannel.isSourceUrl(value), isFalse, reason: value);
    }
  });

  test(
    'one native subscription delivers sources to all Dart listeners',
    () async {
      const String channelName = 'app.fushi.reader/source_urls/stream';
      const StandardMethodCodec codec = StandardMethodCodec();
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final List<String> methodCalls = <String>[];
      final Completer<void> listened = Completer<void>();
      messenger.setMockMethodCallHandler(const MethodChannel(channelName), (
        MethodCall call,
      ) async {
        methodCalls.add(call.method);
        if (call.method == 'listen') listened.complete();
        return null;
      });
      final List<String> first = <String>[];
      final List<String> second = <String>[];
      final StreamSubscription<String> firstSubscription =
          SourceUrlChannel.urls.listen(first.add);
      final StreamSubscription<String> secondSubscription =
          SourceUrlChannel.urls.listen(second.add);
      await listened.future;
      for (final Object event in <Object>[
        'fushi://source?v=1&uid=cold',
        'fushi://ankiFetch',
        7,
        'fushi://source?v=1&uid=warm',
      ]) {
        await messenger.handlePlatformMessage(
          channelName,
          codec.encodeSuccessEnvelope(event),
          (ByteData? reply) {},
        );
      }
      await firstSubscription.cancel();
      await secondSubscription.cancel();
      expect(first, <String>[
        'fushi://source?v=1&uid=cold',
        'fushi://source?v=1&uid=warm',
      ]);
      expect(second, first);
      expect(methodCalls, <String>['listen', 'cancel']);
      messenger.setMockMethodCallHandler(
        const MethodChannel(channelName),
        null,
      );
    },
  );
}
