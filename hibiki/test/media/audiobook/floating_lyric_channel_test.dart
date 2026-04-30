import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.hibiki.reader/floating_lyric';
  const MethodCodec codec = StandardMethodCodec();

  Future<void> invokeFromNative(String method, [Object? arguments]) async {
    final ByteData data = codec.encodeMethodCall(
      MethodCall(method, arguments),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  tearDown(FloatingLyricChannel.clearEventHandlers);

  group('FloatingLyricChannel native events', () {
    test('forwards lookup text from the overlay', () async {
      String? lookupText;
      FloatingLyricChannel.setEventHandlers(
        onLookupText: (String text) {
          lookupText = text;
        },
      );

      await invokeFromNative('lookupText', <String, Object?>{
        'text': '言葉',
      });

      expect(lookupText, '言葉');
    });

    test('forwards overlay playback controls', () async {
      final List<String> calls = <String>[];
      FloatingLyricChannel.setEventHandlers(
        onPreviousCue: () {
          calls.add('previous');
        },
        onPlayPause: () {
          calls.add('playPause');
        },
        onNextCue: () {
          calls.add('next');
        },
        onClose: () {
          calls.add('close');
        },
      );

      await invokeFromNative('previousCue');
      await invokeFromNative('playPause');
      await invokeFromNative('nextCue');
      await invokeFromNative('close');

      expect(calls, <String>['previous', 'playPause', 'next', 'close']);
    });
  });
}
