import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Windows runner display-recovery fix (TODO-689): repaint the window
/// when a monitor powers on or the display topology changes, so the app does not
/// stay black after the display returns. These assertions pin the message
/// handling AND the Register/Unregister pairing (so a future edit can't drop the
/// unregister and silently leak the power-notification handle).
void main() {
  group('Windows runner display recovery contract (TODO-689)', () {
    final String win32 =
        File('windows/runner/win32_window.cpp').readAsStringSync();
    final String win32Header =
        File('windows/runner/win32_window.h').readAsStringSync();
    final String flutterWindow =
        File('windows/runner/flutter_window.cpp').readAsStringSync();
    final String flutterWindowHeader =
        File('windows/runner/flutter_window.h').readAsStringSync();

    test('win32_window handles display-change and monitor power-on messages',
        () {
      expect(win32, contains('WM_DISPLAYCHANGE'),
          reason: 'Must repaint on display topology / mode change.');
      expect(win32, contains('WM_POWERBROADCAST'),
          reason: 'Must react to monitor power-on broadcasts.');
      expect(win32, contains('GUID_MONITOR_POWER_ON'),
          reason: 'Must scope the power notification to monitor power-on.');
      expect(win32, contains('PBT_POWERSETTINGCHANGE'),
          reason: 'Must only read POWERBROADCAST_SETTING for setting changes.');
      // Repaint path: invalidate + ask the renderer for a fresh frame.
      expect(win32, contains('InvalidateRect'),
          reason: 'Must invalidate the window so it repaints.');
      expect(win32, contains('OnDisplayRecovered'),
          reason: 'Both messages must funnel into OnDisplayRecovered.');
    });

    test('win32_window registers AND unregisters the power notification', () {
      expect(win32, contains('RegisterPowerSettingNotification'),
          reason: 'Must subscribe to monitor power-on notifications.');
      // Pairing guard: dropping the unregister leaks the HPOWERNOTIFY handle.
      expect(win32, contains('UnregisterPowerSettingNotification'),
          reason: 'Must release the power notification handle on Destroy().');
      expect(win32Header, contains('HPOWERNOTIFY power_notify_'),
          reason: 'The registration handle must be held for later cleanup.');
      expect(win32Header, contains('OnDisplayRecovered'),
          reason: 'Base class must expose the virtual recovery hook.');
    });

    test('flutter_window forces a redraw when the display recovers', () {
      expect(flutterWindowHeader, contains('OnDisplayRecovered'),
          reason: 'FlutterWindow must override the recovery hook.');
      expect(flutterWindow, contains('void FlutterWindow::OnDisplayRecovered'),
          reason: 'FlutterWindow must implement the recovery hook.');
      expect(flutterWindow, contains('ForceRedraw'),
          reason: 'Recovery must push a fresh frame through the controller.');
    });
  });
}
