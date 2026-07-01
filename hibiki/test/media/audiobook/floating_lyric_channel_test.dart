import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.hibiki.reader/floating_lyric';
  const MethodCodec codec = StandardMethodCodec();

  setUp(() {
    FloatingLyricChannel.platformOverride = true;
  });

  Future<void> invokeFromNative(String method, [Object? arguments]) async {
    final ByteData data = codec.encodeMethodCall(
      MethodCall(method, arguments),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(channelName),
      null,
    );
    FloatingLyricChannel.clearEventHandlers();
    FloatingLyricChannel.platformOverride = null;
  });

  group('FloatingLyricChannel native events', () {
    test('forwards lookup text and index from the overlay', () async {
      String? lookupText;
      int? lookupIndex;
      FloatingLyricChannel.setEventHandlers(
        onLookupText: (text, index) {
          lookupText = text;
          lookupIndex = index;
        },
      );

      await invokeFromNative('lookupText', <String, Object?>{
        'text': 'abcdef',
        'index': 2,
      });

      expect(lookupText, 'abcdef');
      expect(lookupIndex, 2);
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

    test('sends highlight range to the overlay', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return null;
        },
      );

      await FloatingLyricChannel.highlight(start: 2, length: 3);

      expect(capturedCall?.method, 'highlight');
      expect(capturedCall?.arguments, <String, Object?>{
        'start': 2,
        'length': 3,
      });
    });

    test('sends localized labels to the overlay', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return null;
        },
      );

      await FloatingLyricChannel.updateLabels(
        previous: 'Previous',
        playPause: 'Play',
        next: 'Next',
        lock: 'Lock',
        unlock: 'Unlock',
        close: 'Close',
      );

      expect(capturedCall?.method, 'updateLabels');
      expect(capturedCall?.arguments, <String, Object?>{
        'previous': 'Previous',
        'playPause': 'Play',
        'next': 'Next',
        'lock': 'Lock',
        'unlock': 'Unlock',
        'close': 'Close',
      });
    });

    test('sends playback state to the overlay', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return null;
        },
      );

      await FloatingLyricChannel.setPlaybackState(playing: true);

      expect(capturedCall?.method, 'setPlaybackState');
      expect(capturedCall?.arguments, <String, Object?>{
        'playing': true,
      });
    });

    test('sends themed style colors to the overlay', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return null;
        },
      );

      await FloatingLyricChannel.updateStyle(
        fontSize: 18,
        textColor: 0xFF112233,
        bgColor: 0xCC445566,
        buttonTextColor: 0xFF778899,
        buttonBgColor: 0x33112233,
        highlightColor: 0x80445566,
        activeColor: 0xFFABCDEF,
      );

      expect(capturedCall?.method, 'updateStyle');
      expect(capturedCall?.arguments, <String, Object?>{
        'fontSize': 18.0,
        'textColor': 0xFF112233,
        'bgColor': 0xCC445566,
        'buttonTextColor': 0xFF778899,
        'buttonBgColor': 0x33112233,
        'highlightColor': 0x80445566,
        'activeColor': 0xFFABCDEF,
        // TODO-708 P2: 圆角半径 / 窗宽默认哨兵 0（缺省=平台原生观感）。
        'cornerRadius': 0,
        'windowWidth': 0,
      });
    });

    test('starts overlay with themed style and click lookup state', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return true;
        },
      );

      final bool result = await FloatingLyricChannel.show(
        fontSize: 19,
        textColor: 0xFF010203,
        bgColor: 0xCC040506,
        buttonTextColor: 0xFF070809,
        buttonBgColor: 0x330A0B0C,
        highlightColor: 0x80112233,
        activeColor: 0xFF445566,
        locked: true,
        clickLookupEnabled: false,
      );

      expect(result, isTrue);
      expect(capturedCall?.method, 'show');
      expect(capturedCall?.arguments, <String, Object?>{
        'fontSize': 19.0,
        'textColor': 0xFF010203,
        'bgColor': 0xCC040506,
        'buttonTextColor': 0xFF070809,
        'buttonBgColor': 0x330A0B0C,
        'highlightColor': 0x80112233,
        'activeColor': 0xFF445566,
        // TODO-708 P2: 圆角半径 / 窗宽默认哨兵 0（缺省=平台原生观感）。
        'cornerRadius': 0,
        'windowWidth': 0,
        'locked': true,
        'clickLookupEnabled': false,
      });
    });

    test('show does not reset native lock state by default', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return true;
        },
      );

      final bool result = await FloatingLyricChannel.show();

      expect(result, isTrue);
      expect(capturedCall?.method, 'show');
      expect(capturedCall?.arguments, isA<Map<Object?, Object?>>());
      expect(
        capturedCall?.arguments as Map<Object?, Object?>,
        isNot(containsPair('locked', false)),
      );
    });

    test('sends click lookup state to the overlay', () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (call) async {
          capturedCall = call;
          return null;
        },
      );

      await FloatingLyricChannel.setClickLookupEnabled(false);

      expect(capturedCall?.method, 'setClickLookupEnabled');
      expect(capturedCall?.arguments, <String, Object?>{
        'enabled': false,
      });
    });
  });
}
