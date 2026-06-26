// TODO-617 selection capture — inject Ctrl+C to grab the foreground app's
// current selection, read it from the clipboard, then restore the clipboard.
//
// This is what makes "select text in any app + press hotkey" work without the
// user copying first (yomitan-style). Pure Dart FFI over user32's keybd_event
// (a thin SendInput wrapper); no native code.
//
// CRITICAL: a global hotkey (e.g. Ctrl+Alt+D) fires while the user still
// physically holds Ctrl/Alt. RegisterHotKey does not release them, so a naive
// injected Ctrl+C arrives as Ctrl+Alt+C (not a copy). We therefore inject
// key-up for every modifier first, then a clean Ctrl+C.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hibiki/src/lookup/global_lookup_log.dart';

typedef _KeybdEventNative = Void Function(
    Uint8 bVk, Uint8 bScan, Uint32 dwFlags, IntPtr dwExtraInfo);
typedef _KeybdEventDart = void Function(
    int bVk, int bScan, int dwFlags, int dwExtraInfo);

abstract final class SelectionCapture {
  static final DynamicLibrary? _user32 =
      Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final _KeybdEventDart? _keybdEvent = _user32
      ?.lookupFunction<_KeybdEventNative, _KeybdEventDart>('keybd_event');

  // Virtual-key codes.
  static const int _vkShift = 0x10;
  static const int _vkControl = 0x11;
  static const int _vkMenu = 0x12; // Alt
  static const int _vkLWin = 0x5B;
  static const int _vkRWin = 0x5C;
  static const int _vkC = 0x43;
  static const int _keyUp = 0x0002; // KEYEVENTF_KEYUP

  /// Saves the clipboard, clears it, injects a clean Ctrl+C so the foreground
  /// app copies its current selection, reads it back, then restores the
  /// previous clipboard text. Returns the selected text, or null if nothing was
  /// captured.
  static Future<String?> captureForegroundSelection() async {
    if (!Platform.isWindows || _keybdEvent == null) {
      glog('capture: unsupported (windows=${Platform.isWindows} '
          'ffi=${_keybdEvent != null})');
      return null;
    }

    final String? oldText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    await Clipboard.setData(const ClipboardData(text: ''));

    _injectCleanCopy();

    // Bounded poll: the Windows clipboard update is async and may be briefly
    // locked by the source app (mirrors the BUG-114 retry in
    // desktop_lookup_service.dart). ~600ms ceiling.
    String? captured;
    for (int i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final String? now = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (now != null && now.isNotEmpty) {
        captured = now;
        break;
      }
    }

    if (oldText != null && oldText.isNotEmpty && captured != oldText) {
      await Clipboard.setData(ClipboardData(text: oldText));
    }
    glog('capture: result="${captured ?? '<null>'}" '
        '(oldLen=${oldText?.length ?? 0})');
    return captured;
  }

  /// Releases every modifier the user may be holding from the trigger hotkey,
  /// then sends a clean Ctrl+C. Without the releases the injected copy would be
  /// polluted by the still-held Alt/Shift/Win.
  static void _injectCleanCopy() {
    final _KeybdEventDart f = _keybdEvent!;
    // Release anything held.
    f(_vkShift, 0, _keyUp, 0);
    f(_vkMenu, 0, _keyUp, 0);
    f(_vkLWin, 0, _keyUp, 0);
    f(_vkRWin, 0, _keyUp, 0);
    f(_vkControl, 0, _keyUp, 0);
    // Clean Ctrl+C.
    f(_vkControl, 0, 0, 0); // Ctrl down
    f(_vkC, 0, 0, 0); // C down
    f(_vkC, 0, _keyUp, 0); // C up
    f(_vkControl, 0, _keyUp, 0); // Ctrl up
  }
}
