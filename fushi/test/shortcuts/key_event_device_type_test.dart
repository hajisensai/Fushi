import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/key_event_device_type.dart';

// android.view.InputDevice.SOURCE_* / KeyEvent.KEYCODE_* values.
const int _sourceKeyboardDpad = 0x00000301;
const int _sourceGamepad = 0x00000401;
const int _sourceKeyboardGamepad = 0x00000501;
const int _sourceJoystick = 0x01000010;
const int _keycodeDpadDown = 20;

/// One native Android key event the way the engine delivers it: the key data
/// first (dart:ui drops its device type, so it always says keyboard), then
/// the legacy raw message with the real source.
Future<void> _sendAndroidKey({required bool down, required int source}) async {
  // ignore: deprecated_member_use
  ServicesBinding.instance.keyEventManager.handleKeyData(
    ui.KeyData(
      timeStamp: Duration.zero,
      type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
      physical: PhysicalKeyboardKey.arrowDown.usbHidUsage,
      logical: LogicalKeyboardKey.arrowDown.keyId,
      character: null,
      synthesized: false,
    ),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemChannels.keyEvent.name,
        SystemChannels.keyEvent.codec.encodeMessage(<String, Object?>{
          'type': down ? 'keydown' : 'keyup',
          'keymap': 'android',
          'keyCode': _keycodeDpadDown,
          'scanCode': 108,
          'metaState': 0,
          'source': source,
          'flags': 8,
          'deviceId': 10,
        }),
        (ByteData? _) {},
      );
}

/// The focus tree (and its early handlers) only sees keys with a primary
/// focus.
Future<void> _pumpFocused(WidgetTester tester) async {
  await tester.pumpWidget(const Focus(autofocus: true, child: SizedBox()));
  await tester.pump();
}

void main() {
  late List<KeyEvent> seen;

  KeyEventResult record(KeyEvent event) {
    seen.add(event);
    return KeyEventResult.ignored;
  }

  setUp(() {
    seen = <KeyEvent>[];
    AndroidKeyEventSource.install();
    FocusManager.instance.addEarlyKeyEventHandler(record);
  });
  tearDown(() {
    FocusManager.instance.removeEarlyKeyEventHandler(record);
    AndroidKeyEventSource.debugReset();
  });

  testWidgets('a gamepad D-pad is a controller button in the focus tree', (
    WidgetTester tester,
  ) async {
    await _pumpFocused(tester);
    await _sendAndroidKey(down: true, source: _sourceGamepad);
    await _sendAndroidKey(down: false, source: _sourceGamepad);

    expect(seen, hasLength(2));
    // The engine limitation this layer exists for.
    expect(seen.first.deviceType, ui.KeyEventDeviceType.keyboard);
    expect(keyEventDeviceType(seen.first), ui.KeyEventDeviceType.gamepad);
    expect(GamepadButton.fromKeyEvent(seen.first), GamepadButton.dpadDown);
    expect(GamepadButton.fromKeyEvent(seen.last), GamepadButton.dpadDown);
  });

  testWidgets('a hat D-pad (keys synthesized from joystick motion) too', (
    WidgetTester tester,
  ) async {
    await _pumpFocused(tester);
    await _sendAndroidKey(down: true, source: _sourceJoystick);

    expect(keyEventDeviceType(seen.single), ui.KeyEventDeviceType.joystick);
    expect(GamepadButton.fromKeyEvent(seen.single), GamepadButton.dpadDown);
    await _sendAndroidKey(down: false, source: _sourceJoystick);
  });

  testWidgets('keyboard arrows stay keyboard arrows', (
    WidgetTester tester,
  ) async {
    await _pumpFocused(tester);
    await _sendAndroidKey(down: true, source: _sourceKeyboardDpad);

    expect(keyEventDeviceType(seen.single), ui.KeyEventDeviceType.keyboard);
    expect(GamepadButton.fromKeyEvent(seen.single), isNull);
    await _sendAndroidKey(down: false, source: _sourceKeyboardDpad);
  });

  test('source classification matches ControllerKeySource.forFlutter', () {
    expect(
      AndroidKeyEventSource.deviceTypeOfSource(_sourceKeyboardGamepad),
      ui.KeyEventDeviceType.gamepad,
    );
    expect(
      AndroidKeyEventSource.deviceTypeOfSource(_sourceKeyboardGamepad | 0x200),
      ui.KeyEventDeviceType.gamepad,
    );
    expect(
      AndroidKeyEventSource.deviceTypeOfSource(_sourceJoystick | 0x501),
      ui.KeyEventDeviceType.joystick,
    );
    expect(
      AndroidKeyEventSource.deviceTypeOfSource(0x201),
      ui.KeyEventDeviceType.directionalPad,
    );
    expect(
      AndroidKeyEventSource.deviceTypeOfSource(0x101),
      ui.KeyEventDeviceType.keyboard,
    );
  });

  test('cleanup detector: dart:ui still drops KeyData.deviceType', () {
    // When this fails, Flutter's `_unpackKeyData` reads the device type:
    // delete `key_event_device_type.dart` and read KeyEvent.deviceType again.
    final String? root = Platform.environment['FLUTTER_ROOT'];
    final File source = File(
      '$root/bin/cache/pkg/sky_engine/lib/ui/platform_dispatcher.dart',
    );
    if (root == null || !source.existsSync()) {
      markTestSkipped('FLUTTER_ROOT / sky_engine source not available');
      return;
    }
    final String text = source.readAsStringSync();
    final int start = text.indexOf('static KeyData _unpackKeyData(');
    expect(start, isNonNegative);
    final int end = text.indexOf('return keyData;', start);
    expect(text.substring(start, end), isNot(contains('deviceType')));
  });
}
