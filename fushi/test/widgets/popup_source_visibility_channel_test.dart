import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/popup_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel channel = FushiChannels.popup;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    PopupChannel.instance.init();
  });

  test(
    'cold payload parses request-scoped source visibility with a false default',
    () async {
      Object? payload;
      messenger.setMockMethodCallHandler(channel, (_) async => payload);
      for (final Object? value in <Object?>[true, false, null, 'true', 1]) {
        payload = <String, Object?>{
          'text': 'full sentence for mining',
          'charIndex': 8,
          if (value != null) 'sourceTextCollapsed': value,
        };
        final result = await PopupChannel.instance.getInitialProcessText();
        expect(result.sourceTextCollapsed, value == true);
        expect(result.text, 'full sentence for mining');
        expect(result.charIndex, 8);
      }
      payload = 'legacy request';
      expect(
        (await PopupChannel.instance.getInitialProcessText())
            .sourceTextCollapsed,
        isFalse,
      );
    },
  );

  test(
    'warm identical text resets visibility when the next request omits the field',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final List<bool> states = <bool>[];
      final List<String> texts = <String>[];
      PopupChannel.instance.init(
        onNewProcessText:
            (
              String text,
              int charIndex,
              Rect? anchor,
              Rect? subtitle,
              PopupSourceBlock? sourceBlock,
              bool collapsed,
            ) {
              states.add(collapsed);
              texts.add(text);
            },
      );
      await Future<void>.delayed(Duration.zero);
      for (final Object? value in <Object?>[true, null, true, false]) {
        final ByteData data = const StandardMethodCodec().encodeMethodCall(
          MethodCall('onNewProcessText', <String, Object?>{
            'text': 'same complete context',
            if (value != null) 'sourceTextCollapsed': value,
          }),
        );
        final Completer<void> reply = Completer<void>();
        await messenger.handlePlatformMessage(
          channel.name,
          data,
          (_) => reply.complete(),
        );
        await reply.future;
      }
      expect(states, <bool>[true, false, true, false]);
      expect(texts, everyElement('same complete context'));
    },
  );
}
