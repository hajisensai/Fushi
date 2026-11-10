import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The input device class a [KeyEvent] came from.
///
/// Use this instead of [KeyEvent.deviceType] wherever a controller's D-pad
/// must be told apart from a keyboard's arrow keys.
///
/// Temporary compatibility layer for an engine limitation (Flutter 3.47.6 and
/// upstream master as of 2026-11): on Android the engine puts the device type
/// into the key data packet (`KeyData.java` writes `deviceType`, and
/// `MainActivity` narrows a controller's combined source through
/// `ControllerKeySource` so the engine classifies it), but dart:ui's
/// `PlatformDispatcher._unpackKeyData` never reads that field. Every
/// [KeyEvent] built from key data therefore says
/// [ui.KeyEventDeviceType.keyboard], and a gamepad / joystick D-pad looked
/// exactly like keyboard arrows (controller lookup mode and companion panel
/// drive let the page turn instead of moving the cursor).
///
/// The engine still sends the legacy raw key message for the same native
/// event, with the real source, and the framework hands it to [RawKeyboard]
/// listeners right before it dispatches that event's [KeyEvent]s to the
/// [HardwareKeyboard] handlers and the focus tree (including
/// `FocusManager.addEarlyKeyEventHandler`). [install] records that source, and
/// [keyEventDeviceType] uses it for the non-synthesized events of the same
/// message.
///
/// Scope: Android only (other platforms' raw data carries no source); events
/// whose [KeyEvent.deviceType] is already not `keyboard` are returned as is.
/// Remove this file (callers read [KeyEvent.deviceType] again) once
/// `_unpackKeyData` reads the device type: the test
/// `test/shortcuts/key_event_device_type_test.dart` asserts that the engine
/// still drops it and fails when it no longer does.
abstract final class AndroidKeyEventSource {
  static bool _installed = false;
  static int? _source;

  /// Starts recording the source of each raw Android key message. Idempotent;
  /// call it once at startup, before the first key event.
  static void install() {
    if (_installed) return;
    _installed = true;
    RawKeyboard.instance.addListener(_onRawKeyEvent);
  }

  static void _onRawKeyEvent(RawKeyEvent event) {
    final RawKeyEventData data = event.data;
    _source = data is RawKeyEventDataAndroid ? data.eventSource : null;
  }

  /// Forgets the installation (tests).
  @visibleForTesting
  static void debugReset() {
    if (_installed) {
      RawKeyboard.instance.removeListener(_onRawKeyEvent);
    }
    _installed = false;
    _source = null;
  }

  /// The device class of the Android input [source] bit mask, with the same
  /// rule as `ControllerKeySource.forFlutter` on the Java side: a source that
  /// carries the joystick or gamepad class is that controller; exactly
  /// `SOURCE_DPAD` is a directional pad; everything else (including the
  /// `SOURCE_KEYBOARD | SOURCE_DPAD` of a keyboard with arrow keys) is a
  /// keyboard.
  static ui.KeyEventDeviceType deviceTypeOfSource(int source) {
    bool has(int wanted) => (source & wanted) == wanted;
    if (has(_sourceJoystick)) return ui.KeyEventDeviceType.joystick;
    if (has(_sourceGamepad)) return ui.KeyEventDeviceType.gamepad;
    if (source == _sourceDpad) return ui.KeyEventDeviceType.directionalPad;
    if (source == _sourceHdmi) return ui.KeyEventDeviceType.hdmi;
    return ui.KeyEventDeviceType.keyboard;
  }

  // android.view.InputDevice.SOURCE_* values.
  static const int _sourceDpad = 0x00000201;
  static const int _sourceGamepad = 0x00000401;
  static const int _sourceJoystick = 0x01000010;
  static const int _sourceHdmi = 0x02000001;
}

/// The device class of [event]; see [AndroidKeyEventSource].
ui.KeyEventDeviceType keyEventDeviceType(KeyEvent event) {
  if (event.deviceType != ui.KeyEventDeviceType.keyboard) {
    return event.deviceType;
  }
  // A synthesized event (modifier / pressed-state repair) is dispatched on
  // its own, without a raw message: the recorded source belongs to some
  // earlier key.
  if (event.synthesized) return event.deviceType;
  final int? source = AndroidKeyEventSource._source;
  if (source == null) return event.deviceType;
  return AndroidKeyEventSource.deviceTypeOfSource(source);
}
