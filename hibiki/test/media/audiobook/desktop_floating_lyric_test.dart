import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';

/// In-memory stand-in for the native floating-lyric window
/// (`windows/runner/floating_lyric_window.cpp`). It records the same state the
/// real strip holds so the Dart controller/channel state machine can be
/// exercised on the host without a window. Native taps are simulated by feeding
/// method calls back through the platform messenger, exactly like the C++ side
/// does via `MethodChannel::InvokeMethod`.
class _FakeFloatingLyricWindow {
  bool visible = false;
  bool clickLookupEnabled = true;
  bool? playing;
  String text = '';
  ({int start, int length})? highlight;
  Map<Object?, Object?>? lastStyle;
  Map<Object?, Object?>? lastLabels;
  final List<String> methodLog = <String>[];

  Future<Object?> handle(MethodCall call) async {
    methodLog.add(call.method);
    final Object? args = call.arguments;
    final Map<Object?, Object?> map =
        args is Map ? args : const <Object?, Object?>{};
    switch (call.method) {
      case 'canDrawOverlays':
        return true;
      case 'show':
        clickLookupEnabled = map['clickLookupEnabled'] == true;
        lastStyle = map;
        visible = true;
        return true;
      case 'hide':
        visible = false;
        return null;
      case 'isShowing':
        return visible;
      case 'updateText':
        text = map['text']?.toString() ?? '';
        highlight = null;
        return null;
      case 'highlight':
        highlight = (
          start: (map['start'] as num).toInt(),
          length: (map['length'] as num).toInt(),
        );
        return null;
      case 'updateStyle':
        lastStyle = map;
        return null;
      case 'updateLabels':
        lastLabels = map;
        return null;
      case 'setPlaybackState':
        playing = map['playing'] == true;
        return null;
      case 'setClickLookupEnabled':
        clickLookupEnabled = map['enabled'] == true;
        return null;
      case 'setLocked':
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.hibiki.reader/floating_lyric';
  const MethodChannel channel = MethodChannel(channelName);
  const MethodCodec codec = StandardMethodCodec();
  late _FakeFloatingLyricWindow native;

  setUp(() {
    FloatingLyricChannel.platformOverride = true;
    native = _FakeFloatingLyricWindow();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FloatingLyricChannel.clearEventHandlers();
    FloatingLyricChannel.platformOverride = null;
  });

  // Mirrors the C++ window pushing an event up the channel.
  Future<void> nativeEvent(String method, [Object? arguments]) async {
    final ByteData data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  group('desktop floating lyric state machine', () {
    test('show -> update -> highlight -> hide lifecycle drives the window',
        () async {
      expect(await FloatingLyricChannel.isShowing(), isFalse);

      final bool shown = await FloatingLyricChannel.show(
        fontSize: 22,
        clickLookupEnabled: false,
      );
      expect(shown, isTrue);
      expect(native.visible, isTrue);
      expect(native.clickLookupEnabled, isFalse);
      expect(await FloatingLyricChannel.isShowing(), isTrue);

      await FloatingLyricChannel.updateText('テスト文章');
      expect(native.text, 'テスト文章');

      await FloatingLyricChannel.highlight(start: 1, length: 2);
      expect(native.highlight, isNotNull);
      expect(native.highlight!.start, 1);
      expect(native.highlight!.length, 2);

      await FloatingLyricChannel.setPlaybackState(playing: true);
      expect(native.playing, isTrue);

      await FloatingLyricChannel.hide();
      expect(native.visible, isFalse);
      expect(await FloatingLyricChannel.isShowing(), isFalse);
    });

    test('updateText clears any prior highlight (cue advanced)', () async {
      await FloatingLyricChannel.show();
      await FloatingLyricChannel.updateText('first');
      await FloatingLyricChannel.highlight(start: 0, length: 3);
      expect(native.highlight, isNotNull);

      await FloatingLyricChannel.updateText('second');
      expect(native.highlight, isNull);
      expect(native.text, 'second');
    });

    test('setClickLookupEnabled propagates to the window', () async {
      await FloatingLyricChannel.show(clickLookupEnabled: true);
      expect(native.clickLookupEnabled, isTrue);

      await FloatingLyricChannel.setClickLookupEnabled(false);
      expect(native.clickLookupEnabled, isFalse);
    });

    test('native lookup tap forwards text + index to the handler', () async {
      String? lookupText;
      int? lookupIndex;
      FloatingLyricChannel.setEventHandlers(
        onLookupText: (String text, int index) {
          lookupText = text;
          lookupIndex = index;
        },
      );

      await FloatingLyricChannel.show();
      await FloatingLyricChannel.updateText('あいうえお');
      // The native strip hit-tests a tap to char index 2 and reports it.
      await nativeEvent('lookupText', <String, Object?>{
        'text': 'あいうえお',
        'index': 2,
      });

      expect(lookupText, 'あいうえお');
      expect(lookupIndex, 2);
    });

    test('native control taps drive playback + close', () async {
      final List<String> events = <String>[];
      bool closed = false;
      FloatingLyricChannel.setEventHandlers(
        onPreviousCue: () => events.add('prev'),
        onPlayPause: () => events.add('play'),
        onNextCue: () => events.add('next'),
        onClose: () async {
          closed = true;
          await FloatingLyricChannel.hide();
        },
      );

      await FloatingLyricChannel.show();
      await nativeEvent('previousCue');
      await nativeEvent('playPause');
      await nativeEvent('nextCue');
      await nativeEvent('close');

      expect(events, <String>['prev', 'play', 'next']);
      expect(closed, isTrue);
      expect(native.visible, isFalse);
    });

    test('canDrawOverlays is always permitted on the desktop strip', () async {
      expect(await FloatingLyricChannel.canDrawOverlays(), isTrue);
    });
  });
}
