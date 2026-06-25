// TODO-617 selection capture — inject Ctrl+C to grab the foreground app's
// current selection, read it from the clipboard, then restore the clipboard.
//
// This is what makes "select text in any app + press hotkey" work without the
// user copying first (yomitan-style). Pure Dart FFI over user32's keybd_event
// (a thin SendInput wrapper); no native code.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

typedef _KeybdEventNative = Void Function(
    Uint8 bVk, Uint8 bScan, Uint32 dwFlags, IntPtr dwExtraInfo);
typedef _KeybdEventDart = void Function(
    int bVk, int bScan, int dwFlags, int dwExtraInfo);

abstract final class SelectionCapture {
  static final DynamicLibrary? _user32 =
      Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final _KeybdEventDart? _keybdEvent = _user32
      ?.lookupFunction<_KeybdEventNative, _KeybdEventDart>('keybd_event');

  static const int _vkControl = 0x11;
  static const int _vkC = 0x43;
  static const int _keyEventKeyUp = 0x0002;

  /// Saves the clipboard, clears it, injects Ctrl+C so the foreground app copies
  /// its current selection, reads it back, then restores the previous clipboard
  /// text. Returns the selected text, or null if nothing was captured (no
  /// selection, or the app did not honour Ctrl+C).
  ///
  /// Non-text clipboard content (images) is not preserved — best-effort restore
  /// of text only. The selection is detected by clearing first so it also works
  /// when the selection equals the previous clipboard text.
  static Future<String?> captureForegroundSelection() async {
    if (!Platform.isWindows || _keybdEvent == null) {
      return null;
    }

    final String? oldText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    await Clipboard.setData(const ClipboardData(text: ''));

    _injectCtrlC();

    // Bounded poll: the Windows clipboard update is async and may be briefly
    // locked by the source app (mirrors the BUG-114 retry in
    // desktop_lookup_service.dart). ~500ms ceiling.
    String? captured;
    for (int i = 0; i < 20; i++) {
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
    return captured;
  }

  static void _injectCtrlC() {
    final _KeybdEventDart f = _keybdEvent!;
    f(_vkControl, 0, 0, 0); // Ctrl down
    f(_vkC, 0, 0, 0); // C down
    f(_vkC, 0, _keyEventKeyUp, 0); // C up
    f(_vkControl, 0, _keyEventKeyUp, 0); // Ctrl up
  }
}
